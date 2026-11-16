import AppKit

// The window that asks whether a new device may connect (PROTOCOL.md
// "Approving a device"). Same build as ConfirmationUI.swift: a hand-laid
// NSStackView in a floating panel.
//
// Approving here is what lets a device see and control this Mac, so the
// window is built not to be answered by accident:
// - It never takes keyboard focus and no key presses a button, so typing
//   that was meant for another app cannot approve anything.
// - Both buttons stay disabled for a moment whenever the window shows
//   something new, so a click that was already on its way to something else
//   cannot land on them.
// - There is one window and it asks about one device at a time.
// - Closing it decides nothing. The device keeps waiting in the Devices menu.

final class DeviceApprovalPanelController: NSWindowController {
    /// How long the buttons stay disabled after the window shows something
    /// new.
    static let approveDelay: TimeInterval = 1.5
    /// How long a decision made somewhere else stays on screen.
    static let noticeTime: TimeInterval = 10

    /// The user's answer for the device being asked about.
    var onDecision: ((DeviceRecord, DeviceTrustStore.Decision) -> Void)?
    /// "Revoke" on a decision made somewhere else.
    var onRevoke: ((DeviceRecord) -> Void)?
    /// The notice was acknowledged or its time ran out.
    var onNoticeDone: (() -> Void)?
    /// The user closed the window without deciding.
    var onSetAside: (() -> Void)?

    private enum Content {
        case nothing
        case asking(DeviceRecord)
        case notice(DeviceRecord, canRevoke: Bool)
    }
    private var content = Content.nothing

    private let caption = NSTextField(wrappingLabelWithString: "")
    private let nameLabel = NSTextField(wrappingLabelWithString: "")
    private let fingerprintLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let queueLabel = NSTextField(labelWithString: "")
    private let leftButton = NSButton(title: "", target: nil, action: nil)
    private let rightButton = NSButton(title: "", target: nil, action: nil)
    private var armTimer: Timer?
    private var noticeTimer: Timer?
    /// Set while the window is closed by this class, so that is not taken
    /// for the user closing it.
    private var closingItself = false

    private static let textWidth: CGFloat = 348

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 220),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Clamshell"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        // Visible whichever Space or full-screen app the user is in.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.center()
        super.init(window: panel)
        panel.delegate = self
        buildContent()
    }
    required init?(coder: NSCoder) { fatalError() }

    var isShowing: Bool { window?.isVisible == true }

    /// The device being asked about, if the window is asking.
    var askingId: String? {
        if case .asking(let d) = content, isShowing { return d.id }
        return nil
    }

    var isShowingNotice: Bool {
        if case .notice = content, isShowing { return true }
        return false
    }

    private func buildContent() {
        caption.font = .systemFont(ofSize: 12)
        caption.textColor = .secondaryLabelColor

        nameLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        nameLabel.maximumNumberOfLines = 2
        nameLabel.lineBreakMode = .byTruncatingTail

        fingerprintLabel.font = .monospacedSystemFont(ofSize: 22, weight: .medium)
        fingerprintLabel.isSelectable = true
        fingerprintLabel.setAccessibilityLabel("Fingerprint")

        hintLabel.font = .systemFont(ofSize: 12)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        queueLabel.font = .systemFont(ofSize: 11)
        queueLabel.textColor = .secondaryLabelColor

        for label in [caption, nameLabel, hintLabel, detailLabel] {
            label.preferredMaxLayoutWidth = Self.textWidth
        }

        // No key equivalents on either button: see the note at the top.
        leftButton.bezelStyle = .rounded
        leftButton.target = self
        leftButton.action = #selector(leftPressed)
        leftButton.refusesFirstResponder = true
        rightButton.bezelStyle = .rounded
        rightButton.target = self
        rightButton.action = #selector(rightPressed)
        rightButton.refusesFirstResponder = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [queueLabel, spacer, leftButton, rightButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [caption, nameLabel, fingerprintLabel, hintLabel, detailLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(4, after: caption)
        stack.setCustomSpacing(12, after: nameLabel)
        stack.setCustomSpacing(14, after: detailLabel)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            buttons.widthAnchor.constraint(equalToConstant: Self.textWidth),
            caption.widthAnchor.constraint(equalToConstant: Self.textWidth),
            nameLabel.widthAnchor.constraint(equalToConstant: Self.textWidth),
            hintLabel.widthAnchor.constraint(equalToConstant: Self.textWidth),
            detailLabel.widthAnchor.constraint(equalToConstant: Self.textWidth),
        ])
        window?.contentView = view
    }

    // MARK: what the window shows

    /// Asks about `device`. `position` of `total` devices are waiting.
    /// `nameIsTaken` says a trusted device already goes by the same name.
    /// Showing the same device again only refreshes the small print; it does
    /// not restart the wait before a button can be pressed.
    func ask(_ device: DeviceRecord, position: Int, of total: Int, connectedNow: Bool, nameIsTaken: Bool) {
        let sameDevice = askingId == device.id
        content = .asking(device)
        noticeTimer?.invalidate()
        noticeTimer = nil

        caption.stringValue = "A new device is asking to see and control this Mac. It calls itself:"
        nameLabel.stringValue = device.label
        fingerprintLabel.stringValue = device.fingerprint
        hintLabel.stringValue = "Approve it only if the device shows this same fingerprint on its own screen."
        hintLabel.isHidden = false
        let from = device.address.isEmpty ? "an unknown address" : device.address
        let asked = DeviceCommands.ago(device.firstSeen, now: Date().timeIntervalSince1970)
        detailLabel.stringValue = "Asked \(asked) from \(from)."
            + (connectedNow ? "" : " It is not connected right now.")
            + (nameIsTaken ? " A device you already trust has the same name; this one has a different key." : "")
        queueLabel.stringValue = total > 1 ? "\(position) of \(total) waiting" : ""
        leftButton.title = "Deny"
        leftButton.isHidden = false
        rightButton.title = "Approve"

        if !sameDevice { disarmBriefly() }
        present()
    }

    /// Turns both buttons off and back on after `approveDelay`.
    private func disarmBriefly() {
        leftButton.isEnabled = false
        rightButton.isEnabled = false
        armTimer?.invalidate()
        armTimer = Self.timer(after: Self.approveDelay) { [weak self] in
            guard let self else { return }
            if case .nothing = self.content { return }
            self.leftButton.isEnabled = true
            self.rightButton.isEnabled = true
        }
    }

    /// A timer that also runs while a menu is open or an alert is up, so the
    /// window does not freeze behind them.
    private static func timer(after delay: TimeInterval, _ body: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in body() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// Shows a decision that was made somewhere else. `text` is the whole
    /// sentence; `canRevoke` offers to take an approval back.
    func showNotice(_ text: String, device: DeviceRecord, canRevoke: Bool) {
        content = .notice(device, canRevoke: canRevoke)
        armTimer?.invalidate()
        armTimer = nil

        caption.stringValue = "Decided somewhere other than this window:"
        nameLabel.stringValue = text
        fingerprintLabel.stringValue = device.fingerprint
        hintLabel.isHidden = true
        detailLabel.stringValue = canRevoke
            ? "If that was not you, revoke it now. The device is disconnected and cannot come back until you approve it."
            : "You can change this in the Devices menu."
        queueLabel.stringValue = ""
        leftButton.title = "Revoke"
        leftButton.isHidden = !canRevoke
        rightButton.title = "OK"
        disarmBriefly()

        noticeTimer?.invalidate()
        noticeTimer = Self.timer(after: Self.noticeTime) { [weak self] in
            guard let self, case .notice = self.content else { return }
            self.content = .nothing
            self.onNoticeDone?()
        }
        present()
    }

    /// Takes the window off screen without that counting as the user closing
    /// it.
    func dismiss() {
        content = .nothing
        armTimer?.invalidate()
        armTimer = nil
        noticeTimer?.invalidate()
        noticeTimer = nil
        guard isShowing else { return }
        closingItself = true
        window?.close()
        closingItself = false
    }

    private func present() {
        guard let window else { return }
        resizeToFitContent()
        // Front, without making Clamshell the active app: whatever the user
        // is typing into keeps the keyboard.
        if !window.isVisible { window.center() }
        window.orderFrontRegardless()
    }

    private func resizeToFitContent() {
        guard let window, let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        let height = view.fittingSize.height
        guard height > 0, abs(view.frame.height - height) > 0.5 else { return }
        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        window.setContentSize(NSSize(width: view.frame.width, height: height))
        window.setFrameTopLeftPoint(topLeft)
    }

    // MARK: buttons

    @objc private func leftPressed() {
        guard leftButton.isEnabled else { return }
        switch content {
        case .asking(let device):
            content = .nothing
            onDecision?(device, .deny)
        case .notice(let device, let canRevoke):
            guard canRevoke else { return }
            noticeTimer?.invalidate()
            noticeTimer = nil
            content = .nothing
            onRevoke?(device)
        case .nothing:
            break
        }
    }

    @objc private func rightPressed() {
        guard rightButton.isEnabled else { return }
        switch content {
        case .asking(let device):
            content = .nothing
            onDecision?(device, .approve)
        case .notice:
            noticeTimer?.invalidate()
            noticeTimer = nil
            content = .nothing
            onNoticeDone?()
        case .nothing:
            break
        }
    }
}

extension DeviceApprovalPanelController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        armTimer?.invalidate()
        armTimer = nil
        noticeTimer?.invalidate()
        noticeTimer = nil
        guard !closingItself else { return }
        let wasAsking: Bool
        if case .asking = content { wasAsking = true } else { wasAsking = false }
        let wasNotice: Bool
        if case .notice = content { wasNotice = true } else { wasNotice = false }
        content = .nothing
        if wasAsking { onSetAside?() }
        if wasNotice { onNoticeDone?() }
    }
}
