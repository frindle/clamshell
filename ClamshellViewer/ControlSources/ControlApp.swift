import SwiftUI
import AVFoundation

// ClamshellControl — iPhone client for the Clamshell stream protocol.
// Unlike the iPad viewer, the iPhone shows NO video of its own: the external
// monitor plugged into the phone (USB-C monitor, or AR glasses — they enumerate
// as ordinary external UIScreens) is the only video output, showing whichever
// single Mac display the user picked. The phone's screen is a minimal control
// surface: a relative-movement trackpad, a software-keyboard toggle, and the
// connection status. Hardware keyboards/mice attached to the phone work like
// on the iPad (KeyMap press forwarding, hover, indirect scroll).
//
// StreamClient, VideoView/ExternalDisplayView, AudioPlayer, KeyMap and the
// protocol/assembler files are shared with the iPad target unchanged.

@main
struct ControlApp: App {
    @UIApplicationDelegateAdaptor(ControlAppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup { ControlContentView() }
    }
}

// MARK: - External display scene (same generic UIScreen-driven routing as iPad)

final class ControlAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        clogViewer("scene connecting with role \(connectingSceneSession.role.rawValue)")
        if connectingSceneSession.role == .windowExternalDisplayNonInteractive {
            config.delegateClass = ControlExternalSceneDelegate.self
        }
        return config
    }
}

final class ControlExternalSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else {
            clogViewer("external scene connected but is not a UIWindowScene — ignoring")
            return
        }
        clogViewer("external display scene CONNECTED: \(describeScreen(windowScene.screen))")
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(
            rootView: ExternalDisplayView(client: ControlSession.shared.client))
        window.isHidden = false
        self.window = window
        ControlSession.shared.externalScreenChanged(windowScene.screen)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        clogViewer("external display scene DISCONNECTED")
        ControlSession.shared.externalScreenChanged(nil)
        window = nil
    }
}

// MARK: - Session (one client: the picked Mac display)

/// One StreamClient for the single Mac display being mirrored to the external
/// monitor. The connection stays up even without a monitor attached — the same
/// socket carries the trackpad/keyboard input, so it can't be gated on the
/// external scene the way the iPad's Display B is.
final class ControlSession: ObservableObject {
    static let shared = ControlSession()

    let client = StreamClient()
    @Published var externalAttached = false

    /// displayIndex is 0-based; a bare host connects to streamDefaultPort+index.
    /// A full ws(s):// URL (tunnel) is used as-is — the tunnel hostname already
    /// pins a specific display's endpoint, so the index is ignored.
    func connect(host: String, displayIndex: Int, accessId: String, accessSecret: String) {
        let endpoint = host.contains("://")
            ? host
            : "ws://\(host):\(Int(streamDefaultPort) + displayIndex)"
        client.onClipboard = { text in UIPasteboard.general.string = text }
        client.connect(host: endpoint, accessId: accessId, accessSecret: accessSecret)
    }

    func disconnect() { client.disconnect() }

    /// The external monitor is this client's ONLY video surface, so its size
    /// (never the phone's) is what the Mac should shape the virtual display
    /// to — and there is never a *second* surface, so dual mode is never
    /// requested from the phone. No size report until a monitor exists.
    func externalScreenChanged(_ screen: UIScreen?) {
        externalAttached = screen != nil
        if let screen {
            client.updateReportedDisplay(pixelSize: screen.nativeBounds.size, secondDisplay: false)
        }
    }
}

// MARK: - Trackpad surface (relative pointer, like a laptop trackpad)

/// Relative-movement trackpad: the client keeps a virtual cursor in normalized
/// 0..1 display coordinates and nudges it by touch deltas, since the protocol's
/// INPUT_MOUSE_MOVE is absolute. One-finger pan moves, tap clicks, two-finger
/// tap right-clicks, two-finger pan scrolls. Hardware mice/trackpads (hover +
/// indirect scroll) and hardware keyboards (press forwarding) also land here.
final class TrackpadUIView: UIView {
    weak var client: StreamClient?

    /// Virtual cursor, normalized 0..1 in the Mac display's space.
    private var cursor = CGPoint(x: 0.5, y: 0.5)
    // ponytail: fixed gain (full phone-width swipe ≈ 80% of the Mac display),
    // no acceleration curve — add a sensitivity setting if it feels wrong.
    private let gain: CGFloat = 1.0 / 500.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isMultipleTouchEnabled = true

        let move = UIPanGestureRecognizer(target: self, action: #selector(onMove))
        move.minimumNumberOfTouches = 1
        move.maximumNumberOfTouches = 1
        addGestureRecognizer(move)

        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap))
        addGestureRecognizer(tap)

        let rightTap = UITapGestureRecognizer(target: self, action: #selector(onRightTap))
        rightTap.numberOfTouchesRequired = 2
        addGestureRecognizer(rightTap)

        let twoFingerScroll = UIPanGestureRecognizer(target: self, action: #selector(onScroll))
        twoFingerScroll.minimumNumberOfTouches = 2
        twoFingerScroll.maximumNumberOfTouches = 2
        addGestureRecognizer(twoFingerScroll)

        // Bluetooth mouse wheel / trackpad two-finger scroll (indirect).
        let indirectScroll = UIPanGestureRecognizer(target: self, action: #selector(onScroll))
        indirectScroll.allowedScrollTypesMask = .all
        indirectScroll.maximumNumberOfTouches = 0
        addGestureRecognizer(indirectScroll)

        // Bluetooth mouse / trackpad movement: hover position deltas drive the
        // same virtual cursor (relative, not absolute — the phone screen is
        // tiny and the Mac display isn't).
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(onHover))
        addGestureRecognizer(hover)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func moveCursor(byPointDelta d: CGPoint) {
        cursor.x = min(max(cursor.x + d.x * gain, 0), 1)
        cursor.y = min(max(cursor.y + d.y * gain, 0), 1)
        client?.sendMouseMove(x: Float(cursor.x), y: Float(cursor.y))
    }

    private var lastPan: CGPoint = .zero
    @objc private func onMove(_ g: UIPanGestureRecognizer) {
        if g.state == .began { lastPan = .zero }
        let t = g.translation(in: self)
        moveCursor(byPointDelta: CGPoint(x: t.x - lastPan.x, y: t.y - lastPan.y))
        lastPan = t
    }

    private var lastHover: CGPoint?
    @objc private func onHover(_ g: UIHoverGestureRecognizer) {
        let p = g.location(in: self)
        defer { lastHover = g.state == .ended ? nil : p }
        guard g.state == .changed, let last = lastHover else { return }
        moveCursor(byPointDelta: CGPoint(x: p.x - last.x, y: p.y - last.y))
    }

    private func click(button: UInt8) {
        let (x, y) = (Float(cursor.x), Float(cursor.y))
        client?.sendMouseButton(button: button, down: true, x: x, y: y)
        client?.sendMouseButton(button: button, down: false, x: x, y: y)
    }
    @objc private func onTap() { click(button: 0) }
    @objc private func onRightTap() { click(button: 1) }

    private var lastScroll: CGPoint = .zero
    @objc private func onScroll(_ g: UIPanGestureRecognizer) {
        if g.state == .began { lastScroll = .zero }
        let t = g.translation(in: self)
        let dx = Float(t.x - lastScroll.x)
        let dy = Float(t.y - lastScroll.y)
        lastScroll = t
        if dx != 0 || dy != 0 { client?.sendScroll(dx: dx, dy: dy) }
    }

    // Hardware keyboard passthrough while the trackpad is first responder.
    override var canBecomeFirstResponder: Bool { true }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { becomeFirstResponder() }
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !KeyMap.forward(presses, down: true, to: client) { super.pressesBegan(presses, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !KeyMap.forward(presses, down: false, to: client) { super.pressesEnded(presses, with: event) }
    }
}

// MARK: - Software keyboard input

/// Invisible first-responder that summons the software keyboard and turns its
/// characters into INPUT_KEY down/up pairs via KeyMap. Becoming first responder
/// shows the keyboard; resigning hides it (responder then returns to the
/// trackpad for hardware keys).
final class KeyInputUIView: UIView, UIKeyInput {
    weak var client: StreamClient?

    var hasText: Bool { true } // keeps the delete key always active

    func insertText(_ text: String) {
        for char in text {
            guard let (vk, shift) = KeyMap.macVK(for: char) else { continue }
            let flags: UInt64 = shift ? 0x2_0000 : 0
            client?.sendKey(macKeyCode: vk, down: true, flags: flags)
            client?.sendKey(macKeyCode: vk, down: false, flags: flags)
        }
    }

    func deleteBackward() {
        client?.sendKey(macKeyCode: 51, down: true, flags: 0)  // kVK_Delete
        client?.sendKey(macKeyCode: 51, down: false, flags: 0)
    }

    override var canBecomeFirstResponder: Bool { true }

    // Raw passthrough: no local text processing of any kind.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no

    // Hardware keys still forward while the software keyboard is up.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !KeyMap.forward(presses, down: true, to: client) { super.pressesBegan(presses, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !KeyMap.forward(presses, down: false, to: client) { super.pressesEnded(presses, with: event) }
    }
}

/// Trackpad + hidden key-input view; `keyboardVisible` toggles the software
/// keyboard by moving first-responder status between the two.
struct ControlSurface: UIViewRepresentable {
    let client: StreamClient
    @Binding var keyboardVisible: Bool

    final class Container: UIView {
        let trackpad = TrackpadUIView(frame: .zero)
        let keyInput = KeyInputUIView(frame: .zero)

        override init(frame: CGRect) {
            super.init(frame: frame)
            trackpad.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            trackpad.frame = bounds
            addSubview(trackpad)
            keyInput.isHidden = true
            addSubview(keyInput)
        }
        required init?(coder: NSCoder) { fatalError() }
    }

    func makeUIView(context: Context) -> Container {
        let v = Container(frame: .zero)
        v.trackpad.client = client
        v.keyInput.client = client
        return v
    }

    func updateUIView(_ v: Container, context: Context) {
        if keyboardVisible {
            if !v.keyInput.isFirstResponder { v.keyInput.becomeFirstResponder() }
        } else {
            if v.keyInput.isFirstResponder {
                v.keyInput.resignFirstResponder()
                v.trackpad.becomeFirstResponder()
            }
        }
    }
}

// MARK: - UI

struct ControlContentView: View {
    private let session = ControlSession.shared
    @ObservedObject private var sessionState = ControlSession.shared
    @ObservedObject private var client = ControlSession.shared.client
    @StateObject private var store = MachineStore()
    @AppStorage("hostAddress") private var host = ""
    @AppStorage("displayIndex") private var displayIndex = 0
    @AppStorage("cfAccessClientId") private var accessId = ""
    @AppStorage("cfAccessClientSecret") private var accessSecret = ""
    @AppStorage("nerdMode") private var nerdMode = false
    @State private var keyboardVisible = false
    @State private var showScanner = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch client.status {
            case .idle, .failed: connectForm
            case .connecting, .streaming: controlSurface
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .fullScreenCover(isPresented: $showScanner) {
            QRScannerView(onScan: applyScan, onCancel: { showScanner = false })
                .ignoresSafeArea()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            if let text = UIPasteboard.general.string { client.syncClipboard(text) }
        }
    }

    private func connectNow(host h: String, displayIndex idx: Int, accessId id: String, accessSecret secret: String) {
        guard !h.isEmpty else { return }
        store.upsert(MachineProfile(name: ContentViewNaming.deriveName(h), host: h,
                                    accessId: id, accessSecret: secret, displayIndex: idx))
        session.connect(host: h, displayIndex: idx, accessId: id, accessSecret: secret)
    }

    private func select(_ m: MachineProfile) {
        host = m.host; accessId = m.accessId; accessSecret = m.accessSecret; displayIndex = m.displayIndex
        session.connect(host: m.host, displayIndex: m.displayIndex, accessId: m.accessId, accessSecret: m.accessSecret)
    }

    private func applyScan(_ code: String) {
        showScanner = false
        guard let pairing = ClamshellPairing(url: code) else {
            clogViewer("QR scan ignored: not a clamshell pairing code"); return
        }
        host = pairing.host; accessId = pairing.accessId; accessSecret = pairing.accessSecret
        store.upsert(MachineProfile(name: ContentViewNaming.deriveName(pairing.host), host: pairing.host,
                                    accessId: pairing.accessId, accessSecret: pairing.accessSecret, displayIndex: displayIndex))
        clogViewer("QR scan filled connection for \(pairing.host)")
    }

    private var controlSurface: some View {
        ControlSurface(client: client, keyboardVisible: $keyboardVisible)
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    topBar
                    if client.softwareEncoding { SoftwareEncodingBanner() }
                    QualityIndicator(client: client)
                }
                .padding()
            }
    }

    private var topBar: some View {
        HStack {
            Button {
                keyboardVisible = false
                session.disconnect()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            Spacer()
            Text(statusLine)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.35))
            Spacer()
            Button {
                keyboardVisible.toggle()
            } label: {
                Image(systemName: keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard")
            }
        }
        .font(.title2)
        .foregroundStyle(.white.opacity(0.35))
    }

    private var statusLine: String {
        switch client.status {
        case .streaming(let desc):
            return sessionState.externalAttached ? desc : "\(desc) — no external display"
        case .connecting: return client.lastError ?? "connecting…"
        case .failed(let reason): return reason
        case .idle: return ""
        }
    }

    private var connectForm: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("Clamshell Control").font(.title2).foregroundStyle(.white)
                Text("Video goes to the external monitor; this screen is the trackpad.")
                    .font(.footnote).foregroundStyle(.gray)

                SavedMachinesView(store: store, onSelect: select)

                Button { showScanner = true } label: {
                    Label("Scan QR to Pair", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(.bordered)

                TextField("Mac address (192.168.1.5) or wss:// URL", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .frame(maxWidth: 420)
                // Which Mac display to mirror (bare host only; a wss:// tunnel URL
                // already addresses one display's endpoint).
                if !host.contains("://") {
                    Picker("Display", selection: $displayIndex) {
                        ForEach(0..<4, id: \.self) { Text("Display \($0 + 1)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 420)
                }
                TextField("CF-Access-Client-Id (optional)", text: $accessId)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(maxWidth: 420)
                SecureField("CF-Access-Client-Secret (optional)", text: $accessSecret)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 420)
                Button("Connect") {
                    connectNow(host: host.trimmingCharacters(in: .whitespaces),
                               displayIndex: displayIndex,
                               accessId: accessId.trimmingCharacters(in: .whitespaces),
                               accessSecret: accessSecret.trimmingCharacters(in: .whitespaces))
                }
                .buttonStyle(.borderedProminent)
                .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                Toggle("Nerd Mode (show stream stats)", isOn: $nerdMode)
                    .frame(maxWidth: 420)
                    .foregroundStyle(.gray)
                if case .failed(let reason) = client.status {
                    Text(reason).font(.footnote).foregroundStyle(.red)
                } else if let e = client.lastError {
                    Text(e).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
            }
            .padding()
        }
    }
}
