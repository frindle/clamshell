import Foundation
import CoreMedia
import UIKit

// WebSocket protocol client shared by both UIs of the universal iOS app (the
// iPad viewer and the iPhone control surface): connect, parse framed messages, assemble
// video samples, play audio, forward input, sync clipboard, auto-reconnect.

final class StreamClient: ObservableObject {
    enum Status: Equatable {
        case idle, connecting, streaming(String), failed(String)
    }

    @Published var status: Status = .idle
    @Published var videoSize: CGSize = .zero
    /// True when HELLO_ACK reported the host is encoding in SOFTWARE (no
    /// hardware encoder) — surfaced as a warning banner in the UI.
    @Published var softwareEncoding = false
    /// Host's current encoder target (kbps) from STREAM_STATUS; 0 = not yet
    /// reported. Drives the connection-quality dot / Nerd Mode readout.
    @Published var currentBitrateKbps: UInt16 = 0
    /// Negotiated codec name ("HEVC"/"H.264") from HELLO_ACK, for Nerd Mode.
    @Published var codecName = ""
    /// Human-readable reason for the most recent connection failure, surfaced
    /// on-screen while auto-reconnect keeps retrying. nil once streaming.
    @Published var lastError: String?
    /// True while the host reports its screen is locked (HOST_LOCK_STATE). The
    /// native capture path can't survive the macOS lock screen, so the UI shows
    /// a banner pointing at the browser VNC fallback until the host unlocks.
    @Published var hostLocked = false
    /// Host video encoder state from VIDEO_STATE: 0 running, 1 rebuilding, 2 gave up.
    @Published var videoState: UInt8 = 0
    /// Remote cursor position from the host's periodic CURSOR_POS reports,
    /// normalized 0..1 in this display's source-frame space — nil until the
    /// first report arrives. Values outside 0...1 mean the cursor is
    /// currently on a different display than this connection; consumers
    /// (auto-pan) should treat that as "not visible here". See
    /// PROTOCOL.md "Cursor-follow auto-pan".
    @Published var cursorPos: CGPoint?
    /// What the host says it supports (PROTOCOL.md "Capabilities"). Empty until
    /// the handshake fills it, so against today's hosts every feature that
    /// needs a capability stays off.
    @Published var hostCapabilities: StreamCapabilities = []

    private let keepaliveLock = NSLock()
    private var keepalive = KeepaliveGate(now: ProcessInfo.processInfo.systemUptime)
    private var keepaliveTimer: DispatchSourceTimer?

    /// Whether audio plays through this client. Only the primary (iPad-screen)
    /// client plays audio; the external-display client stays muted.
    var playsAudio = true

    /// This client's video surface size in pixels, reported to the host in
    /// HELLO so it can auto-size its virtual display to the device (instead
    /// of a manually picked preset). nil = report nothing (older behavior).
    var reportedPixelSize: CGSize?
    /// Whether a second display surface is attached client-side (external
    /// monitor on the iPad) — drives the host's auto dual-display mode.
    var reportsSecondDisplay = false
    /// The attached second display surface's pixel size (external monitor on
    /// the iPad) — reported alongside the flag so the host sizes Display B to
    /// the real monitor instead of a fixed preset. nil = size unknown.
    var reportedSecondPixelSize: CGSize?
    /// Called with received clipboard text (main thread).
    var onClipboard: ((String) -> Void)?

    /// What the host last heard on this socket (HELLO, then CLIENT_DISPLAYS), and whether HELLO_ACK is still
    /// pending. Main thread only.
    private var helloReport: DisplayReport?
    private var awaitingHelloAck = false

    /// Decoded-ready compressed samples for the display layer. Called on the
    /// network queue; AVSampleBufferDisplayLayer enqueue is thread-safe.
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    /// What the connection flow wants the user to see or answer (waiting for
    /// approval, the identity questions, refusals, "not verified"). nil when
    /// there is nothing to show. The screens in AuthPromptView read this.
    @Published var authState: FlowState?

    /// One connection attempt. Everything in it except `task` is touched only
    /// on `wireQueue`: the flow (which owns the sealer and opener), the parser,
    /// the timers. `ended` makes late callbacks of a finished attempt harmless.
    private final class Attempt {
        let task: URLSessionWebSocketTask
        var flow: ClientAuthFlow
        let parser = StreamMessageParser(maxPayload: 16 * 1024)
        var ended = false
        var opened = false
        var timers: [(FlowTimer, DispatchWorkItem)] = []
        var openTimer: DispatchWorkItem?
        /// How long this attempt waits for the socket to open.
        let openTimeout: TimeInterval

        init(task: URLSessionWebSocketTask, flow: ClientAuthFlow, openTimeout: TimeInterval) {
            self.task = task
            self.flow = flow
            self.openTimeout = openTimeout
        }

        func cancelTimers() {
            for (_, item) in timers { item.cancel() }
            timers.removeAll()
            openTimer?.cancel()
            openTimer = nil
        }
    }

    /// Reports when a socket opens (URLSession queues sends until then, but the
    /// flow must start its 2 s wait from the moment the host can speak).
    private final class SocketDelegate: NSObject, URLSessionWebSocketDelegate {
        var onOpen: ((URLSessionWebSocketTask) -> Void)?
        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                        didOpenWithProtocol protocol: String?) {
            onOpen?(webSocketTask)
        }
    }

    /// One serial queue owns every attempt's flow, so the order messages are
    /// sealed in is the order they are written to the socket, and the order
    /// they arrive in is the order they are opened in.
    private let wireQueue = DispatchQueue(label: "clamshell.viewer.wire")
    /// Main thread only.
    private var current: Attempt?
    /// Mirror of `current` for `wireQueue`.
    private var wireAttempt: Attempt?
    private let socketDelegate = SocketDelegate()
    private lazy var session = URLSession(configuration: .default, delegate: socketDelegate, delegateQueue: nil)
    /// What carries from one attempt to the next (busy back-off and so on).
    private var flowCarry = FlowCarry()

    private var task: URLSessionWebSocketTask? { current?.task }
    private var assembler: FrameAssembler?
    private let audio = AudioPlayer()

    /// True once a HELLO went out on this connection. Main thread.
    private var helloMade = false

    // Retained connection parameters for automatic reconnection.
    private var connectHost: String?
    private var wantConnection = false
    private var reconnectAttempt = 0
    /// Last clipboard text seen in either direction — breaks the echo loop.
    private var lastClipboard: String?

    /// How long a socket may take to open. `URLSessionWebSocketTask` has no
    /// idle timeout of its own, so without this a host that accepts TCP but
    /// never completes the WebSocket upgrade would leave `status` at
    /// `.connecting` forever with no back-off scheduled. Once the socket is
    /// open the flow's own timers (2 s / 10 s for the challenge, 15 s for the
    /// result, 60 s while pending) bound every later wait.
    private let openTimeoutInterval: TimeInterval = 10
    /// The same wait when the Mac has other saved addresses to try next.
    private let alternateOpenTimeoutInterval: TimeInterval = 4
    /// The same wait for an address on a home network when there are others to
    /// try next: away from home it costs little to find that out.
    private let privateOpenTimeoutInterval: TimeInterval = 2
    /// Which of the saved Mac's addresses the next attempt dials (0 is the
    /// first one in the plan: a verified home-network address when there is
    /// one, otherwise the address the user picked). Moves on only when a
    /// socket never opened.
    private var dialIndex = 0
    /// The addresses to dial for the current `connect`, and the saved Mac the
    /// user picked (nil when the address is not a saved Mac's).
    private var dialPlan: [String] = []
    private var pickedHostId: String?
    /// The address the user picked (as dialled), to tell it from the ones this
    /// client added from the saved Mac's list.
    private var pickedURL: String?
    /// An alarm (changed key, no identification) an address the client chose
    /// itself ended with. Shown only when no other address connects.
    private var heldAlarm: DialAlarm?

    /// Accepts a bare host ("192.168.1.5" -> ws://192.168.1.5:5903) or a full
    /// ws:// / wss:// URL (Cloudflare Tunnel: wss://mac.example.com/stream).
    func connect(host: String) {
        wantConnection = true
        lastError = nil
        authState = nil
        flowCarry = FlowCarry()
        dialIndex = 0
        heldAlarm = nil
        connectHost = host
        pickedURL = host.contains("://") ? host : "ws://\(host):\(streamDefaultPort)"
        let plan = makeDialPlan(for: host)
        dialPlan = plan.urls
        pickedHostId = plan.hostId
        openSocket()
    }

    /// The addresses to try for a saved Mac: the one the user picked first,
    /// then the others its key is known at, last successful first. Each one
    /// goes through the same flow against the same saved key, so another
    /// address can never stand in for a different Mac.
    /// Worked out once per `connect`, so an address that moves to another saved
    /// Mac while the attempts run cannot change which Mac was picked.
    private func makeDialPlan(for host: String) -> (urls: [String], hostId: String?) {
        let primary = host.contains("://") ? host : "ws://\(host):\(streamDefaultPort)"
        let known = KnownHostsStore.shared.hosts
        guard let normalized = KnownHosts.normalizeAddress(primary),
              case let .host(id) = known.standing(of: normalized) else { return ([primary], nil) }
        // Every fallback is for the same display as the one picked: the same
        // port for a direct address, the same /ws/<letter> path for a tunnel.
        // A verified home-network address for that display goes before a
        // picked address that is not one (see `KnownHosts.dialURLs`).
        return (known.dialURLs(hostId: id, picked: primary), id)
    }

    /// The user's answer to a question the connection flow asked ("Connect"
    /// or "Cancel" on the rule 6 and rule 12 screens).
    func answerAuthQuestion(_ yes: Bool) {
        guard let a = current else { return }
        wireQueue.async { [weak self] in
            guard let self, !a.ended else { return }
            self.perform(a.flow.answered(yes), on: a)
        }
    }

    /// Maps a URLSession failure to a short reason a user can act on without
    /// opening Console.app: Cloudflare Access rejection vs. unreachable host
    /// vs. wrong address, distinguished by HTTP status and NSURLError code.
    static func friendlyError(_ error: Error, response: URLResponse?) -> String {
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 401, 403: return "Access denied (HTTP \(http.statusCode)) — check the Cloudflare Access token."
            case 302, 400..<500: return "Connection rejected (HTTP \(http.statusCode)) — check the URL / Cloudflare Access."
            case 500...: return "Host error (HTTP \(http.statusCode)) — the Mac rejected the stream."
            default: break
            }
        }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return ns.localizedDescription }
        switch ns.code {
        case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost:
            return "Can't reach the Mac — is it on this network and is Native Streaming enabled?"
        case NSURLErrorTimedOut:
            return "Connection timed out — check the address and that the Mac is awake."
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "Can't find that host — check the address."
        case NSURLErrorNotConnectedToInternet:
            return "This device is offline."
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            return "TLS failed — check the wss:// URL / Cloudflare Tunnel."
        default:
            return "Connection failed: \(ns.localizedDescription)"
        }
    }

    private func openSocket() {
        teardownSocket()
        guard let host = connectHost else { return }
        // A saved Macs list that cannot be read stops the connection: it is
        // never treated as empty (every Mac would be trusted on first use
        // again) and never written over. "Reset saved Macs..." is the way out.
        if let damage = KnownHostsStore.shared.damage {
            clogViewer("connect FAILED: the saved Macs could not be read")
            wantConnection = false
            authState = .failed(damage)
            status = .failed(damage)
            return
        }
        if dialPlan.isEmpty {
            let plan = makeDialPlan(for: host)
            dialPlan = plan.urls
            pickedHostId = plan.hostId
        }
        let urls = dialPlan
        if dialIndex >= urls.count { dialIndex = 0 }
        let urlString = urls[dialIndex]
        guard let url = URL(string: urlString) else {
            clogViewer("connect FAILED: invalid address '\(urlString)'")
            status = .failed("invalid address")
            return
        }
        // The device key first: if it cannot be read, nothing is sent and no
        // new key is made (a new key would be a device the Mac never approved).
        let key: DeviceKey
        do {
            key = try DeviceKeyStore.load()
        } catch {
            let message = error.localizedDescription
            clogViewer("connect FAILED: device key unavailable (\(message))")
            wantConnection = false
            authState = .failed(message)
            status = .failed(message)
            return
        }
        clogViewer("connecting to \(urlString) as device \(key.fingerprint)")
        status = .connecting
        authState = .connecting

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        var config = ClientAuthConfig(deviceKey: key.publicKey, sign: key.sign,
                                      deviceName: UIDevice.current.name, appVersion: version,
                                      dialledURL: urlString,
                                      makeHello: { [weak self] in
                                          // Runs on wireQueue; main never waits on wireQueue.
                                          guard let self else { return Data() }
                                          return DispatchQueue.main.sync { self.makeHelloMessage() }
                                      })
        // This app sends files and game controllers to the Mac (bits 5 and 6).
        // It receives no files: a host offer is answered "declined".
        config.capabilities = ClientAuthFlow.defaultCapabilities.union([.fileTransfer, .peripherals])
        config.fallbackDeviceName = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        config.expectedHostId = pickedHostId
        // An address from the saved list that the user did not type may fall
        // through to the next one; the picked one raises its alarm at once.
        config.fallsThrough = urlString != pickedURL && dialIndex + 1 < urls.count
        let flow = ClientAuthFlow(config: config, known: KnownHostsStore.shared.hosts, carry: flowCarry)

        socketDelegate.onOpen = { [weak self] task in self?.socketOpened(task) }
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 64 << 20 // keyframes at full display resolution
        let attempt = Attempt(task: task, flow: flow,
                              openTimeout: urls.count == 1 ? openTimeoutInterval
                                  : KnownHosts.isPrivateAddress(urlString) ? privateOpenTimeoutInterval
                                  : alternateOpenTimeoutInterval)
        attempt.parser.onMessage = { [weak self, weak attempt] type, payload in
            guard let self, let attempt, !attempt.ended else { return }
            self.perform(attempt.flow.received(type: type.rawValue, payload: payload), on: attempt)
        }
        // A type this build does not know is still a message: before the
        // challenge, or inside an encrypted session, it is a protocol error.
        attempt.parser.onUnknown = { [weak self, weak attempt] raw in
            guard let self, let attempt, !attempt.ended else { return }
            self.perform(attempt.flow.received(type: raw, payload: Data()), on: attempt)
        }
        current = attempt
        wireQueue.async { [weak self] in
            guard let self else { return }
            self.wireAttempt = attempt
            self.armOpenTimer(attempt)
        }
        startKeepalive()
        task.resume()
        receiveLoop(attempt)
    }

    /// Main thread, called by the flow when it sends HELLO: the display report
    /// this HELLO carries is what the host has heard.
    private func makeHelloMessage() -> Data {
        helloMade = true
        helloReport = currentDisplayReport
        awaitingHelloAck = true
        return StreamMessage.hello(requestedCodec: .hevc, displayInfo: displayInfoPayload,
                                   secondSize: secondSizePayload)
    }

    // MARK: Wire queue

    /// On wireQueue: give up on a socket that never opens.
    private func armOpenTimer(_ a: Attempt) {
        let item = DispatchWorkItem { [weak self, weak a] in
            guard let self, let a, !a.ended, !a.opened else { return }
            clogViewer("the socket did not open within \(Int(a.openTimeout)) s")
            self.perform([.end(.failure, "the socket did not open in time")], on: a)
        }
        a.openTimer = item
        wireQueue.asyncAfter(deadline: .now() + a.openTimeout, execute: item)
    }

    /// Any thread: the delegate saw the WebSocket open.
    private func socketOpened(_ task: URLSessionWebSocketTask) {
        wireQueue.async { [weak self] in
            guard let self, let a = self.wireAttempt, a.task === task, !a.ended, !a.opened else { return }
            a.opened = true
            a.openTimer?.cancel()
            a.openTimer = nil
            self.perform(a.flow.opened(), on: a)
        }
    }

    private func cancelTimer(_ timer: FlowTimer, on a: Attempt) {
        for (kind, item) in a.timers where kind == timer { item.cancel() }
        a.timers.removeAll { $0.0 == timer }
    }

    /// On wireQueue: do what the flow said. Sends happen here, in the order
    /// the flow produced them, which is the order of the seal counters.
    private func perform(_ actions: [FlowAction], on a: Attempt) {
        for action in actions {
            guard !a.ended else { return }
            switch action {
            case let .send(data):
                noteSent()
                a.task.send(.data(data)) { _ in }
            case let .startTimer(timer, seconds):
                cancelTimer(timer, on: a)
                let item = DispatchWorkItem { [weak self, weak a] in
                    guard let self, let a, !a.ended else { return }
                    a.timers.removeAll { $0.0 == timer }
                    self.perform(a.flow.timerFired(timer), on: a)
                }
                a.timers.append((timer, item))
                wireQueue.asyncAfter(deadline: .now() + seconds, execute: item)
            case let .cancelTimer(timer):
                cancelTimer(timer, on: a)
            case let .state(state):
                if case .connected = state { a.parser.maxPayload = StreamMessageParser.defaultMaxPayload }
                DispatchQueue.main.async { [weak self] in self?.applyFlowState(state, from: a) }
            case let .deliver(raw, payload):
                if let type = StreamMessageType(rawValue: raw) { handle(type: type, payload: payload) }
            case let .change(change):
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.current === a else { return }
                    KnownHostsStore.shared.apply(change)
                }
            case let .hostCapabilities(caps):
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.current === a else { return }
                    self.hostCapabilities = caps
                }
            case let .close(reason):
                clogViewer("closing the socket: \(reason)")
                a.cancelTimers()
                a.task.cancel(with: .normalClosure, reason: nil)
            case let .end(end, reason):
                a.ended = true
                a.cancelTimers()
                a.task.cancel(with: .normalClosure, reason: nil)
                let opened = a.opened
                DispatchQueue.main.async { [weak self] in self?.attemptEnded(a, end, reason, socketOpened: opened) }
            }
        }
    }

    /// Main thread: what the screen shows.
    private func applyFlowState(_ state: FlowState, from a: Attempt) {
        guard current === a else { return }
        authState = state
        heldAlarm = DialPlanFlow.held(after: state, heldAlarm)
        if case let .connected(verified, _) = state {
            reconnectAttempt = 0
            clogViewer(verified ? "connected and verified" : "connected, NOT verified")
        }
    }

    /// Main thread: an attempt finished. `.stop` waits for the user,
    /// `.failure` uses this client's own back-off, `.reconnect` does as told.
    private func attemptEnded(_ a: Attempt, _ end: FlowEnd, _ reason: String, socketOpened opened: Bool) {
        guard current === a else { return }
        clogViewer("connection attempt ended: \(reason)")
        let shown = authState
        switch end {
        case .stop:
            wantConnection = false
            teardownSocket()
            switch shown {
            case .askUnverified?, .confirmHost?, .connecting?, nil:
                disconnect() // the user said no
            default:
                status = .failed(Self.describe(shown) ?? reason)
            }
        case .failure, .nextAddress:
            // The socket never opened, or the address reached a different saved
            // Mac than the one picked: try the Mac's next saved address at
            // once; only after the last one does the back-off apply.
            // What comes next is decided by `DialPlanFlow` (shared code, with
            // tests): move on, show a held alarm, or fall to the back-off.
            if wantConnection, connectHost != nil, dialPlan.indices.contains(dialIndex) {
                let wrongMac = end == .nextAddress
                let address = dialPlan[dialIndex]
                let outcome = DialPlanFlow.decide(end: end, shown: shown, opened: opened, address: address,
                                                  isPicked: address == pickedURL,
                                                  isLast: dialIndex + 1 >= dialPlan.count, held: heldAlarm)
                if heldAlarm == nil, outcome.held != nil {
                    clogViewer("alarm held for \(address); trying the next saved address")
                }
                heldAlarm = outcome.held
                switch outcome {
                case .tryNext:
                    dialIndex += 1
                    clogViewer(wrongMac ? "that address reaches a different saved Mac, or not the saved key; trying the next saved one"
                                        : "that address did not answer; trying the next saved one")
                    teardownSocket()
                    openSocket()
                    return
                case let .showAlarm(held):
                    // Every address was tried: now the alarm is shown, naming
                    // the address that raised it.
                    dialIndex = 0
                    heldAlarm = nil
                    wantConnection = false
                    teardownSocket()
                    authState = held.state
                    let text = (Self.describe(held.state) ?? "This Mac could not be verified") + " (at \(held.address))"
                    status = .failed(text)
                    lastError = text
                    return
                case let .showError(restartPlan, _):
                    if restartPlan { dialIndex = 0 }
                }
            }
            if case let .failed(text)? = shown { lastError = "Could not connect securely: \(text)" }
            scheduleReconnect()
        case let .reconnect(after, carry):
            flowCarry = carry
            teardownSocket()
            guard wantConnection else { return }
            status = .connecting
            if after <= 0 {
                openSocket()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
                    guard let self, self.wantConnection, self.current == nil else { return }
                    self.openSocket()
                }
            }
        }
    }

    private static func describe(_ state: FlowState?) -> String? {
        switch state {
        case .changedIdentity?: return "This Mac's identity has changed"
        case .didNotIdentify?: return "This Mac did not identify itself"
        case .denied?: return "This Mac turned this device away"
        case .invalid?: return "This Mac did not accept this device"
        case let .failed(text)?: return text
        default: return nil
        }
    }

    /// The wire form of the reported display situation. Mac virtual displays
    /// are landscape, so the size is landscape-normalized regardless of how
    /// the device is currently held.
    private var displayInfoPayload: (widthPx: UInt32, heightPx: UInt32, secondDisplay: Bool)? {
        guard let s = reportedPixelSize, s.width > 0, s.height > 0 else { return nil }
        return (UInt32(max(s.width, s.height)), UInt32(min(s.width, s.height)), reportsSecondDisplay)
    }

    /// The attached second display's landscape-normalized pixel size, sent
    /// only when a second display is actually reported.
    private var secondSizePayload: (widthPx: UInt32, heightPx: UInt32)? {
        guard reportsSecondDisplay, let s = reportedSecondPixelSize, s.width > 0, s.height > 0 else { return nil }
        return (UInt32(max(s.width, s.height)), UInt32(min(s.width, s.height)))
    }

    /// Mid-session update (external monitor plugged/unplugged, or a new
    /// surface size). Stores the values — they ride the next HELLO on
    /// reconnect — and, when connected, tells the host now via
    /// CLIENT_DISPLAYS so it can reshape its virtual display(s).
    ///
    /// Between opening the socket and HELLO_ACK nothing is sent: the stored
    /// values may already ride the HELLO, and a display rebuild that early
    /// raced with the host's capture start. `helloAcknowledged()` sends one
    /// update afterwards if the values moved meanwhile.
    func updateReportedDisplay(pixelSize: CGSize? = nil, secondDisplay: Bool, secondPixelSize: CGSize? = nil) {
        if let pixelSize { reportedPixelSize = pixelSize }
        if let secondPixelSize { reportedSecondPixelSize = secondPixelSize }
        reportsSecondDisplay = secondDisplay
        guard task != nil, helloMade, !awaitingHelloAck else { return }
        // Re-evaluations that change nothing the host cares about (same size
        // after a window closed, say) must not make it rebuild its display.
        guard DisplayReport.differs(sent: helloReport, now: currentDisplayReport) else { return }
        sendDisplayUpdate()
    }

    private func sendDisplayUpdate() {
        guard let info = displayInfoPayload else { return }
        helloReport = currentDisplayReport // from here on: what the host last heard
        clogViewer("reporting display update: \(Int(info.widthPx))x\(Int(info.heightPx))px, second display \(info.secondDisplay)")
        send(StreamMessage.clientDisplays(widthPx: info.widthPx, heightPx: info.heightPx,
                                          secondDisplay: info.secondDisplay, secondSize: secondSizePayload))
    }

    /// The current report in comparable form (nil while no size is known).
    private var currentDisplayReport: DisplayReport? {
        guard let info = displayInfoPayload else { return nil }
        let second = secondSizePayload
        return DisplayReport(width: info.widthPx, height: info.heightPx, secondDisplay: info.secondDisplay,
                             secondWidth: second?.widthPx ?? 0, secondHeight: second?.heightPx ?? 0)
    }

    /// Main thread, on HELLO_ACK: updates were held back since the HELLO.
    private func helloAcknowledged() {
        guard awaitingHelloAck else { return }
        awaitingHelloAck = false
        if DisplayReport.differs(sent: helloReport, now: currentDisplayReport) { sendDisplayUpdate() }
    }

    /// User-initiated disconnect: stop reconnecting and tear down.
    func disconnect() {
        if wantConnection { clogViewer("disconnect requested by user") }
        wantConnection = false
        connectHost = nil
        reconnectAttempt = 0
        teardownSocket()
        status = .idle
        videoSize = .zero
        softwareEncoding = false
        currentBitrateKbps = 0
        hostLocked = false
        videoState = 0
        lastError = nil
        cursorPos = nil
        hostCapabilities = []
        authState = nil
        flowCarry = FlowCarry()
    }

    /// The Mac's browser VNC bridge (noVNC on http://<mac>:5901), derived from
    /// the connected host — the lock-screen fallback, since Apple's privileged
    /// screensharingd can reach a locked Mac where native capture can't. Works
    /// for a bare LAN host or ws:// URL (swap in the web port); a wss:// tunnel
    /// host reuses the same origin instead — the Cloudflare Tunnel config
    /// (README "Browser access") already routes that hostname's "/" to :5901
    /// and "/websockify" to :5902, and WebServer's own "/" handler detects
    /// the proxy and points noVNC at same-origin wss:// with no port override.
    var browserFallbackURL: URL? {
        guard let host = connectHost else { return nil }
        if host.contains("://") {
            guard let url = URL(string: host), let h = url.host else { return nil }
            if url.scheme == "wss" { return URL(string: "https://\(h)") }
            guard url.scheme == "ws" else { return nil }
            return URL(string: "http://\(h):5901") // WebServer.httpPort
        }
        return URL(string: "http://\(host):5901") // WebServer.httpPort
    }

    // MARK: Keepalive

    private func noteSent() {
        keepaliveLock.lock()
        keepalive.noteSent(at: ProcessInfo.processInfo.systemUptime)
        keepaliveLock.unlock()
    }

    /// PING after 20 s of sending nothing, so a still screen (no video, no
    /// input) does not let a NAT or tunnel drop the connection. The host's
    /// echo is ignored.
    private func startKeepalive() {
        keepaliveTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, self.task != nil else { return }
            self.keepaliveLock.lock()
            let due = self.keepalive.shouldPing(at: ProcessInfo.processInfo.systemUptime)
            self.keepaliveLock.unlock()
            if due { self.send(StreamMessage.frame(type: .ping)) }
        }
        keepaliveTimer = timer
        timer.resume()
    }

    private func teardownSocket() {
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
        if let a = current {
            current = nil
            wireQueue.async { a.ended = true; a.cancelTimers() }
            a.task.cancel(with: .normalClosure, reason: nil)
        }
        wireQueue.async { [weak self] in
            self?.wireAttempt = nil
            self?.assembler = nil
        }
        awaitingHelloAck = false
        helloMade = false
        hostCapabilities = []
        audio?.stop()
    }

    /// Drop detected: retry with capped exponential backoff unless the user
    /// asked to disconnect.
    private func scheduleReconnect() {
        guard wantConnection else { return }
        teardownSocket()
        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), 10) // 1,2,4,8,10,10…
        clogViewer("reconnect attempt \(reconnectAttempt) in \(Int(delay))s (retries forever until user disconnects)")
        DispatchQueue.main.async { self.status = .connecting }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.wantConnection else { return }
            self.openSocket()
        }
    }

    /// Each result hops onto wireQueue before it is used, and the next receive
    /// is asked for only from there, so messages are handled in arrival order.
    private func receiveLoop(_ a: Attempt) {
        a.task.receive { [weak self] result in
            guard let self else { return }
            self.wireQueue.async {
                guard !a.ended else { return }
                switch result {
                case .success(let message):
                    if case .data(let data) = message {
                        // A message proves the socket is open, even when the
                        // delegate's "open" has not run yet (the flow takes a
                        // challenge that comes first as the open).
                        if !a.opened {
                            a.opened = true
                            a.openTimer?.cancel()
                            a.openTimer = nil
                        }
                        a.parser.feed(data)
                        if a.parser.corrupt {
                            self.perform([.end(.failure, "the stream is corrupt")], on: a)
                            return
                        }
                    }
                    if !a.ended { self.receiveLoop(a) }
                case .failure(let error):
                    // A rejected WS upgrade (Cloudflare Access, wrong path) carries
                    // an HTTP status; a dead host/port doesn't. Log both so they're
                    // distinguishable after the fact.
                    var detail = error.localizedDescription
                    if let http = a.task.response as? HTTPURLResponse {
                        detail += " (HTTP \(http.statusCode)"
                        if http.statusCode == 403 || http.statusCode == 401 || http.statusCode == 302 {
                            detail += " — WS upgrade rejected, likely Cloudflare Access auth"
                        }
                        detail += ")"
                    }
                    let actions = a.flow.socketClosed()
                    // Empty: the flow closed this socket itself and is waiting
                    // for the user (rule 12), so this is no failure.
                    guard !actions.isEmpty else { return }
                    clogViewer("stream dropped: \(detail) — reconnecting")
                    let friendly = Self.friendlyError(error, response: a.task.response)
                    DispatchQueue.main.async { if self.current === a { self.lastError = friendly } }
                    self.perform(actions, on: a)
                }
            }
        }
    }

    private func handle(type: StreamMessageType, payload: Data) {
        switch type {
        case .helloAck:
            guard payload.count >= 10,
                  let codec = StreamCodec(rawValue: payload[payload.startIndex + 1]) else { return }
            let width = payload.beUInt32(at: 2), height = payload.beUInt32(at: 6)
            // flags byte (bit 0 = hardware encoder) is trailing; an older host
            // omits it — assume hardware, matching its refuse-to-start contract.
            let hardware = payload.count >= 11 ? (payload[payload.startIndex + 10] & 1) == 1 : true
            clogViewer("HELLO_ACK: \(codec == .hevc ? "HEVC" : "H.264") \(width)x\(height)\(hardware ? "" : " [SOFTWARE ENCODE on host]") — streaming")
            assembler = FrameAssembler(codec: codec)
            let codecName = codec == .hevc ? "HEVC" : "H.264"
            DispatchQueue.main.async {
                self.videoSize = CGSize(width: Double(width), height: Double(height))
                self.softwareEncoding = !hardware
                self.codecName = codecName
                self.lastError = nil // streaming actually started — clear any stale reason
                self.status = .streaming("\(codecName) \(width)x\(height)")
                self.helloAcknowledged()
            }
        case .streamStatus:
            guard payload.count >= 2 else { return }
            let kbps = payload.beUInt16(at: 0)
            DispatchQueue.main.async { self.currentBitrateKbps = kbps }
        case .hostLockState:
            guard let byte = payload.first else { return }
            let locked = byte == 1
            clogViewer("HOST_LOCK_STATE: host screen \(locked ? "LOCKED — showing browser VNC fallback" : "unlocked")")
            DispatchQueue.main.async { self.hostLocked = locked }
        case .videoState:
            guard let state = payload.first else { return }
            clogViewer("VIDEO_STATE: \(state == 0 ? "running" : state == 1 ? "host is rebuilding its encoder" : "host gave up rebuilding its encoder")")
            DispatchQueue.main.async { self.videoState = state }
        case .cursorPos:
            guard payload.count >= 8 else { return }
            let p = CGPoint(x: Double(payload.beFloat32(at: 0)), y: Double(payload.beFloat32(at: 4)))
            DispatchQueue.main.async { self.cursorPos = p }
        case .videoFrame:
            guard let sample = assembler?.assemble(payload: payload) else { return }
            onSampleBuffer?(sample)
        case .audioFrame:
            if playsAudio { audio?.play(aac: payload) }
        case .clipboard:
            if let text = String(data: payload, encoding: .utf8) {
                lastClipboard = text
                DispatchQueue.main.async { self.onClipboard?(text) }
            }
        case .fileOffer, .fileAnswer, .fileEnd, .fileData:
            // On wireQueue; the handler hops to the main thread itself.
            onFileMessage?(type.rawValue, payload)
        case .peripheralStatus:
            onPeripheralStatus?(payload)
        case .ping:
            break // echo of our keepalive: nothing to do
        case .authChallenge, .authResponse, .authResult, .hostInfo, .clientInfo,
             .devicePending, .deviceDecision, .secure:
            break // the auth layer will handle these
        default:
            break // client never receives hello/keyframeRequest
        }
    }

    // MARK: Input (normalized 0..1 display coordinates)

    /// Everything the app sends goes through the flow. Before the host is
    /// accepted it is dropped, never queued: keys pressed at a waiting screen
    /// must not reach the Mac later. After, it is sealed in call order.
    private func send(_ data: Data) {
        guard let a = current else { return }
        wireQueue.async { [weak self] in
            guard let self, !a.ended else { return }
            self.perform(a.flow.send(data), on: a)
        }
    }

    /// Like `send`, and `written` says whether the message was handed to the
    /// socket and written (false: dropped before the host was accepted, or the
    /// socket failed). Called on an arbitrary queue. File pieces wait for it, so
    /// a big file is never held in memory.
    func sendAndWait(_ data: Data, written: @escaping (Bool) -> Void) {
        guard let a = current else { written(false); return }
        wireQueue.async { [weak self] in
            guard let self, !a.ended else { written(false); return }
            let actions = a.flow.send(data)
            guard let last = actions.lastIndex(where: { if case .send = $0 { return true }; return false }),
                  case let .send(sealed) = actions[last] else {
                written(false)
                return
            }
            self.perform(Array(actions[..<last]), on: a)
            guard !a.ended else { written(false); return }
            self.noteSent()
            a.task.send(.data(sealed)) { error in written(error == nil) }
            self.perform(Array(actions[(last + 1)...]), on: a)
        }
    }

    /// Files this connection sends to the Mac.
    lazy var files = FileSendController(client: self)

    /// Set by the file sender and the controller bridge; both are called on
    /// the wire queue.
    var onFileMessage: ((UInt8, Data) -> Void)?
    var onPeripheralStatus: ((Data) -> Void)?

    /// A file message or a peripheral message: sealed like any other.
    func sendFrame(_ data: Data) { send(data) }

    func sendMouseMove(x: Float, y: Float) { send(StreamMessage.mouseMove(x: x, y: y)) }
    func sendMouseButton(button: UInt8, down: Bool, x: Float, y: Float) {
        send(StreamMessage.mouseButton(button: button, down: down, x: x, y: y))
    }
    /// Captured-pointer movement in points; only to a host with `relativeMouse`.
    func sendMouseRelative(dx: Float, dy: Float) {
        guard hostCapabilities.contains(.relativeMouse) else { return }
        send(StreamMessage.mouseRelative(dx: dx, dy: dy))
    }
    /// A press or release of a captured pointer, applied where the host cursor
    /// is; only to a host with `relativeMouse`. Returns false when not sent.
    @discardableResult
    func sendMouseButtonAtCursor(button: UInt8, down: Bool) -> Bool {
        guard hostCapabilities.contains(.relativeMouse) else { return false }
        send(StreamMessage.mouseButtonAtCursor(button: button, down: down))
        return true
    }
    /// Text with no key code (dictation, emoji, input-method output) as
    /// INPUT_TEXT. Returns false, sending nothing, when the host lacks
    /// `textInput`. Long text goes in pieces under the host's 16 KB limit.
    @discardableResult
    func sendText(_ text: String) -> Bool {
        guard hostCapabilities.contains(.textInput), !text.isEmpty else { return false }
        var piece = ""
        var bytes = 0
        for ch in text {
            let n = String(ch).utf8.count
            if bytes + n > 8 * 1024 {
                send(StreamMessage.text(piece))
                piece = ""; bytes = 0
            }
            piece.append(ch); bytes += n
        }
        if !piece.isEmpty { send(StreamMessage.text(piece)) }
        return true
    }
    func sendScroll(dx: Float, dy: Float) { send(StreamMessage.scroll(dx: dx, dy: dy)) }
    func sendKey(macKeyCode: UInt16, down: Bool, flags: UInt64) {
        send(StreamMessage.key(macKeyCode: macKeyCode, down: down, flags: flags))
    }
    /// Push local pasteboard text to the Mac, skipping text we just received.
    func syncClipboard(_ text: String) {
        guard !text.isEmpty, text != lastClipboard else { return }
        lastClipboard = text
        send(StreamMessage.clipboard(text: text))
    }
    func requestKeyframe() { send(StreamMessage.frame(type: .keyframeRequest)) }
}

import os

/// Client-side diagnostic log, mirroring the Mac host's `clog` convention.
/// Goes to the unified log — readable live in Console.app with the device
/// attached, or after the fact via `log collect --device` /
/// `log stream --predicate 'subsystem == "com.frindle.clamshell.viewer"'`.
private let viewerLogger = Logger(subsystem: "com.frindle.clamshell.viewer", category: "stream")

func clogViewer(_ message: String) {
    viewerLogger.notice("\(message, privacy: .public)")
    #if DEBUG
    print("[ClamshellViewer] \(message)")
    #endif
}
