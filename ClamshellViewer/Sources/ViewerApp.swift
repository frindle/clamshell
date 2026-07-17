import SwiftUI

// ClamshellViewer — iPad client for the Clamshell stream protocol
// (see ../PROTOCOL.md). Displays Display A full-screen on the iPad and, when a
// physical external screen is attached, Display B on that screen. StreamClient
// (network), VideoView (render/input), StreamProtocol and FrameAssembler are
// shared with the iPhone ClamshellControl target and/or the Mac host.

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
        window.rootViewController = UIHostingController(
            rootView: ExternalDisplayView(client: Connection.shared.external))
        window.isHidden = false
        self.window = window
        Connection.shared.externalDisplayConnected()
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

    private var params: (host: String, accessId: String, accessSecret: String)?
    private var externalAttached = false

    init() {
        external.playsAudio = false
        // Report the iPad's real screen size in HELLO so the Mac auto-sizes
        // its virtual display to this device (no manual preset needed).
        primary.reportedPixelSize = UIScreen.main.nativeBounds.size
    }

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

    // Called when the external UIWindowScene connects/disconnects. The
    // primary connection tells the Mac about the second surface so it can
    // auto-enter/leave dual display mode (Auto-Detect Dual Display).
    func externalDisplayConnected() {
        externalAttached = true
        primary.updateReportedDisplay(secondDisplay: true)
        connectExternalIfAttached()
    }
    func externalDisplayDisconnected() {
        externalAttached = false
        primary.updateReportedDisplay(secondDisplay: false)
        external.disconnect()
    }

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
                    .overlay(alignment: .top) {
                        if client.softwareEncoding {
                            SoftwareEncodingBanner().padding(.top, 8)
                        }
                    }
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
            TextField("Mac address (192.168.1.5) or wss:// URL", text: $host)
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
