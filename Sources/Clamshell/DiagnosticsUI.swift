import AppKit
import CoreGraphics

// AppKit window for the "Diagnostics…" menu item. The rest of the app is
// pure NSMenu; this is the only window, a small hand-laid NSStackView — no
// SwiftUI, no xib.

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

