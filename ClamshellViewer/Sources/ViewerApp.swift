import SwiftUI
import AVFoundation
import CoreMedia

// ClamshellViewer — Phase 1 iPad client for the Clamshell stream protocol
// (see ../PROTOCOL.md). One full-screen view: connect to the Mac, receive
// framed HEVC/H.264 NAL units, hardware-decode + render them via
// AVSampleBufferDisplayLayer, and forward touches as mouse input.
// StreamProtocol.swift and FrameAssembler.swift are shared with the Mac host.

@main
struct ViewerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

// MARK: - Scene wiring for an external display
//
// SwiftUI's WindowGroup only ever fills the device's own screen. A physical
// external display (monitor over USB-C, or Phase 3 AR glasses — Viture/XREAL/
// Rokid, which enumerate as ordinary external UIScreens) arrives as a separate
// UIWindowScene with the external-display role. We keep the SwiftUI structure
// for the main screen and only hand-place the external one via a UISceneDelegate.
//
// Detection is entirely role/UIScreen-driven — there is NO device-model or
// resolution assumption anywhere. Whatever the OS reports as an external screen
// gets Display B, at whatever bounds/aspect it advertises, aspect-fit by the
// video layer. That is exactly why glasses with nonstandard resolutions work
// on this path unchanged.

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        // .windowExternalDisplayNonInteractive is the iOS 16+ replacement for the
        // deprecated .windowExternalDisplay; deployment target is iOS 17.
        if connectingSceneSession.role == .windowExternalDisplayNonInteractive {
            config.delegateClass = ExternalDisplaySceneDelegate.self
        }
        return config
    }
}

final class ExternalDisplaySceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene) // sized to the external screen's own bounds
        window.rootViewController = UIHostingController(
            rootView: ExternalDisplayView(client: Connection.shared.external))
        window.isHidden = false
        self.window = window
        Connection.shared.externalDisplayConnected()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        Connection.shared.externalDisplayDisconnected()
        window = nil
    }
}

// MARK: - Connection model (shared across the SwiftUI scene and external scene)

/// Owns both stream clients: `primary` (Display A, iPad screen, audio) and
/// `external` (Display B, external screen, muted). Display B only connects
/// while an external screen is actually attached.
final class Connection: ObservableObject {
    static let shared = Connection()

    let primary = StreamClient()
    let external = StreamClient()

    private var params: (host: String, accessId: String, accessSecret: String)?
    private var externalAttached = false

    init() { external.playsAudio = false }

    func connect(host: String, accessId: String, accessSecret: String) {
        params = (host, accessId, accessSecret)
        // A leading "A|B" carries an explicit Display B address; the primary
        // connects only to the A part.
        let primaryHost = host.contains("|") ? String(host.split(separator: "|", maxSplits: 1)[0]) : host
        primary.onClipboard = { text in UIPasteboard.general.string = text }
        primary.connect(host: primaryHost, accessId: accessId, accessSecret: accessSecret)
        connectExternalIfAttached()
    }

    func disconnect() {
        params = nil
        primary.disconnect()
        external.disconnect()
    }

    // Called when the external UIWindowScene connects/disconnects.
    func externalDisplayConnected() { externalAttached = true; connectExternalIfAttached() }
    func externalDisplayDisconnected() { externalAttached = false; external.disconnect() }

    /// Connect Display B only when a physical external screen is actually
    /// attached — otherwise we'd waste a whole encode+stream pipeline (or spin
    /// reconnecting to a port the Mac isn't serving).
    private func connectExternalIfAttached() {
        guard externalAttached,
              let (host, id, secret) = params,
              let bHost = Self.secondDisplayEndpoint(from: host) else { return }
        external.connect(host: bHost, accessId: id, accessSecret: secret)
    }

    /// Display B's endpoint. For a bare LAN host the Mac serves display index 1
    /// at streamDefaultPort+1; a full ws(s):// URL (tunnel) can't be derived, so
    /// the external screen stays dark unless the user gives an explicit B URL
    /// (a `|`-separated second address in the host field).
    static func secondDisplayEndpoint(from host: String) -> String? {
        if host.contains("|") { // "A|B" — explicit second address
            let parts = host.split(separator: "|", maxSplits: 1)
            return parts.count == 2 ? String(parts[1]) : nil
        }
        if host.contains("://") { return nil } // tunnel URL, can't derive port
        return "ws://\(host):\(streamDefaultPort + 1)"
    }
}

// MARK: - Network client

final class StreamClient: ObservableObject {
    enum Status: Equatable {
        case idle, connecting, streaming(String), failed(String)
    }

    @Published var status: Status = .idle
    @Published var videoSize: CGSize = .zero

    /// Whether audio plays through this client. Only the primary (iPad-screen)
    /// client plays audio; the external-display client stays muted.
    var playsAudio = true
    /// Called with received clipboard text (main thread).
    var onClipboard: ((String) -> Void)?

    /// Decoded-ready compressed samples for the display layer. Called on the
    /// network queue; AVSampleBufferDisplayLayer enqueue is thread-safe.
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var parser: StreamMessageParser?
    private var assembler: FrameAssembler?
    private let audio = AudioPlayer()

    // Retained connection parameters for automatic reconnection.
    private var connectParams: (host: String, accessId: String, accessSecret: String)?
    private var wantConnection = false
    private var reconnectAttempt = 0
    /// Last clipboard text seen in either direction — breaks the echo loop.
    private var lastClipboard: String?

    /// Accepts a bare host ("10.0.1.5" -> ws://10.0.1.5:5903) or a full
    /// ws:// / wss:// URL (Cloudflare Tunnel: wss://mac.example.com/stream).
    /// Cloudflare Access service-token headers are attached when provided.
    func connect(host: String, accessId: String = "", accessSecret: String = "") {
        wantConnection = true
        connectParams = (host, accessId, accessSecret)
        openSocket()
    }

    private func openSocket() {
        teardownSocket()
        guard let (host, accessId, accessSecret) = connectParams else { return }
        let urlString = host.contains("://") ? host : "ws://\(host):\(streamDefaultPort)"
        guard let url = URL(string: urlString) else {
            status = .failed("invalid address")
            return
        }
        status = .connecting

        let parser = StreamMessageParser()
        parser.onMessage = { [weak self] type, payload in self?.handle(type: type, payload: payload) }
        self.parser = parser

        var request = URLRequest(url: url)
        // Cloudflare Access service token — validated at Cloudflare's edge.
        if !accessId.isEmpty { request.setValue(accessId, forHTTPHeaderField: "CF-Access-Client-Id") }
        if !accessSecret.isEmpty { request.setValue(accessSecret, forHTTPHeaderField: "CF-Access-Client-Secret") }

        let task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 64 << 20 // keyframes at full display resolution
        self.task = task
        task.resume()
        // URLSession queues sends until the handshake completes.
        task.send(.data(StreamMessage.hello(requestedCodec: .hevc))) { _ in }
        receiveLoop(task)
    }

    /// User-initiated disconnect: stop reconnecting and tear down.
    func disconnect() {
        wantConnection = false
        connectParams = nil
        reconnectAttempt = 0
        teardownSocket()
        status = .idle
        videoSize = .zero
    }

    private func teardownSocket() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        parser = nil
        assembler = nil
        audio?.stop()
    }

    /// Drop detected: retry with capped exponential backoff unless the user
    /// asked to disconnect.
    private func scheduleReconnect() {
        guard wantConnection else { return }
        teardownSocket()
        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), 10) // 1,2,4,8,10,10…
        DispatchQueue.main.async { self.status = .connecting }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.wantConnection else { return }
            self.openSocket()
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self, self.task === task else { return }
            switch result {
            case .success(let message):
                self.reconnectAttempt = 0
                if case .data(let data) = message { self.parser?.feed(data) }
                self.receiveLoop(task)
            case .failure(let error):
                clogViewer("stream dropped: \(error.localizedDescription) — reconnecting")
                self.scheduleReconnect()
            }
        }
    }

    private func handle(type: StreamMessageType, payload: Data) {
        switch type {
        case .helloAck:
            guard payload.count >= 10,
                  let codec = StreamCodec(rawValue: payload[payload.startIndex + 1]) else { return }
            let width = payload.beUInt32(at: 2), height = payload.beUInt32(at: 6)
            assembler = FrameAssembler(codec: codec)
            DispatchQueue.main.async {
                self.videoSize = CGSize(width: Double(width), height: Double(height))
                self.status = .streaming("\(codec == .hevc ? "HEVC" : "H.264") \(width)x\(height)")
            }
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
        default:
            break // client never receives hello/keyframeRequest
        }
    }

    // MARK: Input (normalized 0..1 display coordinates)

    private func send(_ data: Data) {
        task?.send(.data(data)) { _ in }
    }

    func sendMouseMove(x: Float, y: Float) { send(StreamMessage.mouseMove(x: x, y: y)) }
    func sendMouseButton(button: UInt8, down: Bool, x: Float, y: Float) {
        send(StreamMessage.mouseButton(button: button, down: down, x: x, y: y))
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

func clogViewer(_ message: String) {
    #if DEBUG
    print("[ClamshellViewer] \(message)")
    #endif
}

// MARK: - Video view (render + touch capture)

final class VideoUIView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    weak var client: StreamClient?
    var videoSize: CGSize = .zero
    /// Display B on an external screen is output-only — no input capture.
    private let interactive: Bool

    init(frame: CGRect, interactive: Bool) {
        self.interactive = interactive
        super.init(frame: frame)
        displayLayer.videoGravity = .resizeAspect
        isMultipleTouchEnabled = false
        backgroundColor = .black
        guard interactive else { return }

        // Trackpad / mouse hover drives the pointer position without a button.
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(onHover))
        addGestureRecognizer(hover)
        // Trackpad two-finger / mouse-wheel scroll -> INPUT_SCROLL.
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(onScroll))
        scroll.allowedScrollTypesMask = .all
        scroll.maximumNumberOfTouches = 0 // indirect (trackpad/wheel) scroll only
        addGestureRecognizer(scroll)
    }
    required init?(coder: NSCoder) { fatalError() }

    // Physical keyboard: capture key presses while this view is first responder.
    override var canBecomeFirstResponder: Bool { interactive }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil && interactive { becomeFirstResponder() }
    }

    @objc private func onHover(_ g: UIHoverGestureRecognizer) {
        guard let (x, y) = normalized(g.location(in: self)) else { return }
        client?.sendMouseMove(x: x, y: y)
    }

    private var lastScroll: CGPoint = .zero
    @objc private func onScroll(_ g: UIPanGestureRecognizer) {
        if g.state == .began { lastScroll = .zero }
        let t = g.translation(in: self)
        let dx = Float(t.x - lastScroll.x)
        let dy = Float(t.y - lastScroll.y)
        lastScroll = t
        if dx != 0 || dy != 0 { client?.sendScroll(dx: dx, dy: dy) }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forwardKeys(presses, down: true) { super.pressesBegan(presses, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forwardKeys(presses, down: false) { super.pressesEnded(presses, with: event) }
    }

    /// Returns true if at least one press was a mappable hardware key we sent.
    private func forwardKeys(_ presses: Set<UIPress>, down: Bool) -> Bool {
        var handled = false
        for press in presses {
            guard let key = press.key,
                  let macVK = KeyMap.hidToMacVK[key.keyCode.rawValue] else { continue }
            client?.sendKey(macKeyCode: macVK, down: down, flags: KeyMap.cgFlags(from: key.modifierFlags))
            handled = true
        }
        return handled
    }

    func enqueue(_ sample: CMSampleBuffer) {
        if displayLayer.status == .failed {
            displayLayer.flush()
            client?.requestKeyframe()
        }
        displayLayer.enqueue(sample)
    }

    /// Maps a touch point into normalized video coordinates, accounting for
    /// aspect-fit letterboxing. Nil when outside the video rect.
    private func normalized(_ point: CGPoint) -> (Float, Float)? {
        guard videoSize != .zero, bounds.width > 0, bounds.height > 0 else { return nil }
        let rect = AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
        guard rect.width > 0, rect.height > 0 else { return nil }
        let x = Float((point.x - rect.minX) / rect.width)
        let y = Float((point.y - rect.minY) / rect.height)
        guard x >= 0, x <= 1, y >= 0, y <= 1 else { return nil }
        return (x, y)
    }

    // Single touch = left mouse: down on begin, drag on move, up on end.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, let (x, y) = normalized(t.location(in: self)) else { return }
        client?.sendMouseButton(button: 0, down: true, x: x, y: y)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, let (x, y) = normalized(t.location(in: self)) else { return }
        client?.sendMouseMove(x: x, y: y)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, let (x, y) = normalized(t.location(in: self)) else { return }
        client?.sendMouseButton(button: 0, down: false, x: x, y: y)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, let (x, y) = normalized(t.location(in: self)) else { return }
        client?.sendMouseButton(button: 0, down: false, x: x, y: y)
    }
}

struct VideoView: UIViewRepresentable {
    @ObservedObject var client: StreamClient
    var interactive = true

    func makeUIView(context: Context) -> VideoUIView {
        let view = VideoUIView(frame: .zero, interactive: interactive)
        view.client = client
        client.onSampleBuffer = { [weak view] sample in view?.enqueue(sample) }
        return view
    }

    func updateUIView(_ view: VideoUIView, context: Context) {
        view.videoSize = client.videoSize
    }
}

/// Root view hosted on the external UIWindowScene — Display B, output only.
struct ExternalDisplayView: View {
    @ObservedObject var client: StreamClient

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if case .streaming = client.status {
                VideoView(client: client, interactive: false).ignoresSafeArea()
            }
        }
    }
}

// MARK: - UI

struct ContentView: View {
    private let connection = Connection.shared
    @ObservedObject private var client = Connection.shared.primary
    @AppStorage("hostAddress") private var host = ""
    @AppStorage("cfAccessClientId") private var accessId = ""
    @AppStorage("cfAccessClientSecret") private var accessSecret = ""

    private func startConnection() {
        connection.connect(host: host.trimmingCharacters(in: .whitespaces),
                           accessId: accessId.trimmingCharacters(in: .whitespaces),
                           accessSecret: accessSecret.trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if case .streaming = client.status {
                VideoView(client: client)
                    .ignoresSafeArea()
                    .overlay(alignment: .topTrailing) {
                        Button {
                            connection.disconnect()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title)
                                .foregroundStyle(.white.opacity(0.35))
                        }
                        .padding()
                    }
            } else {
                connectForm
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            if let text = UIPasteboard.general.string { client.syncClipboard(text) }
        }
    }

    private var connectForm: some View {
        VStack(spacing: 16) {
            Text("Clamshell Viewer").font(.title2).foregroundStyle(.white)
            // A bare LAN host auto-derives Display B at port+1; for a tunnel URL
            // append "|wss://displayB..." to place a second screen externally.
            TextField("Mac address (10.0.1.5) or wss:// URL", text: $host)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .frame(maxWidth: 420)
            // Cloudflare Access service token (optional — leave blank on LAN).
            TextField("CF-Access-Client-Id (optional)", text: $accessId)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(maxWidth: 420)
            SecureField("CF-Access-Client-Secret (optional)", text: $accessSecret)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)
            Button("Connect") { startConnection() }
                .buttonStyle(.borderedProminent)
                .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
            switch client.status {
            case .connecting: ProgressView().tint(.white)
            case .failed(let reason): Text(reason).font(.footnote).foregroundStyle(.red)
            default: EmptyView()
            }
        }
        .padding()
    }
}
