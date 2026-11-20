import Foundation
import Network
@preconcurrency import ScreenCaptureKit
import CoreMedia
import VideoToolbox

// Host side of the stream: ScreenCaptureKit capture of one display (or, for
// Window Handoff, one window) -> hardware VideoToolbox encode -> framed
// messages over one TCP connection. Receives input messages on the same
// connection and injects them. One client at a time; a new connection
// replaces the current one.

/// What this server captures. A window capture is video+input only — no
/// audio/clipboard/cursor-follow/lock-state/client-display-reporting, all of
/// which are display concepts (see the `isPrimary`-gated features below and
/// PROTOCOL.md's v1 sections they implement). ponytail: window audio capture
/// (SCContentFilter supports it) is skipped for v1 — add if silent remoted
/// apps turn out to matter.
enum StreamSource {
    case display(CGDirectDisplayID)
    case window(UInt32)
}

extension StreamServer {
    /// Resolves the current target display ID, preferring:
    /// a. the original display if it's still present in shareable content,
    /// b. otherwise an active VIRTUAL display if one exists,
    /// c. otherwise CGMainDisplayID() if that is present in shareable content.
    /// Returns nil if nothing at all can be found.
    func resolveCurrentTargetDisplayID(content: SCShareableContent, originalDisplayID: CGDirectDisplayID) -> CGDirectDisplayID? {
        // a. Try the display it was originally constructed with
        if content.displays.contains(where: { $0.displayID == originalDisplayID }) {
            clog("STREAM: using original display \(originalDisplayID)")
            return originalDisplayID
        }
        
        // b. Any of OUR virtual displays, identified by the vendor/product IDs
        // VirtualDisplayController stamps on them. Do NOT construct a
        // VirtualDisplayController here to ask: its `displays` map is
        // per-instance state and the live one is private to
        // CollapseCoordinator, so a fresh instance is always empty and this
        // branch would never fire.
        if let ours = content.displays.first(where: { d in
            CGDisplayVendorNumber(d.displayID) == VirtualDisplayController.vendorID
                && CGDisplayModelNumber(d.displayID) == VirtualDisplayController.productID
        }) {
            clog("STREAM: original display gone; using virtual display \(ours.displayID)")
            return ours.displayID
        }

        // c. Fall back to main display if present in shareable content
        let mainDisplay = CGMainDisplayID()
        if content.displays.contains(where: { $0.displayID == mainDisplay }) {
            clog("STREAM: using main display \(mainDisplay)")
            return mainDisplay
        }
        
        // Nothing found at all
        clog("STREAM: no suitable display found in shareable content")
        return nil
    }

    /// Re-evaluate the capture target when a display configuration change occurs.
    /// This method is called by StreamFleet to handle reconfiguration events.
    func updateCaptureTarget() {
        // We can't easily restart an active stream without tearing down clients,
        // but we've already made the system resilient in startSession()
        clog("STREAM: Capture target updated due to display configuration change")
    }
}

// @unchecked Sendable: all mutable state is confined to the serial `queue`.
final class StreamServer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let source: StreamSource
    private let port: UInt16
    /// The primary server (main display, base port) also carries system audio
    /// and clipboard sync; secondary displays are video+input only.
    private let isPrimary: Bool
    /// Listen on this machine's loopback address only. For selftests, so a
    /// test listener is never reachable from the network.
    private let loopbackOnly: Bool
    /// False for a listener that must never capture the screen or inject
    /// input, whatever a client sends: a HELLO is then logged and ignored, so
    /// no capture session, encoder, clipboard bridge or input injector starts.
    /// Only the test host in `AuthInteropHost` and the gate selftest turn it off.
    private let startsMedia: Bool
    /// How many times a HELLO got as far as starting a capture session (read
    /// through `mediaStartCount`; touched on `queue`).
    private var mediaStarts = 0

    private var listener: NWListener?
    /// Decides which connections get in (see StreamLink.swift). Nothing in
    /// this class runs for a connection the gate has not handed over.
    private let gate: StreamGate
    private let auth: HostAuth
    /// The client being served, and its socket. `connection` doubles as the
    /// identity of the session in the async paths below.
    private var liveLink: StreamLink?
    private var connection: NWConnection?
    private var stream: SCStream?
    /// Read from the capture queue for every frame and replaced on `queue` when
    /// the stream is resized in place, so access goes through a lock.
    private let encoderLock = NSLock()
    private var encoderStorage: VideoEncoder?
    private var encoder: VideoEncoder? {
        get { encoderLock.lock(); defer { encoderLock.unlock() }; return encoderStorage }
        set { encoderLock.lock(); encoderStorage = newValue; encoderLock.unlock() }
    }
    private var audioEncoder: AudioEncoder?
    private var clipboard: ClipboardBridge?
    private var injector: InputInjector?
    /// True only in the login-window agent. Then the host tells clients it
    /// takes LOGIN_CREDENTIALS and types them (see `handleLoginCredentials`).
    var acceptsLoginCredentials = false {
        didSet { gate.advertisesLoginCredentials = acceptsLoginCredentials }
    }
    private var lastLoginCredentialsAt: TimeInterval?
    /// What the connected device may bring along. Each exists only for a
    /// device that was let in and set the matching capability bit (see
    /// `admitted`), and ends with the connection.
    private var fileSession: HostFileSession?
    /// True for a primary connection whose device set capability bit 7 (restart).
    private var restartAllowed = false
    private var restartFailures = 0
    private var peripheralSession: HostPeripheralSession?
    /// Drives the time-based parts of the two above; runs only while one exists.
    private var deviceTimer: DispatchSourceTimer?
    private let audioQueue = DispatchQueue(label: "clamshell.stream.audio")

    /// Serial queue owning all connection/session state.
    private let queue: DispatchQueue
    private let videoQueue = DispatchQueue(label: "clamshell.stream.video")

    /// Send backpressure: frames handed to NWConnection but not yet consumed.
    /// TCP on LAN drains fast; if it backs up, the pacer drops frames until
    /// the next keyframe resynchronizes the decoder, and reports a stalled
    /// connection (see SendPacer).
    private var pacer = SendPacer()

    /// Geometry of the live capture session (on `queue`), so a change of the
    /// display's pixel size can be noticed and the session resized in place.
    private var captureDisplayID: CGDirectDisplayID?
    private var sessionWidthPx = 0
    private var sessionHeightPx = 0
    private var sessionRefresh: Double = 60
    private var resizing = false

    /// A HELLO has already started (or is starting) this connection's capture
    /// session. A repeat HELLO must not start a second one: the first
    /// SCStream/encoder would be orphaned and keep running.
    private var sessionRequested = false

    /// This session's client reported display info (and so may have driven a
    /// collapse) — on teardown, schedule the matching restore request.
    private var clientAnnounced = false

    /// Whether the Mac's screen is currently locked (fed by StreamFleet's
    /// lock-notification observer). Pushed to the client as HOST_LOCK_STATE on
    /// every change and once right after HELLO_ACK, so a client that connects to
    /// an already-locked Mac immediately shows the browser-VNC fallback banner.
    private var hostLocked = false

    // Adaptive bitrate (see PROTOCOL.md "Adaptive bitrate"): reactive, driven
    // purely by the send-queue backpressure above. A full send queue means the
    // network can't drain 20 Mbps — halve the encoder bitrate (min once per
    // second, floor 2 Mbps). After 5 s without congestion, step back up by 25%
    // (min 5 s between up-steps, ceiling 20 Mbps).
    // Matches VideoEncoder's own cold-start value — see its comment on
    // kVTCompressionPropertyKey_AverageBitRate for why this starts low.
    private var bitrate = VideoEncoder.minBitrate
    private var lastCongestionAt: CFAbsoluteTime = 0
    private var lastStepAt: CFAbsoluteTime = 0

    // Cursor-follow auto-pan (see PROTOCOL.md): a lightweight, throttled
    // CURSOR_POS report so the client can auto-pan its viewport without the
    // cursor being decoded from pixels. 20 Hz is plenty for a smooth-feeling
    // follow and is trivial bandwidth (14 bytes/msg) next to the video stream.
    private var cursorTimer: DispatchSourceTimer?
    private var lastSentCursor: CGPoint?

    /// Clipboard text from the client larger than this is ignored.
    static let maxClipboardBytes = 1 << 20

    /// `displayIndex` is this listener's place among the host's displays
    /// (0 = Display A), told to clients in HOST_INFO; nil for a window.
    init(source: StreamSource, port: UInt16 = streamDefaultPort, isPrimary: Bool = true,
         auth: HostAuth = .shared, displayIndex: Int? = nil, loopbackOnly: Bool = false,
         startsMedia: Bool = true) {
        self.source = source
        self.port = port
        self.isPrimary = isPrimary
        self.loopbackOnly = loopbackOnly
        self.startsMedia = startsMedia
        self.auth = auth
        let queue = DispatchQueue(label: "clamshell.stream")
        self.queue = queue
        gate = StreamGate(auth: auth, queue: queue, label: "port \(port)")
        super.init()
        gate.displayIndex = displayIndex
        gate.advertisesDeviceFeatures = isPrimary
        gate.onAdmit = { [weak self] link in self?.admitted(link) }
        gate.onMessage = { [weak self] link, type, payload in
            guard let self, link === self.liveLink else { return }
            self.handle(type: type, payload: payload)
        }
        gate.onClose = { [weak self] link in
            guard let self, link === self.liveLink else { return }
            self.teardownSession()
        }
    }

    convenience init(displayID: CGDirectDisplayID, port: UInt16 = streamDefaultPort, isPrimary: Bool = true,
                     auth: HostAuth = .shared, displayIndex: Int? = nil) {
        self.init(source: .display(displayID), port: port, isPrimary: isPrimary,
                  auth: auth, displayIndex: displayIndex)
    }

    func start() throws {
        // WebSocket over TCP (not raw TCP) so the stream can ride through a
        // Cloudflare Tunnel's HTTP path; the binary framing inside is unchanged.
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        // Nothing a client sends is anywhere near this size; the room above
        // the largest message is for the SECURE wrapping.
        ws.maximumMessageSize = StreamGate.sessionMaxPayload + 4096
        // The upgrade request's headers say who is behind a proxy (see
        // ClientAddress); the gate reads them when the connection is ready.
        let upgradeHeaders = gate.upgradeHeaders
        ws.setClientRequestHandler(queue) { _, headers in
            upgradeHeaders.record(headers)
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            clog("STREAM: invalid listen port \(port)")
            throw NWError.posix(.EINVAL)
        }
        let listener: NWListener
        if loopbackOnly {
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
            listener = try NWListener(using: params)
        } else {
            listener = try NWListener(using: params, on: nwPort)
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.queue.async { self?.accept(conn) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            clog("STREAM: listener \(state)")
            if case .failed = state { self?.listenerFailed(listener) }
        }
        listener.start(queue: queue)
        self.listener = listener
        auth.startWatchingSetting()
        clog("STREAM: listening on port \(port)\(loopbackOnly ? " (this machine only)" : "") for \(source) — device approval is \(auth.requireApproval ? "on" : "OFF")")
    }

    // The bind happens after start() returns, so "port still in use" (the
    // login-window agent on its way out, or the previous instance during an
    // update relaunch) only shows up as a failed listener. Try again a few
    // times instead of leaving the port dead until the next topology change.
    private var stopped = false
    private var listenRetries = 0
    private static let maxListenRetries = 8

    /// On `queue` (listener state handlers are delivered there).
    private func listenerFailed(_ failed: NWListener?) {
        guard !stopped, let failed, failed === listener else { return }
        failed.cancel()
        listener = nil
        guard listenRetries < Self.maxListenRetries else {
            clog("STREAM: port \(port) still unavailable after \(listenRetries) tries — giving up")
            return
        }
        listenRetries += 1
        let attempt = listenRetries
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.stopped, self.listener == nil else { return }
            clog("STREAM: retrying listen on port \(self.port) (try \(attempt) of \(Self.maxListenRetries))")
            do { try self.start() } catch { clog("STREAM: retry on port \(self.port) failed: \(error)") }
        }
    }

    /// `completion` fires only once the listener has actually released its
    /// port (NWListener.cancel() is itself fire-and-forget) — callers that
    /// start a new listener on the same port right after stop() must wait
    /// for this, or the bind races the old socket's teardown and fails with
    /// EADDRINUSE. Confirmed live 2026-07-31: this raced during
    /// collapse/restore, the resulting failed bind cancelled the
    /// connection, which looked like the client dropping and reconnecting
    /// in an infinite loop.
    func stop(completion: @escaping () -> Void = {}) {
        queue.async { [self] in
            stopped = true
            teardownSession()
            gate.closeAll(why: "the listener is stopping")
            if let l = listener {
                l.stateUpdateHandler = { state in
                    clog("STREAM: listener \(state)")
                    if case .cancelled = state { completion() }
                }
                l.cancel()
            } else {
                completion()
            }
            listener = nil
        }
    }

    /// Force-disconnect the current client (Diagnostics "Disconnect All").
    func disconnectClient() {
        queue.async { [self] in teardownSession() }
    }

    /// Update the host lock state (from StreamFleet's lock observer). Stores it
    /// for the next HELLO_ACK and, if a client is connected, pushes it now.
    func setLockState(_ locked: Bool) {
        queue.async { [self] in
            hostLocked = locked
            guard connection != nil else { return }
            send(StreamMessage.hostLockState(locked, native: StreamMessage.nativeLockScreenEnabled()))
        }
    }

    /// Snapshot for the Diagnostics view (read from the main queue).
    var portNumber: UInt16 { port }
    var primary: Bool { isPrimary }
    var isClientConnected: Bool { queue.sync { connection != nil } }
    /// How many HELLOs have started a capture session on this server. Always 0
    /// when `startsMedia` is false.
    var mediaStartCount: Int { queue.sync { mediaStarts } }
    /// Whether an input injector exists (only a started session creates one).
    var hasInputInjector: Bool { queue.sync { injector != nil } }

    // MARK: - Connection lifecycle (on `queue`)

    /// A connection arrived. It belongs to the gate until the gate lets it
    /// in; until then it cannot disturb the client being served.
    private func accept(_ conn: NWConnection) {
        listenRetries = 0 // a connection reached us, so the port is ours
        gate.accept(conn)
    }

    /// The gate let this connection in: it is the client from now on.
    private func admitted(_ link: StreamLink) {
        if liveLink != nil || connection != nil {
            clog("STREAM: new client replaces existing connection")
            teardownSession()
        }
        liveLink = link
        connection = link.conn
        sessionRequested = false
        startDeviceSessions(for: link)
    }

    /// Creates what the device's capability bits ask for. A connection with no
    /// handshake (a host with approval off, a client that never answered the
    /// challenge) has no device and so no bits: it never transfers files.
    private func startDeviceSessions(for link: StreamLink) {
        // Files and controllers belong to the primary connection only; a
        // secondary display's connection must not get sessions or a timer.
        guard isPrimary else { return }
        guard let device = link.device else { return }
        restartAllowed = link.phase == .accepted && device.capabilities.contains(.restart)
        restartFailures = 0
        if HostFileSession.allowed(phase: link.phase, capabilities: device.capabilities) {
            let name = device.name
            fileSession = HostFileSession(onStored: { url in
                HostNotice.post(title: "File received",
                                body: "\(url.lastPathComponent) from \(name) is in Downloads/Clamshell.")
            })
        }
        if HostPeripheralSession.allowed(phase: link.phase, capabilities: device.capabilities) {
            // Controller events take the same path INPUT_* messages do: the
            // injector, looked up when used because a session may not have
            // started yet.
            let session = HostPeripheralSession(device: device.name, output: LiveInjector(server: self))
            PeripheralHub.shared.register(session: session.sessionId) { [weak self, weak session] id in
                self?.queue.async {
                    guard let self, let session, self.peripheralSession === session else { return }
                    for frame in session.removeByHost(id: id) { self.send(frame) }
                }
            }
            peripheralSession = session
        }
        if fileSession != nil || peripheralSession != nil { startDeviceTimer() }
    }

    /// Forwards to whatever injector the server has now (on `queue`).
    private final class LiveInjector: GamepadOutput {
        private unowned let server: StreamServer
        init(server: StreamServer) { self.server = server }
        func mouseRelative(dx: Float32, dy: Float32) { server.injector?.mouseRelative(dx: dx, dy: dy) }
        func mouseButtonAtCursor(button: UInt8, down: Bool) {
            server.injector?.mouseButtonAtCursor(button: button, down: down)
        }
        func scroll(dx: Float32, dy: Float32) { server.injector?.scroll(dx: dx, dy: dy) }
        func key(macKeyCode: UInt16, down: Bool, flags: UInt64) {
            server.injector?.key(macKeyCode: macKeyCode, down: down, flags: flags)
        }
    }

    private func startDeviceTimer() {
        guard deviceTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.016, repeating: 0.016, leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in self?.deviceTick() }
        timer.resume()
        deviceTimer = timer
    }

    private func deviceTick() {
        let now = ProcessInfo.processInfo.systemUptime
        for frame in fileSession?.tick(now: now) ?? [] { send(frame) }
        for frame in peripheralSession?.tick(now: now) ?? [] { send(frame) }
    }

    private func teardownSession() {
        guard connection != nil || stream != nil else { return }
        if clientAnnounced {
            clientAnnounced = false
            scheduleRestorePost()
        }
        let link = liveLink
        liveLink = nil
        connection = nil
        if let link { gate.close(link, why: "the session ended") }
        pacer.reset()
        sessionRequested = false
        bitrate = VideoEncoder.minBitrate
        lastCongestionAt = 0
        lastStepAt = 0
        cursorTimer?.cancel()
        cursorTimer = nil
        lastSentCursor = nil
        if let s = stream {
            s.stopCapture { _ in }
            stream = nil
        }
        encoder?.invalidate()
        encoder = nil
        captureDisplayID = nil
        resizing = false
        audioEncoder = nil
        clipboard?.stop()
        clipboard = nil
        deviceTimer?.cancel()
        deviceTimer = nil
        // Controllers first: they release their keys and buttons through the
        // injector, which is then released as a whole.
        peripheralSession?.closeAll()
        peripheralSession = nil
        injector?.releaseAll()
        injector = nil
        fileSession?.closeAll()
        fileSession = nil
        restartAllowed = false
    }

    // MARK: - Messages (on `queue`)

    private func handle(type: StreamMessageType, payload: Data) {
        switch type {
        case .hello:
            guard payload.count >= 2 else { return }
            let requested = StreamCodec(rawValue: payload[payload.startIndex + 1]) ?? .hevc
            handleClientDisplayInfo(payload, at: 2)
            guard !sessionRequested else {
                clog("STREAM: repeat HELLO on a live session — keeping the session, sending a keyframe")
                encoder?.requestKeyframe()
                return
            }
            sessionRequested = true
            startSession(requestedCodec: requested)
        case .clientDisplays:
            handleClientDisplayInfo(payload, at: 0)
        case .ping:
            // Keepalive from a client that was otherwise quiet: answer so the
            // path carries traffic both ways (a still screen sends no video).
            send(StreamMessage.frame(type: .ping, payload: Data()))
        case .keyframeRequest:
            encoder?.requestKeyframe()
        case .mouseMove, .mouseButton, .key, .scroll, .mouseRelative, .mouseButtonAtCursor, .text:
            guard let input = InputMessage.decode(type: type, payload: payload) else { return }
            switch input {
            case let .mouseMove(x, y): injector?.mouseMove(x: x, y: y)
            case let .mouseButton(button, down, x, y): injector?.mouseButton(button: button, down: down, x: x, y: y)
            case let .key(code, down, flags): injector?.key(macKeyCode: code, down: down, flags: flags)
            case let .scroll(dx, dy): injector?.scroll(dx: dx, dy: dy)
            case let .mouseRelative(dx, dy): injector?.mouseRelative(dx: dx, dy: dy)
            case let .mouseButtonAtCursor(button, down): injector?.mouseButtonAtCursor(button: button, down: down)
            case let .text(data): injector?.text(data)
            }
        case .clipboard:
            guard payload.count <= Self.maxClipboardBytes else {
                clog("STREAM: ignored \(payload.count) bytes of clipboard text from the client (limit \(Self.maxClipboardBytes))")
                return
            }
            if let text = String(data: payload, encoding: .utf8) { clipboard?.receiveFromClient(text) }
        case .authChallenge, .authResponse, .authResult, .hostInfo, .clientInfo,
             .devicePending, .deviceDecision, .secure:
            break // the gate deals with these; here they mean nothing
        case .helloAck, .videoFrame, .audioFrame, .streamStatus, .hostLockState, .cursorPos, .videoState:
            break // host never receives these
        case .fileOffer, .fileData, .fileEnd:
            // Only a session made for a device that set the bit has one.
            guard let files = fileSession else { return }
            for frame in files.receive(type: type.rawValue, payload: payload,
                                       now: ProcessInfo.processInfo.systemUptime) { send(frame) }
        case .fileAnswer:
            break // the host never offers a file, so there is nothing to answer
        case .loginCredentials:
            handleLoginCredentials(payload)
        case .restartRequest:
            // The user name and password arrive inside the encrypted session, are used for
            // this one call and are never logged or kept (RestartService).
            guard restartAllowed, payload.count <= 1024,
                  let body = try? JSONSerialization.jsonObject(with: payload) as? [String: String],
                  let user = body["username"], let password = body["password"] else { return }
            restartAllowed = false // one at a time
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let outcome = RestartService.restart(username: user, password: password)
                clog("RESTART: authrestart result \(outcome)")
                self?.queue.async {
                    self?.send(StreamMessage.frame(type: .restartResult, payload: Data([outcome.rawValue])))
                    if outcome != .restarting, let self {
                        self.restartFailures += 1
                        self.restartAllowed = self.restartFailures < 3 // three wrong tries per connection
                    }
                }
            }
        case .restartResult:
            break // host to client only
        case .peripheralAttach, .peripheralDetach, .peripheralInput:
            // Only a session made for a device that set the bit has one.
            guard let peripherals = peripheralSession else { return }
            for frame in peripherals.receive(type: type.rawValue, payload: payload,
                                             now: ProcessInfo.processInfo.systemUptime) { send(frame) }
        case .peripheralStatus, .peripheralOutput:
            break // host to client only (rumble is not sent in this version)
        }
    }

    /// A saved login from the client, typed into the login window. Acts only
    /// in the login-window agent, on the encrypted session of a device that
    /// set the capability bit, and at most once every few seconds. Nothing
    /// about the contents is logged.
    private func handleLoginCredentials(_ payload: Data) {
        let now = ProcessInfo.processInfo.systemUptime
        guard let link = liveLink,
              LoginCredentialsPolicy.allowed(serving: acceptsLoginCredentials, phase: link.phase,
                                             capabilities: link.device?.capabilities),
              LoginCredentialsPolicy.rateAllows(last: lastLoginCredentialsAt, now: now) else { return }
        lastLoginCredentialsAt = now
        guard let credentials = LoginCredentials.decode(payload) else {
            clog("STREAM: ignored a malformed login from the client")
            return
        }
        clog("STREAM: typing a login from \(link.device?.fingerprint ?? "a device") at the login window")
        injector?.text(credentials.typingPayload)
    }

    // MARK: - Client display info -> host auto-configuration (on `queue`)

    /// Posts the `collapse` distributed notification. Swappable so
    /// `hello-collapse-selftest` can capture posts without collapsing the
    /// running app.
    static var postCollapse: ([String: String]) -> Void = { info in
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.frindle.clamshell.collapse"), object: nil,
            userInfo: info, deliverImmediately: true)
    }

    /// The client reports its real screen size (and whether it has a second
    /// display surface) in HELLO / CLIENT_DISPLAYS. Forward it to the menu
    /// bar app over the same distributed-notification channel Sunshine's
    /// prep-command uses, so the virtual display gets auto-sized to the
    /// device (and dual mode auto-toggled) without a manual preset pick.
    /// Only the primary connection speaks for the client; secondary display
    /// connections would otherwise fight over the geometry.
    func handleClientDisplayInfo(_ payload: Data, at offset: Int) {
        guard isPrimary, let req = ClientDisplayRequest.parse(payload, at: offset) else { return }
        clientAnnounced = true
        let second = req.secondDisplay
            ? " + second display\(req.secondWidthPx.map { " \($0)x\(req.secondHeightPx ?? 0)px" } ?? "")" : ""
        clog("STREAM: client reports \(req.widthPx)x\(req.heightPx)px\(req.oneX ? " @1x" : "")\(second) — requesting collapse")
        let info = req.userInfo
        DispatchQueue.main.async {
            Self.pendingRestorePost?.cancel()
            Self.pendingRestorePost = nil
            Self.postCollapse(info)
        }
    }

    /// Restore is posted only after a grace period with no announcing client:
    /// viewer reconnects (network blips, and this process rebuilding servers
    /// on display-topology changes) must not thrash the collapse. Static
    /// because a topology rebuild replaces server instances mid-session — the
    /// reconnecting client's HELLO on the *new* primary must cancel the *old*
    /// instance's scheduled restore. Main-queue confined.
    private static var pendingRestorePost: DispatchWorkItem?

    private func scheduleRestorePost() {
        DispatchQueue.main.async {
            Self.pendingRestorePost?.cancel()
            let work = DispatchWorkItem {
                Self.pendingRestorePost = nil
                clog("STREAM: no client for 15s — requesting restore")
                DistributedNotificationCenter.default().postNotificationName(
                    Notification.Name("com.frindle.clamshell.restore"), object: nil,
                    userInfo: ["source": "stream"], deliverImmediately: true)
            }
            Self.pendingRestorePost = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
        }
    }

    // MARK: - Capture session

    private func startSession(requestedCodec: StreamCodec) {
        guard startsMedia else {
            clog("STREAM: HELLO ignored — this listener starts no capture and no input")
            return
        }
        mediaStarts += 1
        let source = self.source
        // Pin this session to the connection that sent HELLO. A second client
        // can connect (tearing down `connection` and installing a new one)
        // during the awaits below; without this check the new connection would
        // inherit this session's stream/encoder while the old one leaks.
        let sessionConn = self.connection
        Task {
            do {
                // Distinguish "permission denied" from other capture failures up
                // front — SCShareableContent's error alone is cryptic.
                if !CGPreflightScreenCaptureAccess() {
                    clog("STREAM: WARNING — Screen Recording permission NOT granted; capture will fail. Grant it in System Settings > Privacy & Security > Screen Recording.")
                }

                let (filter, pxWidth, pxHeight, refresh): (SCContentFilter, Int, Int, Double)
                // The display actually captured. It can differ from the one
                // this server was created for (see resolveCurrentTargetDisplayID),
                // and input and cursor reports must use the same one.
                let capturedDisplayID: CGDirectDisplayID?
                switch source {
                case .display(let displayID):
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    
                    // Resolve the current target display ID with fallback logic
                    guard let resolvedDisplayID = self.resolveCurrentTargetDisplayID(content: content, originalDisplayID: displayID) else {
                        clog("STREAM: no suitable display found for capture")
                        self.failSession(sessionConn)
                        return
                    }
                    
                    // Use the resolved display ID to find the actual SCDisplay object
                    guard let scDisplay = content.displays.first(where: { $0.displayID == resolvedDisplayID }) else {
                        clog("STREAM: resolved display \(resolvedDisplayID) not found in shareable content")
                        self.failSession(sessionConn)
                        return
                    }
                    
                    // Native pixel resolution and refresh rate — no scaling in
                    // the capture path; the encoder sees exactly what the
                    // display shows.
                    let mode = CGDisplayCopyDisplayMode(resolvedDisplayID)
                    pxWidth = mode?.pixelWidth ?? scDisplay.width
                    pxHeight = mode?.pixelHeight ?? scDisplay.height
                    if let rate = mode?.refreshRate, rate > 0 { refresh = rate } else { refresh = 60 }
                    filter = SCContentFilter(display: scDisplay, excludingWindows: [])
                    capturedDisplayID = resolvedDisplayID
                case .window(let windowID):
                    // Window Handoff (PROTOCOL.md): explicit-selection v1, no
                    // AX-based hide/drag-trigger (blocked on this dev Mac —
                    // see WindowHandoff/WindowHideSelfTest.swift), so the
                    // window is captured wherever it currently sits.
                    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                    guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
                        clog("STREAM: window \(windowID) not found (closed, minimized, or off-screen?)")
                        self.failSession(sessionConn)
                        return
                    }
                    // ponytail: points-resolution capture, not the window's
                    // real backing-store pixel size (no cheap way to read a
                    // window's owning screen's backingScaleFactor from
                    // SCWindow alone) — upgrade if Retina windows look soft.
                    pxWidth = max(Int(scWindow.frame.width), 1)
                    pxHeight = max(Int(scWindow.frame.height), 1)
                    refresh = 60
                    filter = SCContentFilter(desktopIndependentWindow: scWindow)
                    capturedDisplayID = nil
                }

                let encoder = try VideoEncoder.makeEncoder(
                    width: Int32(pxWidth), height: Int32(pxHeight), preferred: requestedCodec)

                // Only the primary display carries system audio — one capture,
                // no separate Core Audio tap. Windows never do (see StreamSource).
                let audioEncoder = self.isPrimary ? AudioEncoder() : nil
                let config = self.makeConfiguration(width: pxWidth, height: pxHeight, refresh: refresh,
                                                    withAudio: audioEncoder != nil)

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.videoQueue)
                if audioEncoder != nil {
                    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.audioQueue)
                }
                try await stream.startCapture()

                self.queue.async {
                    // Require the *same* connection that started this session:
                    // nil means the client vanished, a different object means a
                    // second client replaced it mid-setup. Either way this
                    // stream/encoder is orphaned — tear it down, don't attach.
                    guard self.connection === sessionConn, self.connection != nil else {
                        stream.stopCapture { _ in }
                        encoder.invalidate()
                        return
                    }
                    self.attachFrameHandler(to: encoder)
                    self.encoder = encoder
                    self.captureDisplayID = capturedDisplayID
                    self.sessionWidthPx = pxWidth
                    self.sessionHeightPx = pxHeight
                    self.sessionRefresh = refresh
                    self.stream = stream
                    if let audioEncoder {
                        audioEncoder.onEncodedPacket = { [weak self] aac in
                            self?.queue.async {
                                guard self?.connection != nil else { return }
                                self?.send(StreamMessage.audioFrame(aac))
                            }
                        }
                        self.audioEncoder = audioEncoder
                    }
                    if self.isPrimary {
                        let clipboard = ClipboardBridge()
                        clipboard.onLocalChange = { [weak self] text in
                            self?.queue.async {
                                guard self?.connection != nil else { return }
                                // The same limit both ways: a client is not
                                // sent more than the host would take from it.
                                guard text.utf8.count <= Self.maxClipboardBytes else {
                                    clog("STREAM: did not send \(text.utf8.count) bytes of clipboard text to the client (limit \(Self.maxClipboardBytes))")
                                    return
                                }
                                self?.send(StreamMessage.clipboard(text: text))
                            }
                        }
                        clipboard.start()
                        self.clipboard = clipboard
                    }
                    switch source {
                    case .display(let displayID):
                        self.injector = InputInjector(displayID: capturedDisplayID ?? displayID)
                    case .window(let windowID): self.injector = InputInjector(windowID: windowID)
                    }
                    self.send(StreamMessage.helloAck(codec: encoder.codec,
                                                     width: UInt32(pxWidth), height: UInt32(pxHeight),
                                                     hardwareEncoder: encoder.isHardware))
                    self.sendStreamStatus() // initial bitrate for the quality indicator
                    self.send(StreamMessage.hostLockState(self.hostLocked, native: StreamMessage.nativeLockScreenEnabled())) // so a client joining a locked Mac knows now
                    // Cursor-follow auto-pan is a display concept (see
                    // PROTOCOL.md) — a remoted window has no "different
                    // display" to report positions relative to.
                    if case .display(let displayID) = source {
                        self.startCursorReporting(displayID: capturedDisplayID ?? displayID)
                    }
                    clog("STREAM: session started — \(encoder.codec) \(pxWidth)x\(pxHeight)@\(Int(refresh.rounded()))\(encoder.isHardware ? "" : " [SOFTWARE ENCODE]")")
                }
            } catch {
                clog("STREAM: failed to start capture session: \(error)")
                self.failSession(sessionConn)
            }
        }
    }

    /// The capture configuration for a session of this pixel size. Shared by
    /// the first start and an in-place resize (`updateConfiguration` needs the
    /// whole configuration again, audio settings included).
    private func makeConfiguration(width: Int, height: Int, refresh: Double, withAudio: Bool) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(refresh.rounded()))
        // NV12 full range is the hardware encoder's native input —
        // no format conversion between capture and encode.
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.queueDepth = 5
        // A remoted window shouldn't carry the source Mac's own
        // cursor into the frame; a whole display should.
        if case .window = source {
            config.showsCursor = false
        } else {
            config.showsCursor = true
        }
        if withAudio {
            config.capturesAudio = true
            config.sampleRate = 48000
            config.channelCount = 2
        }
        return config
    }

    private func attachFrameHandler(to encoder: VideoEncoder) {
        encoder.onEncodedFrame = { [weak self, weak encoder] keyframe, pts, nalData in
            self?.queue.async {
                // A callback that fired just before an in-place resize swapped
                // encoders must not send its old-size frame after the new HELLO_ACK.
                guard let self, let encoder, self.encoder === encoder else { return }
                self.sendFrame(keyframe: keyframe, ptsMicros: pts, nalData: nalData)
            }
        }
    }

    // MARK: - Resize in place (on `queue`)

    /// The virtual display changed size (the browser picked another monitor
    /// size, or its window was resized). Called by StreamFleet from any queue.
    /// The mode change can land a moment after the request, so look again
    /// for a few seconds before giving up.
    func displaySizeMayHaveChanged() {
        queue.async { [self] in checkDisplaySize(retriesLeft: 6) }
    }

    private func checkDisplaySize(retriesLeft: Int) {
        guard case .display = source, let stream, let oldEncoder = encoder, let did = captureDisplayID,
              connection != nil, !resizing else { return }
        let mode = CGDisplayCopyDisplayMode(did)
        switch SessionResize.decide(sessionWidthPx: sessionWidthPx, sessionHeightPx: sessionHeightPx,
                                    displayWidthPx: mode?.pixelWidth, displayHeightPx: mode?.pixelHeight) {
        case .keep:
            if retriesLeft > 0 {
                queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.checkDisplaySize(retriesLeft: retriesLeft - 1) }
            }
        case .rebuild(let w, let h):
            resizing = true
            let sessionConn = connection
            let refresh = sessionRefresh
            let withAudio = isPrimary
            clog("STREAM: display is now \(w)x\(h) (was \(sessionWidthPx)x\(sessionHeightPx)) — resizing the stream without reconnecting")
            Task {
                do {
                    // New encoder first: if the new size cannot be encoded at all,
                    // nothing has been touched yet.
                    let newEncoder = try VideoEncoder.makeEncoder(width: Int32(w), height: Int32(h), preferred: oldEncoder.codec)
                    do {
                        try await stream.updateConfiguration(
                            self.makeConfiguration(width: w, height: h, refresh: refresh, withAudio: withAudio))
                    } catch {
                        newEncoder.invalidate()
                        throw error
                    }
                    self.queue.async {
                        self.finishResize(stream: stream, sessionConn: sessionConn, oldEncoder: oldEncoder,
                                          newEncoder: newEncoder, widthPx: w, heightPx: h)
                    }
                } catch {
                    self.queue.async {
                        guard self.connection === sessionConn else { return }
                        // Same outcome as before in-place resizing existed: the client
                        // reconnects and gets a session at the new size.
                        clog("STREAM: in-place resize failed (\(error)) — dropping the client so it reconnects")
                        self.teardownSession()
                    }
                }
            }
        }
    }

    private func finishResize(stream resizedStream: SCStream, sessionConn: NWConnection?, oldEncoder: VideoEncoder,
                              newEncoder: VideoEncoder, widthPx: Int, heightPx: Int) {
        guard connection === sessionConn, connection != nil, stream === resizedStream else {
            // A stale task from an older connection: leave `resizing` alone, it
            // belongs to whatever session is current (teardown resets it).
            newEncoder.invalidate()
            return
        }
        resizing = false
        attachFrameHandler(to: newEncoder)
        newEncoder.setBitrate(bitrate)
        // Frames the old encoder still has in flight are the wrong size for the
        // client's new decoder: drop them rather than send them after HELLO_ACK.
        oldEncoder.onEncodedFrame = nil
        encoder = newEncoder // its first frame is a keyframe, parameter sets included
        oldEncoder.invalidate()
        sessionWidthPx = widthPx
        sessionHeightPx = heightPx
        // The client rebuilds its decoder and canvas from a new HELLO_ACK.
        send(StreamMessage.helloAck(codec: newEncoder.codec, width: UInt32(widthPx), height: UInt32(heightPx),
                                    hardwareEncoder: newEncoder.isHardware))
        clog("STREAM: resized in place — \(newEncoder.codec) \(widthPx)x\(heightPx)")
        checkDisplaySize(retriesLeft: 0) // it may have moved again meanwhile
    }

    /// A session failed while starting. Tear down only if the connection that
    /// asked for it is still the current one — a newer client may have
    /// replaced it during the awaits, and its session must be left alone.
    private func failSession(_ sessionConn: NWConnection?) {
        queue.async { [self] in
            guard connection === sessionConn else { return }
            teardownSession()
        }
    }

    // MARK: - Cursor-follow auto-pan (on `queue`)

    /// Polls the global cursor position at 20 Hz and reports it normalized to
    /// this display's bounds — skipped when it hasn't moved (beyond a small
    /// epsilon) since the last send, so an idle mouse costs nothing. `CGEvent`
    /// location is in the same top-left-origin global point space as
    /// `CGDisplayBounds`, matching `InputInjector.map` exactly.
    private func startCursorReporting(displayID: CGDirectDisplayID) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50)) // 20 Hz
        timer.setEventHandler { [weak self] in
            guard let self, let global = CGEvent(source: nil)?.location else { return }
            let bounds = CGDisplayBounds(displayID)
            guard bounds.width > 0, bounds.height > 0 else { return }
            let norm = CGPoint(x: (global.x - bounds.origin.x) / bounds.width,
                               y: (global.y - bounds.origin.y) / bounds.height)
            if let last = self.lastSentCursor,
               abs(last.x - norm.x) < 0.001, abs(last.y - norm.y) < 0.001 { return }
            self.lastSentCursor = norm
            self.send(StreamMessage.cursorPos(x: Float32(norm.x), y: Float32(norm.y)))
        }
        timer.resume()
        cursorTimer = timer
    }

    // MARK: - Sending (on `queue`)

    private func sendFrame(keyframe: Bool, ptsMicros: UInt64, nalData: Data) {
        guard let conn = connection else { return }
        switch pacer.offer(keyframe: keyframe, now: CFAbsoluteTimeGetCurrent()) {
        case .stalled:
            clog("STREAM: nothing sent for \(Int(pacer.stallTimeout))s with \(pacer.inFlight) frames waiting — dropping the stalled connection")
            teardownSession()
            return
        case .drop(let requestKeyframe, let congested):
            // Network can't keep up: drop until a keyframe resyncs the decoder.
            if requestKeyframe { encoder?.requestKeyframe() }
            if congested { stepBitrateDown() }
            return
        case .send:
            break
        }
        maybeStepBitrateUp()
        send(StreamMessage.videoFrame(keyframe: keyframe, ptsMicros: ptsMicros, nalData: nalData)) { [weak self] in
            // A completion from a connection that has since been replaced
            // must not count against the new session.
            guard let self, self.connection === conn else { return }
            self.pacer.completed(now: CFAbsoluteTimeGetCurrent())
        }
    }

    // MARK: - Adaptive bitrate (on `queue`)

    /// Current encoder target, for the client's quality indicator.
    private func sendStreamStatus() {
        guard connection != nil else { return }
        send(StreamMessage.streamStatus(bitrateKbps: UInt16(min(bitrate / 1000, Int(UInt16.max)))))
    }

    private func stepBitrateDown() {
        let now = CFAbsoluteTimeGetCurrent()
        lastCongestionAt = now
        guard bitrate > VideoEncoder.minBitrate, now - lastStepAt >= 1 else { return }
        bitrate = max(bitrate / 2, VideoEncoder.minBitrate)
        lastStepAt = now
        encoder?.setBitrate(bitrate)
        sendStreamStatus()
        clog("STREAM: congestion (send queue full, dropping frames) — bitrate down to \(bitrate / 1_000_000) Mbps")
    }

    private func maybeStepBitrateUp() {
        guard bitrate < VideoEncoder.maxBitrate else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastCongestionAt >= 5, now - lastStepAt >= 5 else { return }
        bitrate = min(bitrate * 5 / 4, VideoEncoder.maxBitrate)
        lastStepAt = now
        encoder?.setBitrate(bitrate)
        sendStreamStatus()
        clog("STREAM: healthy for 5s — bitrate up to \(bitrate / 1_000_000) Mbps")
    }

    /// Sends one message to the client being served, through the gate, which
    /// encrypts it on a session that has a key. On `queue`.
    private func send(_ data: Data, completion: (() -> Void)? = nil) {
        guard let link = liveLink else { return }
        gate.send(data, to: link) { [weak self] error in
            self?.queue.async {
                completion?()
                // A late failure from a client that has since been replaced
                // must not end its successor's session.
                if error != nil, let self, self.liveLink === link { self.teardownSession() }
            }
        }
    }

    // MARK: - SCStreamOutput / SCStreamDelegate (on `videoQueue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            if sampleBuffer.isValid { audioEncoder?.encode(sampleBuffer) }
            return
        }
        guard type == .screen,
              sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                  as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let enc = encoder else { return }
        // During an in-place resize the capture can deliver frames of the new
        // size before the new encoder is attached (or the old size just after).
        // A mismatched buffer cannot be encoded; the next frame is right.
        guard CVPixelBufferGetWidth(pixelBuffer) == Int(enc.width),
              CVPixelBufferGetHeight(pixelBuffer) == Int(enc.height) else { return }
        enc.encode(pixelBuffer, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        clog("STREAM: capture stopped with error: \(error)")
        queue.async { self.teardownSession() }
    }
}

// MARK: - Fleet: one server per active display, following topology changes

/// Owns the per-display StreamServers for the `Clamshell stream` CLI and
/// rebuilds them when the display topology changes. That matters because the
/// client's HELLO can trigger a collapse (auto-sized virtual display, maybe
/// dual) *after* this process started — virtual display A must take over the
/// base port and B must get base+1 (where the iPad's external-screen client
/// connects), and the physical displays drop off the active list while
/// mirrored. Clients ride through the rebuild via their auto-reconnect.
/// Main-queue confined.
final class StreamFleet {
    /// Shared instance for access from CollapseCoordinator
    static var shared: StreamFleet?
    
    private let basePort: UInt16
    /// Set by the login-window agent before the first `rebuild`.
    var acceptsLoginCredentials = false
    /// The host's key, device list and approval setting, shared by every
    /// listener of this fleet.
    private let auth: HostAuth
    private var servers: [StreamServer] = []
    private var currentIDs: [CGDirectDisplayID] = []
    private var pendingRebuild: DispatchWorkItem?
    /// Whether the primary display's port is announced on the local network
    /// (PROTOCOL.md "Discovery"), and what does the announcing.
    private var announce: Bool
    private var advertiser: BonjourAdvertiser?

    /// Current screen-lock state, tracked from the `com.apple.screenIsLocked` /
    /// `...Unlocked` distributed notifications. Seeded from the login-session
    /// dictionary so a fleet started while already locked is correct. New
    /// servers inherit it on rebuild; live changes are pushed to every server.
    private var screenLocked = false
    private var lockObservers: [NSObjectProtocol] = []
    private var pendingLockSettle: DispatchWorkItem?

    /// Track virtual displays created by collapse operations to avoid tearing down active connections during collapse
    private var collapseCreatedDisplays: Set<CGDirectDisplayID> = []

    var isServing: Bool { !servers.isEmpty }

    /// Per-display connection snapshot for the Diagnostics view.
    var clientStatus: [(port: UInt16, primary: Bool, connected: Bool)] {
        servers.map { ($0.portNumber, $0.primary, $0.isClientConnected) }
    }

    /// Stored so it can be removed on stop() — the same function pointer must
    /// be passed to register and remove, and a live callback holding an
    /// unretained pointer to a deallocated fleet would dangle.
    private let reconfigCallback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
        guard let userInfo else { return }
        let fleet = Unmanaged<StreamFleet>.fromOpaque(userInfo).takeUnretainedValue()
        if flags.contains(.addFlag) || flags.contains(.removeFlag) {
            DispatchQueue.main.async { fleet.rebuildSoon() }
        } else if flags.contains(.setModeFlag) || flags.contains(.desktopShapeChangedFlag) {
            // Same displays, new size: the sessions resize themselves.
            DispatchQueue.main.async { fleet.displaySizeChanged() }
        }
    }
    private var callbackRegistered = false

    /// `reportLockState: false` keeps HOST_LOCK_STATE at "unlocked" for good —
    /// for the login-window agent, where the lock screen is what's being
    /// served and the client must not fall back to VNC.
    ///
    /// `announce` is off unless asked for: a test rig or the login-window
    /// agent should not put this Mac in the clients' list of nearby hosts.
    init(basePort: UInt16, reportLockState: Bool = true, auth: HostAuth = .shared, announce: Bool = false) {
        self.basePort = basePort
        self.auth = auth
        self.announce = announce
        CGDisplayRegisterReconfigurationCallback(reconfigCallback, Unmanaged.passUnretained(self).toOpaque())
        callbackRegistered = true
        guard reportLockState else { return }
        screenLocked = Self.currentlyLocked() // correct if started while already locked
        observeLockState()
    }

    /// Whether the login session's screen is locked right now. `nil` (key
    /// absent) means unlocked. Used to seed initial state and is the same signal
    /// the screenIsLocked/Unlocked notifications flip.
    private static func currentlyLocked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Int == 1
    }

    /// Observe the system lock/unlock distributed notifications (the same
    /// mechanism `screensharingd` and the login window use) and fan the state
    /// out to every server so connected clients get HOST_LOCK_STATE. Main-queue
    /// confined, matching the rest of this class.
    private func observeLockState() {
        let dnc = DistributedNotificationCenter.default()
        for (name, _) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            let obs = dnc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                // Debounce lock state changes to handle the transient unlock->lock flap during login-window -> user-session handoff
                // The ~600ms delay allows for the screensharingd handoff flap to settle before propagating the final state
                self.pendingLockSettle?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    // Read the authoritative current lock state rather than trusting the notification that triggered this
                    let settled = Self.currentlyLocked()
                    if settled != self.screenLocked {
                        self.screenLocked = settled
                        clog("STREAM: screen \(settled ? "LOCKED" : "UNLOCKED") — notifying \(self.servers.count) server(s)")
                        for s in self.servers { s.setLockState(settled) }
                    }
                }
                self.pendingLockSettle = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
            }
            lockObservers.append(obs)
        }
    }

    /// Stop every server and unregister the topology callback. Lets the
    /// menu-bar app toggle native streaming on and off in-process.
    func stop() {
        pendingRebuild?.cancel()
        pendingRebuild = nil
        for s in servers { s.stop() }
        servers = []
        currentIDs = []
        auth.directory.setDisplays([])
        updateAnnouncement()
        if callbackRegistered {
            CGDisplayRemoveReconfigurationCallback(reconfigCallback, Unmanaged.passUnretained(self).toOpaque())
            callbackRegistered = false
        }
        for obs in lockObservers { DistributedNotificationCenter.default().removeObserver(obs) }
        lockObservers = []
        // Cancel any pending lock settle work item to prevent dangling scheduled work
        pendingLockSettle?.cancel()
        pendingLockSettle = nil
        clog("STREAM: fleet stopped")
    }

    /// Disconnect every connected client without tearing down the listeners —
    /// forces stuck reconnect-looping clients to re-handshake cleanly.
    func disconnectAllClients() {
        for s in servers { s.disconnectClient() }
    }

    /// Active displays, main display first (index 0 = base port = the primary
    /// connection carrying audio/clipboard/display-info). Mirrored displays
    /// are excluded by CGGetActiveDisplayList, so while collapsed the list is
    /// just the virtual display(s).
    private static func activeIDs() -> [CGDirectDisplayID] {
        var list = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &list, &count)
        var ids = Array(list.prefix(Int(count)))
        if ids.isEmpty { ids = [CGMainDisplayID()] }
        if let mainIdx = ids.firstIndex(of: CGMainDisplayID()), mainIdx != 0 { ids.swapAt(0, mainIdx) }
        return ids
    }

    func rebuild() {
        let ids = Self.activeIDs()
        guard ids != currentIDs else { return }
        
        // Check if this is a reconfiguration that's part of an ongoing collapse operation.
        // If so, we should avoid tearing down active connections to prevent the loop.
        let isCollapseRebuild = !collapseCreatedDisplays.isEmpty && 
                               Set(ids).isSubset(of: collapseCreatedDisplays)
        
        // If this rebuild is due to a collapse and there are no other displays
        // (i.e., only virtual displays), we should not tear down existing connections
        if isCollapseRebuild {
            clog("STREAM: skipping rebuild for collapse-created displays")
            return
        }
        
        let group = DispatchGroup()
        for s in servers { group.enter(); s.stop { group.leave() } }
        servers = []
        currentIDs = ids
        // Wait for every old listener's port to actually release before
        // binding new ones on the same ports — see stop()'s doc comment.
        group.notify(queue: .main) { [self] in
            var served: [HostDirectory.Display] = []
            for (i, id) in ids.enumerated() {
                let port = basePort + UInt16(i)
                let server = StreamServer(displayID: id, port: port, isPrimary: i == 0,
                                          auth: auth, displayIndex: i)
                server.acceptsLoginCredentials = acceptsLoginCredentials
                do {
                    try server.start()
                    server.setLockState(screenLocked) // inherit current lock state
                    servers.append(server)
                    served.append(HostDirectory.Display(index: i, name: Self.displayName(i),
                                                        primary: i == 0, port: port))
                } catch {
                    clog("STREAM: failed to start server on port \(port): \(error)")
                }
            }
            // What HOST_INFO tells a client it can also connect to.
            auth.directory.setDisplays(served)
            updateAnnouncement()
            clog("STREAM: serving \(servers.count) display(s) on ports \(basePort)–\(basePort + UInt16(max(servers.count, 1) - 1))")
        }
    }

    /// The Streaming menu's switch.
    func setAnnounce(_ on: Bool) {
        announce = on
        updateAnnouncement()
    }

    /// How the announcement stands, for the menu.
    var announcement: BonjourAdvertiser.Outcome { advertiser?.outcome ?? .off }

    /// Announces the primary display's port while it is being served and the
    /// user wants it announced. The port stays the same across rebuilds, so
    /// the announcement is left alone while the listeners are replaced.
    private func updateAnnouncement() {
        guard announce, let primary = servers.first(where: { $0.primary }) else {
            advertiser?.stop()
            return
        }
        if advertiser == nil {
            advertiser = BonjourAdvertiser(hostId: auth.identity.id, name: auth.hostName)
        }
        advertiser?.start(port: primary.portNumber)
    }

    /// "Display A", "Display B", …: the names the clients already use.
    static func displayName(_ index: Int) -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return letters.indices.contains(index) ? "Display \(letters[index])" : "Display \(index + 1)"
    }

    /// A display kept its ID but changed pixel size. Each server compares its
    /// capture session to the display and resizes in place if they differ, so
    /// the connected client keeps streaming. Safe to call often.
    func displaySizeChanged() {
        for s in servers { s.displaySizeMayHaveChanged() }
    }

    /// Collapse/restore reconfigures displays several times over ~2s;
    /// debounce so we rebuild once, after the topology settles.
    private func rebuildSoon() {
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingRebuild = nil
            self?.rebuild()
        }
        pendingRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    /// Mark a display as created during collapse operation to prevent it from 
    /// triggering rebuilds that would tear down active connections.
    func markCollapseCreatedDisplay(_ displayID: CGDirectDisplayID) {
        collapseCreatedDisplays.insert(displayID)
    }
    
    /// Clear the set of collapse-created displays after a period, allowing
    /// normal rebuild behavior for external changes.
    func clearCollapseCreatedDisplays() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.collapseCreatedDisplays.removeAll()
        }
    }
}
