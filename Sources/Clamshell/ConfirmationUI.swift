import AppKit

// AppKit panel for a pending remote confirmation. Same shape as
// DiagnosticsUI.swift: hand-laid NSStackView, no SwiftUI, no xib, a repeating
// timer driving the refresh.
//
// An NSPanel rather than a plain window because this is a transient,
// time-boxed prompt that has to stay on top of whatever the user is looking
// at while they reach for the key — floating, and explicitly NOT
// hidesOnDeactivate (the default for utility panels would hide it the moment
// focus moved, which is exactly when the countdown matters most).

final class ConfirmationWindowController: NSWindowController {
    private let coordinator: ConfirmationCoordinator
    private let actionLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(wrappingLabelWithString: "")
    private let countdownLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private var refreshTimer: Timer?
    private var dismissTimer: Timer?

    /// How long a settled result stays on screen before the panel closes
    /// itself — long enough to read, short enough that it never becomes
    /// another window to tidy up.
    private let dismissDelay: TimeInterval = 2.5

    init(coordinator: ConfirmationCoordinator) {
        self.coordinator = coordinator
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 170),
            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Confirm Action"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.center()
        super.init(window: panel)
        panel.delegate = self
        buildContent()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildContent() {
        let caption = NSTextField(labelWithString: "A remote confirmation is pending:")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor

        actionLabel.font = .monospacedSystemFont(ofSize: 15, weight: .semibold)
        actionLabel.isSelectable = true

        stateLabel.font = .systemFont(ofSize: 12)
        // Wrapping labels need this to report an honest multi-line height;
        // the rejection line carries whole card-error sentences.
        stateLabel.preferredMaxLayoutWidth = 328

        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countdownLabel.textColor = .secondaryLabelColor

        progress.style = .bar
        progress.isIndeterminate = false
        progress.controlSize = .small
        progress.usesThreadedAnimation = false
        progress.minValue = 0
        progress.maxValue = ConfirmationBridge.nonceTTL

        let stack = NSStackView(views: [caption, actionLabel, stateLabel, progress, countdownLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stateLabel.widthAnchor.constraint(equalToConstant: 328),
            progress.widthAnchor.constraint(equalToConstant: 328),
        ])
        window?.contentView = content
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        refresh()
        refreshTimer?.invalidate()
        // 0.2s so the countdown ticks look continuous rather than stepping.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    /// Repaints from the coordinator's live state. Pull rather than push:
    /// the same refresh serves both the per-tick countdown and state changes,
    /// so there's only one path that can be wrong.
    @objc private func refresh() {
        actionLabel.stringValue = coordinator.actionName ?? "—"

        switch coordinator.state {
        case .idle:
            stateLabel.stringValue = "No confirmation pending."
            stateLabel.textColor = .secondaryLabelColor
        case .connecting:
            stateLabel.stringValue = "Reading the key… (no touch needed yet)"
            stateLabel.textColor = .labelColor
        case .awaitingTouch:
            stateLabel.stringValue = "Touch the YubiKey now — it should be blinking."
            stateLabel.textColor = .labelColor
        case .verifying:
            stateLabel.stringValue = "Verifying signature…"
            stateLabel.textColor = .labelColor
        case .approved:
            stateLabel.stringValue = "Approved — signature verified on hardware."
            stateLabel.textColor = .systemGreen
        case .rejected(let why):
            stateLabel.stringValue = "Rejected — \(why)"
            stateLabel.textColor = .systemRed
        case .expired:
            stateLabel.stringValue = "Expired — no valid signature in time."
            stateLabel.textColor = .systemOrange
        }

        // No challenge issued yet means no honest clock to show, so the bar
        // sits full rather than implying time has already been lost. Once
        // settled there's no time left to describe, so it goes away entirely
        // rather than sitting at empty (which reads as failure next to a
        // green "Approved").
        let remaining = coordinator.secondsRemaining
        progress.isHidden = coordinator.isTerminal
        progress.doubleValue = remaining ?? ConfirmationBridge.nonceTTL
        if coordinator.isTerminal {
            countdownLabel.stringValue = ""
        } else if let remaining {
            countdownLabel.stringValue = String(format: "Expires in %.0fs", ceil(remaining))
        } else {
            countdownLabel.stringValue = "Challenge not issued yet"
        }

        if coordinator.isTerminal {
            scheduleDismiss()
        } else {
            // A fresh run started while an old result was still on screen.
            dismissTimer?.invalidate()
            dismissTimer = nil
        }

        resizeToFitContent()
    }

    /// A rejection can carry a whole card-error sentence ("the binary needs
    /// the com.apple.security.smartcard entitlement…"), which is far taller
    /// than the one-line states. Grow to whatever the text needs rather than
    /// clipping the one message the user most needs to read — anchored at the
    /// top-left so the title bar doesn't hop around between states.
    private func resizeToFitContent() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let height = content.fittingSize.height
        guard height > 0, abs(content.frame.height - height) > 0.5 else { return }
        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        window.setContentSize(NSSize(width: content.frame.width, height: height))
        window.setFrameTopLeftPoint(topLeft)
    }

    private func scheduleDismiss() {
        guard dismissTimer == nil else { return }
        dismissTimer = Timer.scheduledTimer(withTimeInterval: dismissDelay, repeats: false) { [weak self] _ in
            self?.close()
        }
    }
}

extension ConfirmationWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        dismissTimer?.invalidate()
        dismissTimer = nil
    }
}
