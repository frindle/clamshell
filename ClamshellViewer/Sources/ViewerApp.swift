import SwiftUI

// ClamshellViewer — iPad client for the Clamshell stream protocol
// (see ../PROTOCOL.md). Displays Display A full-screen on the iPad and, when a
// physical external screen is attached, Display B on that screen. StreamClient
// (network), VideoView (render/input), StreamProtocol and FrameAssembler are
// shared with the iPhone ClamshellControl target and/or the Mac host.
//
// Stage-Manager-capable iPads (confirmed on a real M4 iPad Air, 2026-07-31):
// dragging the app's single window onto an external display already works
// with zero app code — SwiftUI renders wherever the window's UIWindowScene
// physically sits, no scene-role detection needed. `ExternalDisplaySceneDelegate`
// below (and genuine Display B) only matters for iPads without Stage Manager,
// where dragging isn't possible and the external screen can only be claimed
// via the legacy external-display scene role.

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
// external display (monitor over USB-C, or AR glasses — Viture/XREAL/
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
        // Real hardware test 2026-07-31: a wired external display connected
        // via USB-C only ever showed the OS's own default mirroring (dock +
        // wallpaper), never ExternalDisplaySceneDelegate — meaning this
        // check's role never matched. Both .windowExternalDisplay and
        // .windowExternalDisplayNonInteractive are real, distinct roles;
        // which one iOS actually hands a given external display depends on
        // context/OS version, not a strict "one replaced the other"
        // relationship the previous comment here assumed. Check both rather
        // than bet on a single role.
        clogViewer("scene connecting with role \(connectingSceneSession.role.rawValue)")
        if connectingSceneSession.role == .windowExternalDisplayNonInteractive
            || connectingSceneSession.role == .windowExternalDisplay {
            config.delegateClass = ExternalDisplaySceneDelegate.self
        }
        return config
    }
}

final class ExternalDisplaySceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else {
            clogViewer("external scene connected but is not a UIWindowScene — ignoring")
            return
        }
        clogViewer("external display scene CONNECTED: \(describeScreen(windowScene.screen))")
        let window = UIWindow(windowScene: windowScene) // sized to the external screen's own bounds
        window.rootViewController = UIHostingController(
            rootView: ExternalDisplayView(client: Connection.shared.external))
        window.isHidden = false
        self.window = window
        Connection.shared.externalDisplayConnected(size: windowScene.screen.nativeBounds.size)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        clogViewer("external display scene DISCONNECTED")
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

    private var connectedHost: String?
    /// True whenever a physical external screen is currently attached —
    /// drives dual-display negotiation with the Mac.
    @Published var externalAttached = false

    init() {
        external.playsAudio = false
        // Report the iPad's real screen size in HELLO so the Mac auto-sizes
        // its virtual display to this device (no manual preset needed).
        primary.reportedPixelSize = UIScreen.main.nativeBounds.size
    }

    func connect(host: String) {
        connectedHost = host
        // A leading "A|B" carries an explicit Display B address; the primary
        // connects only to the A part.
        let primaryHost = host.contains("|") ? String(host.split(separator: "|", maxSplits: 1)[0]) : host
        primary.onClipboard = { text in UIPasteboard.general.string = text }
        primary.connect(host: primaryHost)
        connectExternalIfAttached()
    }

    func disconnect() {
        connectedHost = nil
        primary.disconnect()
        external.disconnect()
    }

    // Called when the external UIWindowScene connects/disconnects. The
    // primary connection tells the Mac about the second surface so it can
    // auto-enter/leave dual display mode (Auto-Detect Dual Display).
    func externalDisplayConnected(size: CGSize) {
        externalAttached = true
        // The primary connection carries Display B's size too (only the
        // primary's report is honored host-side), so the Mac sizes Display B
        // to the real external monitor instead of the fixed presetB.
        primary.updateReportedDisplay(secondDisplay: true, secondPixelSize: size)
        connectExternalIfAttached()
    }
    func externalDisplayDisconnected() {
        externalAttached = false
        primary.updateReportedDisplay(secondDisplay: false)
        external.disconnect()
    }

    /// Connect Display B only when a physical external screen is actually
    /// attached — otherwise we'd waste a whole encode+stream pipeline (or
    /// spin reconnecting to a port the Mac isn't serving).
    private func connectExternalIfAttached() {
        guard externalAttached,
              let host = connectedHost,
              let bHost = Self.secondDisplayEndpoint(from: host) else { return }
        external.connect(host: bHost)
    }

    /// Manual Display B request for Stage Manager iPads: real hardware testing
    /// 2026-07-31 found the OS never signals this app when a window lands on
    /// an external display (no scene role change, no notification — dragging
    /// just opens an ordinary second window), so `externalAttached` never
    /// flips on its own. This is the same effect as `externalDisplayConnected`,
    /// triggered by an explicit user choice (the mirror/extend toggle) instead
    /// of a scene notification that doesn't fire. `size`, when known, is the
    /// Display-B window's own frame in pixels — same-session testing found
    /// this is exactly the real external monitor's resolution once that
    /// window goes fullscreen there (see `WindowSizeReader`), so the Mac can
    /// still auto-size Display B correctly despite having no external
    /// UIWindowScene to read bounds from directly.
    func requestDisplayB(size: CGSize? = nil) {
        externalAttached = true
        primary.updateReportedDisplay(secondDisplay: true, secondPixelSize: size)
        connectExternalIfAttached()
    }

    /// Re-report Display B's size after it's already connected — e.g. the
    /// window goes fullscreen (or un-fullscreens) after the initial toggle.
    func updateDisplayBSize(_ size: CGSize) {
        guard externalAttached else { return }
        primary.updateReportedDisplay(secondDisplay: true, secondPixelSize: size)
    }

    /// Re-report the iPad's own window size, live — Display A's size was
    /// previously only read once at launch (`UIScreen.main.nativeBounds` in
    /// `init()`), which doesn't reflect Stage Manager resizing that window
    /// after connect (e.g. going fullscreen after HELLO already sent a
    /// smaller tile size) — the same real-hardware black-bars bug Display B
    /// had, just on the primary side. Preserves the existing dual-mode flag.
    func updatePrimarySize(_ size: CGSize) {
        primary.updateReportedDisplay(pixelSize: size, secondDisplay: externalAttached)
    }

    func releaseDisplayB() {
        externalAttached = false
        primary.updateReportedDisplay(secondDisplay: false)
        external.disconnect()
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

/// Reports this window's own real pixel size, live, via
/// `view.window?.screen.nativeBounds` — used for both the Display A and
/// Display B windows so each reports whatever physical screen IT is
/// actually showing on right now, rather than a size read once at connect
/// time (real-hardware testing 2026-07-31 found the latter causes
/// letterboxing/black bars whenever Stage Manager resizes the window, e.g.
/// going fullscreen, after the size was already reported).
struct WindowSizeReader: UIViewRepresentable {
    /// (size, isDeviceScreen) — isDeviceScreen distinguishes the iPad's own
    /// built-in screen from any external monitor. Real bug hit 2026-07-31:
    /// with two windows both mirroring Display A (neither toggled to
    /// Extend), each reported its OWN real screen size for Display A — the
    /// iPad's and the external monitor's, whichever different sizes — and
    /// they fought over it, each report triggering a re-collapse that
    /// triggered another layout pass that reported again. Only the device's
    /// own screen should ever drive Display A's size; a window mirroring A
    /// on any other screen just aspect-fits locally.
    var onChange: (CGSize, Bool) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = SizeReaderView()
        view.onChange = onChange
        return view
    }
    // Without this, the closure captured in makeUIView (and everything it
    // closes over — critically, `showingDisplayB` at that moment) would
    // freeze at the window's first layout pass, before the user ever taps
    // the toggle — misrouting size reports permanently.
    func updateUIView(_ uiView: UIView, context: Context) {
        (uiView as? SizeReaderView)?.onChange = onChange
    }

    private final class SizeReaderView: UIView {
        var onChange: ((CGSize, Bool) -> Void)?
        private var lastSize: CGSize?
        override func didMoveToWindow() { super.didMoveToWindow(); report() }
        override func layoutSubviews() { super.layoutSubviews(); report() }
        // Measures THIS VIEW's own rendered area, not the screen's full
        // nativeBounds — real bug hit 2026-07-31: the video only fills the
        // window's own bounds, but iPadOS reserves some space on an external
        // display that the window doesn't actually cover even fullscreen, so
        // reporting the raw screen size made the Mac size Display B larger
        // than what the video actually renders into, causing black bars.
        private func report() {
            guard let screen = window?.screen, bounds.width > 0, bounds.height > 0 else { return }
            let scale = screen.scale
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            guard size != lastSize else { return }
            lastSize = size
            onChange?(size, screen == UIScreen.main)
        }
    }
}

/// Number of this app's own windows currently open — drives whether the
/// mirror/extend toggle appears (only meaningful with a second window to put
/// Display B in). No dedicated "scene did connect" notification exists, so
/// this refreshes from `UIApplication.connectedScenes` on the two events that
/// actually change it: a window's own ContentView appearing, and any scene
/// disconnecting.
final class WindowCount: ObservableObject {
    static let shared = WindowCount()
    @Published private(set) var count = 1
    private init() {
        NotificationCenter.default.addObserver(
            forName: UIScene.didDisconnectNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }
    func refresh() {
        count = UIApplication.shared.connectedScenes.filter { $0 is UIWindowScene }.count
    }
}

// MARK: - UI

struct ContentView: View {
    @ObservedObject private var connection = Connection.shared
    @ObservedObject private var windowCount = WindowCount.shared
    // Both permanently observed — SwiftUI can't reassign which object an
    // @ObservedObject points to from a struct View's non-mutating context.
    // `client` below just picks which one THIS window renders.
    @ObservedObject private var primaryClient = Connection.shared.primary
    @ObservedObject private var externalClient = Connection.shared.external
    @State private var showingDisplayB = false
    // This window's own real pixel size — see WindowSizeReader. Only
    // meaningful/read while showingDisplayB, but kept updated regardless
    // so the first report on toggle isn't stale.
    @State private var windowPixelSize: CGSize?
    private var client: StreamClient { showingDisplayB ? externalClient : primaryClient }
    @StateObject private var store = MachineStore()
    @AppStorage("hostAddress") private var host = ""
    @State private var machineName = ""
    @AppStorage("nerdMode") private var nerdMode = false
    @State private var showScanner = false
    @State private var showSettings = false
    // Icon toolbar (top-right) stays hidden until the pointer hovers that
    // corner, or a touch taps the invisible catcher there — otherwise the
    // icons permanently cover the spot Stage Manager/the Dock reveal from.
    @State private var toolbarVisible = false
    // Grace period before hiding again after the pointer leaves — without
    // this, a slight overshoot while moving toward a button hides it again
    // before the tap lands.
    @State private var hideToolbarTask: DispatchWorkItem?

    // RDP connection mode — a second target type alongside the native
    // Clamshell protocol (see RDPSession.swift / RDPConnectView.swift).
    // Kept as separate state/views rather than woven into StreamClient so
    // the existing Clamshell path is untouched.
    enum TargetType: String, CaseIterable { case clamshell = "Clamshell", rdp = "RDP" }
    @State private var targetType: TargetType = .clamshell
    @StateObject private var rdpSession = RDPSession()
    @StateObject private var rdpStore = RDPProfileStore()
    @State private var pendingCertificate: (subject: String, issuer: String, fingerprint: String, completion: (Bool) -> Void)?

    private func startConnection() {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return }
        let n = machineName.trimmingCharacters(in: .whitespaces)
        // A blank name field must NOT clobber an already-saved custom name
        // on a later reconnect to the same host (upsert always overwrites
        // the whole profile) — fall back to the existing name first, then
        // the auto-derived one only for a genuinely new host.
        let name = !n.isEmpty ? n
            : (store.machines.first(where: { $0.host == h })?.name ?? ContentViewNaming.deriveName(h))
        store.upsert(MachineProfile(name: name, host: h))
        store.markUsed(h)
        machineName = ""
        connection.connect(host: h)
    }

    private func select(_ m: MachineProfile) {
        host = m.host
        store.markUsed(m.host)
        connection.connect(host: m.host)
    }

    /// Switch to another saved machine mid-session: drop the current stream and
    /// reconnect to the chosen one.
    private func switchTo(_ m: MachineProfile) {
        showSettings = false
        connection.disconnect()
        select(m)
    }

    /// Pre-fill the connect form from the last-used saved machine so a single
    /// Connect press reuses it (does NOT auto-connect).
    private func preselectLastUsed() {
        guard host.trimmingCharacters(in: .whitespaces).isEmpty, let m = store.lastUsed else { return }
        host = m.host
    }

    private func applyScan(_ code: String) {
        showScanner = false
        guard let pairing = ClamshellPairing(url: code) else {
            clogViewer("QR scan ignored: not a clamshell pairing code")
            return
        }
        host = pairing.host
        store.upsert(MachineProfile(name: ContentViewNaming.deriveName(pairing.host), host: pairing.host))
        clogViewer("QR scan filled connection for \(pairing.host)")
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if targetType == .rdp, rdpSession.status != .idle {
                RDPStreamView(session: rdpSession, onClose: { rdpSession.disconnect() })
            } else if case .streaming = client.status {
                VideoView(client: client)
                    .ignoresSafeArea()
                    .background(
                        WindowSizeReader { size, isDeviceScreen in
                            windowPixelSize = size
                            if showingDisplayB {
                                connection.updateDisplayBSize(size)
                            } else if isDeviceScreen {
                                connection.updatePrimarySize(size)
                            }
                            // else: mirroring Display A on a non-device
                            // screen (Extend not toggled here) — let it
                            // aspect-fit locally, don't fight over A's size.
                        }
                    )
                    .overlay(alignment: .top) {
                        VStack(spacing: 6) {
                            if client.hostLocked { LockScreenBanner(fallbackURL: client.browserFallbackURL) }
                            if client.softwareEncoding { SoftwareEncodingBanner() }
                            QualityIndicator(client: client)
                        }
                        .padding(.top, 8)
                    }
                    .overlay(alignment: .topTrailing) {
                        ZStack(alignment: .topTrailing) {
                            // Always-present, invisible hover/tap catcher —
                            // hover reveals for pointer users, tap toggles
                            // for touch-only, so the corner stays free the
                            // rest of the time for Stage Manager/Dock reveal.
                            Color.clear
                                .frame(width: 220, height: 90)
                                .contentShape(Rectangle())
                                .onHover { hovering in
                                    hideToolbarTask?.cancel()
                                    if hovering {
                                        withAnimation(.easeInOut(duration: 0.15)) { toolbarVisible = true }
                                    } else {
                                        let task = DispatchWorkItem {
                                            withAnimation(.easeInOut(duration: 0.15)) { toolbarVisible = false }
                                        }
                                        hideToolbarTask = task
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: task)
                                    }
                                }
                                .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { toolbarVisible.toggle() } }
                            HStack(spacing: 16) {
                                // Only meaningful with a second window to put
                                // Display B in (see WindowCount's doc comment).
                                if windowCount.count >= 2 {
                                    Button {
                                        showingDisplayB.toggle()
                                    } label: {
                                        Label(showingDisplayB ? "Extend" : "Mirror",
                                              systemImage: showingDisplayB ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle")
                                            .font(.subheadline)
                                            .foregroundStyle(.white.opacity(0.7))
                                    }
                                }
                                Button { showSettings = true } label: {
                                    Image(systemName: "gearshape.fill")
                                        .font(.title)
                                        .foregroundStyle(.white.opacity(0.35))
                                }
                                Button {
                                    connection.disconnect()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.title)
                                        .foregroundStyle(.white.opacity(0.35))
                                }
                            }
                            .padding()
                            .opacity(toolbarVisible ? 1 : 0)
                            .allowsHitTesting(toolbarVisible)
                        }
                    }
            } else if showingDisplayB {
                // Toggled to Display B but `external` hasn't reached
                // .streaming yet (Mac still spinning up the second virtual
                // display) — a dedicated wait state instead of falling to
                // connectForm, which would wrongly suggest re-entering a host.
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("Connecting to Display B…").foregroundStyle(.white)
                    if let e = externalClient.lastError {
                        Text(e).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                    }
                    Button("Back to Display A") { showingDisplayB = false }
                        .buttonStyle(.bordered).tint(.white)
                }
            } else {
                connectForm
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            preselectLastUsed()
            windowCount.refresh()
        }
        .onChange(of: showingDisplayB) { isB in
            if isB {
                connection.requestDisplayB(size: windowPixelSize)
            } else {
                connection.releaseDisplayB()
            }
        }
        .sheet(isPresented: $showSettings) {
            InSessionSettingsView(store: store, currentHost: host,
                                  onSwitch: switchTo, onClose: { showSettings = false })
        }
        .fullScreenCover(isPresented: $showScanner) {
            QRScannerView(onScan: applyScan, onCancel: { showScanner = false })
                .ignoresSafeArea()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            if let text = UIPasteboard.general.string { client.syncClipboard(text) }
        }
        .modifier(RDPCertificatePrompt(pending: $pendingCertificate))
        .onAppear {
            rdpSession.onCertificatePrompt = { subject, issuer, fingerprint, completion in
                DispatchQueue.main.async {
                    pendingCertificate = (subject, issuer, fingerprint, completion)
                }
            }
        }
    }

    private var connectForm: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("Clamshell Viewer").font(.title2).foregroundStyle(.white)

                Picker("Target", selection: $targetType) {
                    ForEach(ContentView.TargetType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)

                if targetType == .rdp {
                    RDPConnectForm(store: rdpStore) { rdpHost, port, username, password, domain in
                        let size = UIScreen.main.nativeBounds.size
                        rdpSession.connect(host: rdpHost, port: port, username: username, password: password,
                                          domain: domain, width: Int(max(size.width, size.height)),
                                          height: Int(min(size.width, size.height)), ignoreCertErrors: false)
                    }
                } else {
                    SavedMachinesView(store: store, onSelect: select, selectedHost: store.lastUsedHost)

                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan QR to Pair", systemImage: "qrcode.viewfinder")
                    }
                    .buttonStyle(.bordered)

                    // A bare LAN host auto-derives Display B at port+1; for a tunnel URL
                    // append "|wss://displayB..." to place a second screen externally.
                    TextField("Mac address (192.168.1.5) or wss:// URL", text: $host)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .frame(maxWidth: 420)
                    // Optional — blank falls back to the auto-derived host name.
                    TextField("Name (optional)", text: $machineName)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .frame(maxWidth: 420)
                    Button("Connect") { startConnection() }
                        .buttonStyle(.borderedProminent)
                        .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                    Toggle("Nerd Mode (show stream stats)", isOn: $nerdMode)
                        .frame(maxWidth: 420)
                        .foregroundStyle(.gray)
                    switch client.status {
                    case .connecting:
                        VStack(spacing: 6) {
                            ProgressView().tint(.white)
                            if let e = client.lastError {
                                Text(e).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                            }
                        }
                    case .failed(let reason): Text(reason).font(.footnote).foregroundStyle(.red)
                    default: EmptyView()
                    }
                }
            }
            .padding()
        }
    }
}
