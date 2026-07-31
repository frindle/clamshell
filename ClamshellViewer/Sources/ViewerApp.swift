import SwiftUI

// ClamshellViewer — iPad client for the Clamshell stream protocol
// (see ../PROTOCOL.md). Displays Display A full-screen on the iPad and, when a
// physical external screen is attached, Display B on that screen. StreamClient
// (network), VideoView (render/input), StreamProtocol and FrameAssembler are
// shared with the iPhone ClamshellControl target and/or the Mac host.
//
// "External Display Only" mode (Connection.externalOnlyMode, off by default)
// is a second, simpler pairing for the same external-scene plumbing: instead
// of a second virtual Mac display (Display B), the single `primary` stream is
// what plays on the external screen, and the iPad's own screen drops the
// video for a small status view — so the iPad itself stays free for other
// apps while a monitor is attached. See ExternalDisplaySceneDelegate and
// ContentView.externalOnlyStatusView.

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
        // .windowExternalDisplayNonInteractive is the iOS 16+ replacement for the
        // deprecated .windowExternalDisplay; deployment target is iOS 17.
        clogViewer("scene connecting with role \(connectingSceneSession.role.rawValue)")
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
        guard let windowScene = scene as? UIWindowScene else {
            clogViewer("external scene connected but is not a UIWindowScene — ignoring")
            return
        }
        clogViewer("external display scene CONNECTED: \(describeScreen(windowScene.screen))")
        let window = UIWindow(windowScene: windowScene) // sized to the external screen's own bounds
        // External Display Only mode: the external screen shows the single
        // `primary` stream (same one that would otherwise be on the iPad's own
        // screen) instead of Display B, so the iPad's screen is free to go
        // back to the connect/status view (or the user can leave the app
        // entirely) while the video plays out only on the monitor.
        let externalClient = Connection.shared.externalOnlyMode ? Connection.shared.primary : Connection.shared.external
        // Manual pan+zoom / cursor-follow auto-pan only applies to External
        // Display Only mode's single-stream path — Display B keeps its plain
        // aspect-fit behavior unchanged.
        let viewport = Connection.shared.externalOnlyMode ? Connection.shared.viewport : nil
        window.rootViewController = UIHostingController(
            rootView: ExternalDisplayView(client: externalClient, viewport: viewport))
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
    /// Manual pan+zoom / cursor-follow auto-pan state for External Display
    /// Only mode's external screen — see VideoView.swift. One instance for
    /// the app's lifetime (reset on each new connection, not recreated) since
    /// it's rendered from a UIKit scene delegate outside SwiftUI's view tree.
    let viewport = Viewport()

    private var connectedHost: String?
    /// True whenever a physical external screen is currently attached
    /// (regardless of `externalOnlyMode`) — drives the iPad-screen UI.
    @Published var externalAttached = false
    /// When on, an attached external display shows the single Mac screen
    /// (the `primary` stream) instead of Display B, and the iPad's own screen
    /// switches to a lightweight status view instead of the video — freeing
    /// it for Home Screen / other apps while the session keeps running.
    /// Persisted; **off by default** so existing dual-display behavior
    /// (Display A on iPad + Display B external) is unaffected unless the
    /// user opts in.
    @Published var externalOnlyMode: Bool {
        didSet { UserDefaults.standard.set(externalOnlyMode, forKey: "externalOnlyMode") }
    }

    init() {
        externalOnlyMode = UserDefaults.standard.bool(forKey: "externalOnlyMode")
        external.playsAudio = false
        // Report the iPad's real screen size in HELLO so the Mac auto-sizes
        // its virtual display to this device (no manual preset needed).
        primary.reportedPixelSize = UIScreen.main.nativeBounds.size
    }

    func connect(host: String) {
        viewport.reset()
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
        // External Display Only: no Display B to negotiate — the external
        // screen just plays the primary client's existing single stream.
        guard !externalOnlyMode else { return }
        // The primary connection carries Display B's size too (only the
        // primary's report is honored host-side), so the Mac sizes Display B
        // to the real external monitor instead of the fixed presetB.
        primary.updateReportedDisplay(secondDisplay: true, secondPixelSize: size)
        connectExternalIfAttached()
    }
    func externalDisplayDisconnected() {
        externalAttached = false
        // Mid-session unplug while in External Display Only mode: nothing to
        // tear down here — `primary` was never paused, so ContentView falls
        // straight back to showing its video on the iPad's own screen the
        // moment `externalAttached` flips (see ContentView.body). This is the
        // "fall back rather than freeze" choice for a live session.
        guard !externalOnlyMode else { return }
        primary.updateReportedDisplay(secondDisplay: false)
        external.disconnect()
    }

    /// Connect Display B only when a physical external screen is actually
    /// attached and dual-display mode applies — otherwise we'd waste a whole
    /// encode+stream pipeline (or spin reconnecting to a port the Mac isn't
    /// serving). No-op in External Display Only mode (no Display B exists).
    private func connectExternalIfAttached() {
        guard !externalOnlyMode,
              externalAttached,
              let host = connectedHost,
              let bHost = Self.secondDisplayEndpoint(from: host) else { return }
        external.connect(host: bHost)
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

// MARK: - UI

struct ContentView: View {
    @ObservedObject private var connection = Connection.shared
    @ObservedObject private var client = Connection.shared.primary
    @StateObject private var store = MachineStore()
    @AppStorage("hostAddress") private var host = ""
    @AppStorage("nerdMode") private var nerdMode = false
    @State private var showScanner = false
    @State private var showSettings = false

    private func startConnection() {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return }
        // Both manual and scanned connections are saved (dedup by host).
        store.upsert(MachineProfile(name: ContentViewNaming.deriveName(h), host: h))
        store.markUsed(h)
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
            if case .streaming = client.status {
                if connection.externalOnlyMode && connection.externalAttached {
                    externalOnlyStatusView
                } else {
                    VideoView(client: client)
                        .ignoresSafeArea()
                        .overlay(alignment: .top) {
                            VStack(spacing: 6) {
                                if client.hostLocked { LockScreenBanner(fallbackURL: client.browserFallbackURL) }
                                if client.softwareEncoding { SoftwareEncodingBanner() }
                                QualityIndicator(client: client)
                            }
                            .padding(.top, 8)
                        }
                        .overlay(alignment: .topTrailing) {
                            HStack(spacing: 16) {
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
                        }
                }
            } else {
                connectForm
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear(perform: preselectLastUsed)
        .sheet(isPresented: $showSettings) {
            InSessionSettingsView(store: store, currentHost: host,
                                  onSwitch: switchTo, onClose: { showSettings = false },
                                  externalOnlyToggle: $connection.externalOnlyMode)
        }
        .fullScreenCover(isPresented: $showScanner) {
            QRScannerView(onScan: applyScan, onCancel: { showScanner = false })
                .ignoresSafeArea()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            if let text = UIPasteboard.general.string { client.syncClipboard(text) }
        }
    }

    /// Shown on the iPad's own screen instead of the video, while External
    /// Display Only mode is on and a monitor is attached — the actual video
    /// is playing on the external scene (see ExternalDisplaySceneDelegate).
    /// Doubles as the manual pan+zoom gesture surface (PanZoomGestureSurface,
    /// full-screen underneath the status card): two-finger drag pans, pinch
    /// zooms — same "control surface on the device, video on the external
    /// screen" split ClamshellControl's trackpad already uses. See
    /// VideoView.swift for the render/gesture/protocol pieces.
    private var externalOnlyStatusView: some View {
        ZStack {
            // Full-screen, behind the status card. The card below only
            // occupies its own intrinsic size (it's not given a full-screen
            // frame), so its 1-finger buttons and this view's 2-finger
            // pan / pinch never compete for the same touches, and blank space
            // around the card still reaches this gesture surface.
            PanZoomGestureSurface(viewport: connection.viewport)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 16) {
                Image(systemName: "tv.and.hifispeaker.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.6))
                Text("Streaming to external display")
                    .font(.headline).foregroundStyle(.white)
                Text("Two-finger drag pans, pinch zooms the external display.")
                    .font(.footnote).foregroundStyle(.gray)
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
                if client.hostLocked { LockScreenBanner(fallbackURL: client.browserFallbackURL) }
                if client.softwareEncoding { SoftwareEncodingBanner() }
                QualityIndicator(client: client)
                panZoomControls
                HStack(spacing: 24) {
                    Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape.fill") }
                    Button(role: .destructive) { connection.disconnect() } label: {
                        Label("Disconnect", systemImage: "xmark.circle.fill")
                    }
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
            .padding()
        }
    }

    /// Auto-Follow toggle + Reset, and the live zoom readout — small enough
    /// to not compete with the status card, big enough to find without
    /// hunting. Auto-Follow starts on; a manual pan/pinch flips it off (see
    /// Viewport's manual-override doc comment) and this is how the user turns
    /// it back on.
    @ObservedObject private var viewportState = Connection.shared.viewport
    private var panZoomControls: some View {
        VStack(spacing: 10) {
            Toggle(isOn: $viewportState.autoFollow) {
                Label("Auto-Follow Cursor", systemImage: "cursorarrow.motionlines")
            }
            .toggleStyle(.button)
            .tint(.white.opacity(0.25))
            .foregroundStyle(.white)
            if viewportState.zoom > 1.01 {
                HStack(spacing: 12) {
                    Text("Zoom \(String(format: "%.1fx", viewportState.zoom))")
                        .font(.caption).foregroundStyle(.gray)
                    Button("Reset View") { viewportState.reset() }
                        .font(.caption)
                }
            }
        }
    }

    private var connectForm: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("Clamshell Viewer").font(.title2).foregroundStyle(.white)

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
                Button("Connect") { startConnection() }
                    .buttonStyle(.borderedProminent)
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                Toggle("Nerd Mode (show stream stats)", isOn: $nerdMode)
                    .frame(maxWidth: 420)
                    .foregroundStyle(.gray)
                Toggle("External display only (frees this screen)", isOn: $connection.externalOnlyMode)
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
            .padding()
        }
    }
}
