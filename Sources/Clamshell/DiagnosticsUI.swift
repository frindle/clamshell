import AppKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

// AppKit windows for the "Diagnostics…" and "Show Pairing QR Code…" menu
// items. The rest of the app is pure NSMenu; these are the only two windows,
// each a small hand-laid NSStackView — no SwiftUI, no xib.

// MARK: - Diagnostics

final class DiagnosticsWindowController: NSWindowController {
    private weak var appDelegate: AppDelegate?
    private let textView = NSTextField(wrappingLabelWithString: "")
    private var refreshTimer: Timer?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Clamshell Diagnostics"
        window.center()
        super.init(window: window)
        window.delegate = self
        buildContent()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildContent() {
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isSelectable = true

        let disconnect = NSButton(title: "Disconnect All Clients", target: self, action: #selector(disconnectAll))
        let restart = NSButton(title: "Restart Streaming", target: self, action: #selector(restart))
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refresh))
        let buttons = NSStackView(views: [disconnect, restart, refresh])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [textView, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            textView.widthAnchor.constraint(equalToConstant: 388),
        ])
        window?.contentView = content
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    @objc private func refresh() {
        textView.stringValue = Self.report(fleet: appDelegate?.streamFleet)
    }

    @objc private func disconnectAll() { appDelegate?.disconnectAllClients(); refresh() }
    @objc private func restart() { appDelegate?.restartStreaming(); refresh() }

    /// Assembled fresh each refresh so it always reflects live permission and
    /// connection state (permissions can flip between launches; clients come
    /// and go). hardwareCodec() is a real VT probe, cached after the first call
    /// since the answer can't change without a reboot.
    private static var cachedHWCodec: StreamCodec?? = nil
    private static func report(fleet: StreamFleet?) -> String {
        func mark(_ ok: Bool) -> String { ok ? "✓" : "✗" }
        var lines: [String] = []
        lines.append("Screen Recording:  \(mark(CGPreflightScreenCaptureAccess()))")
        lines.append("Accessibility:     \(mark(WindowLayoutStore.hasAccessibilityPermission))")
        if cachedHWCodec == nil { cachedHWCodec = VideoEncoder.hardwareCodec() }
        let hw = cachedHWCodec ?? nil
        lines.append("Hardware encoder:  \(hw.map { "✓ (\($0 == .hevc ? "HEVC" : "H.264"))" } ?? "✗ (software fallback)")")
        lines.append("")
        if let fleet, fleet.isServing {
            let status = fleet.clientStatus
            let clients = status.filter { $0.connected }.count
            lines.append("Native streaming:  RUNNING — \(clients) client(s) connected")
            for s in status {
                lines.append("  port \(s.port) (\(s.primary ? "Display A/primary" : "Display \(s.port - streamDefaultPort + 1)")): \(s.connected ? "client connected" : "waiting")")
            }
        } else {
            lines.append("Native streaming:  stopped")
        }
        return lines.joined(separator: "\n")
    }
}

extension DiagnosticsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

// MARK: - Pairing QR

final class PairingQRWindowController: NSWindowController {
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 440),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Pair a Device"
        window.center()
        super.init(window: window)
        buildContent()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Host defaults to the first LAN IPv4 (what an iPad on the same network
    /// dials); a `streamHost` default overrides it for a tunnel hostname.
    private static func currentPairing() -> ClamshellPairing {
        let d = UserDefaults.standard
        let host = d.string(forKey: "streamHost")
            ?? WebServer.lanIPv4s().first?.ip
            ?? "127.0.0.1"
        return ClamshellPairing(host: host)
    }

    private func buildContent() {
        let pairing = Self.currentPairing()

        let imageView = NSImageView()
        imageView.image = Self.qrImage(from: pairing.url, size: 260)
        imageView.imageScaling = .scaleNone
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 260),
            imageView.heightAnchor.constraint(equalToConstant: 260),
        ])

        let caption = NSTextField(wrappingLabelWithString:
            "Scan with the Clamshell app on your iPad or iPhone (Scan QR on the connect screen) to fill in the connection automatically.")
        caption.font = .systemFont(ofSize: 12)
        caption.alignment = .center

        let detail = NSTextField(wrappingLabelWithString: "host: \(pairing.host)")
        detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center

        let stack = NSStackView(views: [imageView, caption, detail])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window?.contentView = content
    }

    override func showWindow(_ sender: Any?) {
        buildContent() // regenerate in case the LAN IP changed
        super.showWindow(sender)
    }

    /// Core Image's built-in QR generator — no third-party dependency.
    static func qrImage(from string: String, size: CGFloat) -> NSImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return NSImage(size: NSSize(width: size, height: size)) }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
