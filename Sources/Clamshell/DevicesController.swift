import AppKit
import UserNotifications

// The Devices menu, and what drives the approval window: which device it asks
// about next, the decisions made somewhere else that it shows, and the alert
// in front of every change the menu can make (PROTOCOL.md "Approving a
// device").
//
// Everything here runs on the main thread.
//
// - A device becomes trusted in two places only: the Approve button of the
//   approval window, and "Approve…" on a denied device, which asks again in
//   an alert that names the device and its fingerprint.
// - Every menu item that changes something asks first. What it asked about
//   is looked up again after the answer, because the list can change while
//   an alert is up.
// - A menu item carries a device id, never a row number, so a list that
//   changed under an open menu cannot make a click land on another device.
// - In the alerts Escape cancels and no key presses the other button, which
//   also stays disabled for a moment. Typing or a click that was meant for
//   something else cannot change anything.

final class DevicesController: NSObject {
    /// Called when what the menu or the status icon shows may have changed.
    var onChange: (() -> Void)?

    /// How long the button that makes a change stays disabled in an alert.
    static let confirmDelay: TimeInterval = 1

    private lazy var auth = HostAuth.shared
    private var prompts = ApprovalPrompts()
    private var records: [DeviceRecord] = []
    private var panel: DeviceApprovalPanelController?
    private var observers: [NSObjectProtocol] = []
    private var started = false
    /// Refreshes the window's small print while it is asking.
    private var tick: Timer?
    /// Notices a waiting device whose 24 hours ran out: the list has no event
    /// for that.
    private var housekeeping: Timer?
    /// Brings the window back when its quiet time is over.
    private var quietTimer: Timer?
    private var alertIsUp = false
    /// Approval as this controller last saw or set it, to tell a change made
    /// in this menu from one made somewhere else.
    private var approvalWasOn = true
    /// Waiting devices the window has asked about at least once.
    private var shown: Set<String> = []
    /// The quiet period a "device is asking" notification was posted for.
    private var notifiedForQuietUntil: TimeInterval = 0
    private var waitingNotificationIsUp = false
    /// Decisions made elsewhere that were posted as notifications, by
    /// notification identifier, so a click can show them again.
    private var posted: [String: ApprovalPrompts.Notice] = [:]

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        tick?.invalidate()
        housekeeping?.invalidate()
        quietTimer?.invalidate()
    }

    /// Starts following the device list. Call once the app has launched.
    func start() {
        guard !started else { return }
        started = true
        approvalWasOn = auth.requireApproval
        let center = NotificationCenter.default
        // Both are posted on whatever thread made the change.
        observers.append(center.addObserver(forName: DeviceTrustStore.didChange, object: auth.store,
                                            queue: nil) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        })
        observers.append(center.addObserver(forName: HostAuth.approvalDidChange, object: auth,
                                            queue: nil) { [weak self] _ in
            DispatchQueue.main.async { self?.approvalChanged() }
        })
        auth.startWatchingSetting()
        if Self.canNotify { UNUserNotificationCenter.current().delegate = self }
        housekeeping = Self.timer(every: 60) { [weak self] in self?.lookAgain() }
        refresh()
    }

    /// How many devices are waiting for the user's answer.
    var waitingCount: Int { records.reduce(0) { $0 + ($1.state == .waiting ? 1 : 0) } }

    // MARK: following the list

    private func refresh(picked: String? = nil) {
        records = auth.store.all()
        let news = prompts.note(records)
        updatePanel(picked: picked)
        announce(news)
        announceWaiting()
        onChange?()
    }

    /// For the timers: the list has no event for a waiting device whose time
    /// ran out, and "asked 5 min ago" ages by itself.
    private func lookAgain() {
        if auth.store.all() != records { refresh() } else { updatePanel() }
    }

    private func approvalChanged() {
        let on = auth.requireApproval
        if on != approvalWasOn {
            // Not changed in this menu, or `setApproval` would have noted it.
            approvalWasOn = on
            if on {
                withdraw([Self.approvalOffNotification])
            } else {
                post(Self.approvalOffNotification, title: "Device approval was turned off",
                     body: "Any device that can reach this Mac can now see and control it. "
                         + "Click to turn approval back on.", quiet: false)
            }
        }
        refresh()
    }

    // MARK: the approval window

    private func updatePanel(picked: String? = nil) {
        let now = Date().timeIntervalSince1970
        switch prompts.step(records: records, asking: panel?.askingId,
                            noticeVisible: panel?.isShowingNotice ?? false, picked: picked, now: now) {
        case .keep:
            break
        case .ask(let device):
            // "2 of 3" counts the devices the window will ask about, not the
            // ones the user closed it on.
            let queue = ApprovalPrompts.waiting(records).filter {
                $0.id == device.id || !prompts.setAside.contains($0.id)
            }
            let position = (queue.firstIndex { $0.id == device.id } ?? 0) + 1
            shown.insert(device.id)
            approvalPanel().ask(device, position: position, of: queue.count,
                                connectedNow: auth.hasWaitingConnection(deviceId: device.id),
                                nameIsTaken: ApprovalPrompts.sharesNameWithTrusted(device, among: records))
        case .notice(let notice):
            approvalPanel().showNotice(ApprovalPrompts.sentence(for: notice, among: records),
                                       device: notice.device, canRevoke: notice.device.state == .trusted)
        case .dismiss:
            panel?.dismiss()
        }
        scheduleTimers(now: now)
    }

    /// Made on first use: nothing touches AppKit before the app has launched.
    private func approvalPanel() -> DeviceApprovalPanelController {
        if let panel { return panel }
        let made = DeviceApprovalPanelController()
        made.onDecision = { [weak self] device, decision in self?.decided(device, decision) }
        made.onRevoke = { [weak self] device in self?.revokedInWindow(device) }
        // These two can arrive while the window is still closing, so what it
        // shows next is worked out on the next turn of the run loop.
        made.onNoticeDone = { [weak self] in
            DispatchQueue.main.async { self?.updatePanel() }
        }
        made.onSetAside = { [weak self] id in
            guard let self else { return }
            self.prompts.questionEnded(id, .closed, in: self.records, now: Date().timeIntervalSince1970)
            DispatchQueue.main.async {
                self.updatePanel()
                self.announceWaiting()
                self.onChange?()
            }
        }
        panel = made
        return made
    }

    private func scheduleTimers(now: TimeInterval) {
        let asking = panel?.askingId != nil
        if asking, tick == nil {
            tick = Self.timer(every: 5) { [weak self] in self?.lookAgain() }
        } else if !asking {
            tick?.invalidate()
            tick = nil
        }
        quietTimer?.invalidate()
        quietTimer = nil
        if !asking, prompts.isQuiet(now: now) {
            quietTimer = Self.timer(after: prompts.quietUntil - now + 0.05) { [weak self] in self?.updatePanel() }
        }
    }

    /// The user pressed Approve or Deny in the window.
    private func decided(_ device: DeviceRecord, _ decision: DeviceTrustStore.Decision) {
        prompts.questionEnded(device.id, decision == .approve ? .approved : .denied, in: records,
                              now: Date().timeIntervalSince1970)
        prompts.expect(device.id, decision == .approve ? .trusted : .denied)
        let saved = auth.store.decide(id: device.id, decision, by: DeviceTrustStore.decidedOnHost,
                                      onlyIfWaiting: true)
        if let saved {
            clog("DEVICES: \(saved.fingerprint) (\(saved.name)) was "
                + "\(saved.state == .trusted ? "approved" : "denied") in the approval window")
        }
        refresh()
        // Nothing changed and it is still waiting: the list could not be
        // saved. Decided somewhere else meanwhile shows as a notice instead.
        if saved == nil, state(of: device.id) == .waiting { couldNotSave() }
    }

    /// "Revoke" on a decision that was made somewhere else. No second
    /// question: this only takes trust away, and it is there for when the
    /// approval was not the user's.
    private func revokedInWindow(_ device: DeviceRecord) {
        prompts.expect(device.id, .denied)
        let saved = auth.store.revoke(id: device.id, by: DeviceTrustStore.decidedOnHost)
        if let saved { clog("DEVICES: \(saved.fingerprint) (\(saved.name)) was revoked in the approval window") }
        refresh()
        if saved == nil, state(of: device.id) == .trusted { couldNotSave() }
    }

    private func state(of id: String) -> DeviceState? { records.first { $0.id == id }?.state }

    // MARK: the menu

    /// Lines for the top of the Clamshell menu: what needs the user.
    func attentionItems() -> [NSMenuItem] {
        guard started else { return [] }
        var items: [NSMenuItem] = []
        let waiting = waitingCount
        if waiting > 0 {
            items.append(item(waiting == 1 ? "1 device is waiting for approval…"
                                           : "\(waiting) devices are waiting for approval…",
                              #selector(reviewWaiting)))
        }
        if !auth.requireApproval {
            items.append(item("⚠ Device approval is off…", #selector(turnApprovalBackOn)))
        }
        return items
    }

    /// The Devices submenu, built from the list as it is now.
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        guard started else { return menu }
        let all = auth.store.all()
        let now = Date().timeIntervalSince1970
        let open = auth.openSessions()

        let waiting = ApprovalPrompts.waiting(all)
        if !waiting.isEmpty {
            menu.addItem(header("Waiting for approval"))
            for device in waiting {
                let row = item(ApprovalPrompts.quoted(device.label), #selector(showWaiting(_:)), id: device.id)
                let detail = "\(device.fingerprint), asked \(DeviceCommands.ago(device.firstSeen, now: now))"
                if #available(macOS 14.4, *) { row.subtitle = detail } else { row.title += "  \(detail)" }
                menu.addItem(row)
            }
        }

        let trusted = all.filter { $0.state == .trusted }.sorted(by: Self.byName)
        if !trusted.isEmpty {
            menu.addItem(header("Trusted"))
            for device in trusted {
                let connected = (open.devices[device.id] ?? 0) > 0
                let from = device.address.isEmpty ? "" : " from \(device.fromText)"
                let seen = connected ? "Connected now\(from)"
                                     : "Last seen \(DeviceCommands.ago(device.lastSeen, now: now))\(from)"
                let details = NSMenu()
                details.addItem(note(device.fingerprint))
                details.addItem(note(seen))
                if let line = Self.decidedLine(device, verb: "Approved", among: all, now: now) {
                    details.addItem(note(line))
                }
                details.addItem(.separator())
                details.addItem(item("Revoke…", #selector(revoke(_:)), id: device.id))
                details.addItem(item("Forget…", #selector(forget(_:)), id: device.id))
                let row = NSMenuItem(title: ApprovalPrompts.quoted(device.label), action: nil, keyEquivalent: "")
                if connected {
                    if #available(macOS 14.4, *) { row.subtitle = "Connected now" } else { row.title += "  connected now" }
                }
                menu.addItem(row)
                menu.setSubmenu(details, for: row)
            }
        }

        let denied = all.filter { $0.state == .denied }.sorted { ($0.decidedAt ?? 0) > ($1.decidedAt ?? 0) }
        if !denied.isEmpty {
            menu.addItem(header("Denied"))
            for device in denied {
                let details = NSMenu()
                details.addItem(note(device.fingerprint))
                if let line = Self.decidedLine(device, verb: "Denied", among: all, now: now) {
                    details.addItem(note(line))
                }
                details.addItem(.separator())
                details.addItem(item("Approve…", #selector(approveDenied(_:)), id: device.id))
                details.addItem(item("Forget…", #selector(forget(_:)), id: device.id))
                let row = NSMenuItem(title: ApprovalPrompts.quoted(device.label), action: nil, keyEquivalent: "")
                menu.addItem(row)
                menu.setSubmenu(details, for: row)
            }
        }

        if all.isEmpty { menu.addItem(note("No devices yet")) }

        menu.addItem(.separator())
        let toggle = item("Ask Before a New Device Can Connect", #selector(toggleApproval))
        toggle.state = auth.requireApproval ? .on : .off
        menu.addItem(toggle)
        let unapproved = auth.unapprovedSessions()
        if unapproved > 0 {
            menu.addItem(note("\(Self.sessions(unapproved)) connected without approval"))
        }

        menu.addItem(.separator())
        menu.addItem(note("This Mac’s fingerprint: \(auth.identity.fingerprint)"))
        if !auth.identity.isPersistent {
            menu.addItem(note("Its key could not be stored and changes when Clamshell restarts"))
        }
        if !auth.store.canPersist {
            menu.addItem(note("The device list could not be stored and lasts until Clamshell quits"))
        }
        return menu
    }

    private func item(_ title: String, _ action: Selector, id: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = id
        return item
    }

    private func note(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        return note(title)
    }

    private static func byName(_ a: DeviceRecord, _ b: DeviceRecord) -> Bool {
        let order = a.label.localizedCaseInsensitiveCompare(b.label)
        return order == .orderedSame ? a.firstSeen < b.firstSeen : order == .orderedAscending
    }

    /// "Approved on this Mac, 3 d ago". nil when nothing is recorded.
    static func decidedLine(_ device: DeviceRecord, verb: String, among records: [DeviceRecord],
                            now: TimeInterval) -> String? {
        let source = ApprovalPrompts.source(of: device.decidedBy, among: records)
        let when = device.decidedAt.map { DeviceCommands.ago($0, now: now) }
        switch (source.isEmpty, when) {
        case (true, nil): return nil
        case (true, let when?): return "\(verb) \(when)"
        case (false, nil): return "\(verb) \(source)"
        case (false, let when?): return "\(verb) \(source), \(when)"
        }
    }

    static func sessions(_ count: Int) -> String { count == 1 ? "1 session" : "\(count) sessions" }

    // MARK: what the menu does

    /// "N devices are waiting…" and the notification that says the same: go
    /// through all of them, including the ones the window was closed on.
    @objc private func reviewWaiting() {
        let waiting = ApprovalPrompts.waiting(auth.store.all())
        guard let first = waiting.first else {
            refresh()
            return
        }
        for device in waiting { prompts.bringBack(device.id) }
        // A question that is already on screen stays; the others follow it.
        refresh(picked: panel?.askingId ?? first.id)
    }

    @objc private func showWaiting(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        prompts.bringBack(id)
        refresh(picked: id)
    }

    @objc private func approveDenied(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let device = current(id, .denied) else { return }
        guard confirm("Approve \(ApprovalPrompts.quoted(device.label))?",
                      "Fingerprint \(device.fingerprint).\n\nThis device was denied before. Approving it lets it "
                          + "see this Mac’s screen and control its keyboard and mouse whenever it connects. "
                          + "Approve it only if the device shows this same fingerprint on its own screen.",
                      action: "Approve", destructive: false),
              current(id, .denied) != nil else { return }
        prompts.expect(id, .trusted)
        let saved = auth.store.decide(id: id, .approve, by: DeviceTrustStore.decidedOnHost, onlyIfWaiting: false)
        if let saved { clog("DEVICES: \(saved.fingerprint) (\(saved.name)) was approved in the Devices menu") }
        refresh()
        if saved == nil, state(of: id) == .denied { couldNotSave() }
    }

    @objc private func revoke(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let device = current(id, .trusted) else { return }
        guard confirm("Revoke \(ApprovalPrompts.quoted(device.label))?",
                      "Fingerprint \(device.fingerprint).\n\nIt is disconnected now and cannot connect again "
                          + "unless you approve it.",
                      action: "Revoke", destructive: true),
              current(id, .trusted) != nil else { return }
        prompts.expect(id, .denied)
        let saved = auth.store.revoke(id: id, by: DeviceTrustStore.decidedOnHost)
        if let saved { clog("DEVICES: \(saved.fingerprint) (\(saved.name)) was revoked in the Devices menu") }
        refresh()
        if saved == nil, state(of: id) == .trusted { couldNotSave() }
    }

    @objc private func forget(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        guard let device = auth.store.record(id: id), device.state != .waiting else {
            refresh()
            return
        }
        let what = device.state == .trusted
            ? "It is disconnected now and taken off the list. If it connects again it has to ask for "
                + "approval like a new device."
            : "It is taken off the list. If it connects again it can ask for approval again."
        guard confirm("Forget \(ApprovalPrompts.quoted(device.label))?",
                      "Fingerprint \(device.fingerprint).\n\n\(what)", action: "Forget", destructive: true),
              current(id, device.state) != nil else { return }
        let removed = auth.store.forget(id: id)
        if let removed { clog("DEVICES: \(removed.fingerprint) (\(removed.name)) was forgotten in the Devices menu") }
        refresh()
        if removed == nil, state(of: id) != nil { couldNotSave() }
    }

    @objc private func toggleApproval() {
        if auth.requireApproval {
            guard confirm("Turn off device approval?",
                          "Any device that can reach this Mac over the network will be able to see its screen "
                              + "and control its keyboard and mouse without asking. The devices you trust "
                              + "stay on the list.",
                          action: "Turn Off", destructive: true) else { return }
            setApproval(false)
        } else {
            // Only worth a question when it throws somebody out.
            let unapproved = auth.unapprovedSessions()
            if unapproved > 0 {
                guard confirm("Turn on device approval?",
                              "\(Self.sessions(unapproved)) connected without approval will be disconnected. "
                                  + "After that only devices you approve can connect.",
                              action: "Turn On", destructive: false) else { return }
            }
            setApproval(true)
        }
    }

    /// The warning line at the top of the menu, and the notification posted
    /// when approval was turned off somewhere else.
    @objc private func turnApprovalBackOn() {
        guard !auth.requireApproval else {
            refresh()
            return
        }
        let unapproved = auth.unapprovedSessions()
        guard confirm("Turn device approval back on?",
                      "While it is off, any device that can reach this Mac over the network can see its screen "
                          + "and control its keyboard and mouse."
                          + (unapproved > 0 ? " \(Self.sessions(unapproved)) connected without approval "
                              + "will be disconnected." : ""),
                      action: "Turn On", destructive: false) else { return }
        setApproval(true)
    }

    private func setApproval(_ on: Bool) {
        auth.setRequireApproval(on)
        approvalWasOn = auth.requireApproval
        if approvalWasOn { withdraw([Self.approvalOffNotification]) }
        refresh()
    }

    /// The device as the list has it now, if it is still in `state`. Brings
    /// the menu up to date when it is not.
    private func current(_ id: String, _ state: DeviceState) -> DeviceRecord? {
        if let device = auth.store.record(id: id), device.state == state { return device }
        refresh()
        return nil
    }

    // MARK: alerts

    /// Asks before a change. True only for a click on the `action` button.
    private func confirm(_ title: String, _ text: String, action: String, destructive: Bool) -> Bool {
        guard !alertIsUp else {
            NSSound.beep()
            return false
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        // Escape cancels and Return presses nothing: no keystroke that was on
        // its way to another app can make the change.
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        let go = alert.addButton(withTitle: action)
        go.keyEquivalent = ""
        go.hasDestructiveAction = destructive
        // Nor can a click that was already on its way to something else.
        go.isEnabled = false
        let arm = Self.timer(after: Self.confirmDelay) { go.isEnabled = true }
        alertIsUp = true
        defer {
            arm.invalidate()
            alertIsUp = false
        }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func couldNotSave() {
        guard !alertIsUp else { return }
        let alert = NSAlert()
        alert.messageText = "The device list could not be saved"
        alert.informativeText = "Nothing was changed. The reason is in ~/Library/Logs/Clamshell.log."
        alert.addButton(withTitle: "OK")
        alertIsUp = true
        defer { alertIsUp = false }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Timers that also run while a menu is open or an alert is up.
    private static func timer(after delay: TimeInterval, _ body: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: max(0, delay), repeats: false) { _ in body() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private static func timer(every interval: TimeInterval, _ body: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in body() }
        timer.tolerance = interval / 5
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    // MARK: notifications

    /// UNUserNotificationCenter needs an app bundle; the bare binary has none.
    private static let canNotify = Bundle.main.bundleIdentifier != nil
    private static let waitingNotification = "devices-waiting"
    private static let approvalOffNotification = "device-approval-off"
    private static let decidedPrefix = "device-decided-"
    private static let maxPosted = 64

    /// One notification for each decision made somewhere else. The window
    /// shows it for a few seconds; the notification is what is still there
    /// when the user comes back to the Mac.
    private func announce(_ news: [ApprovalPrompts.Notice]) {
        guard Self.canNotify else { return }
        // Forget the ones that no longer say what the list says.
        let stale = posted.filter { entry in
            !records.contains {
                $0.id == entry.value.device.id && $0.state == entry.value.device.state
                    && $0.decidedAt == entry.value.device.decidedAt
            }
        }.map(\.key)
        for identifier in stale { posted[identifier] = nil }
        // Not the ones that are posted again below under the same identifier:
        // taking a notification away is not immediate and could catch the
        // new one.
        let again = Set(news.map { Self.decidedPrefix + $0.device.id })
        withdraw(stale.filter { !again.contains($0) })

        for notice in news {
            let device = notice.device
            let identifier = Self.decidedPrefix + device.id
            if posted.count >= Self.maxPosted, posted[identifier] == nil { continue }
            posted[identifier] = notice
            let approved = device.state == .trusted
            post(identifier,
                 title: approved ? "A device was approved" : (notice.wasTrusted ? "A device was revoked" : "A device was denied"),
                 body: ApprovalPrompts.sentence(for: notice, among: records) + " Fingerprint \(device.fingerprint)."
                     + (approved ? " Click if that was not you." : ""),
                 quiet: !approved)
        }
    }

    /// While the window is staying away it does not open for a new device.
    /// The first one in each quiet period gets a notification instead, and a
    /// silent one: closing the window was the user saying "not now".
    private func announceWaiting() {
        guard Self.canNotify else { return }
        let waiting = ApprovalPrompts.waiting(records)
        shown.formIntersection(waiting.map(\.id))
        let unseen = waiting.filter { !shown.contains($0.id) }
        let asking = panel?.askingId != nil
        if unseen.isEmpty || asking {
            if waitingNotificationIsUp {
                waitingNotificationIsUp = false
                withdraw([Self.waitingNotification])
            }
            return
        }
        guard prompts.isQuiet(now: Date().timeIntervalSince1970),
              notifiedForQuietUntil != prompts.quietUntil else { return }
        notifiedForQuietUntil = prompts.quietUntil
        waitingNotificationIsUp = true
        if unseen.count == 1, let device = unseen.first {
            post(Self.waitingNotification, title: "A device is asking to connect",
                 body: "\(ApprovalPrompts.quoted(device.label)) \(device.fingerprint) is waiting for approval. "
                     + "Click to answer.", quiet: true)
        } else {
            post(Self.waitingNotification, title: "\(unseen.count) devices are asking to connect",
                 body: "Click to see who is waiting for approval.", quiet: true)
        }
    }

    private func post(_ identifier: String, title: String, body: String, quiet: Bool) {
        guard Self.canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if quiet {
            content.interruptionLevel = .passive
        } else {
            content.sound = .default
        }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { clog("DEVICES: could not post a notification (\(error))") }
        }
    }

    private func withdraw(_ identifiers: [String]) {
        guard Self.canNotify, !identifiers.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    /// The user clicked one of this controller's notifications. Clicking only
    /// ever opens a question; it decides nothing.
    private func opened(notification identifier: String) {
        guard started else { return }
        if identifier == Self.waitingNotification {
            reviewWaiting()
        } else if identifier == Self.approvalOffNotification {
            turnApprovalBackOn()
        } else if let notice = posted[identifier] {
            records = auth.store.all()
            guard let now = records.first(where: { $0.id == notice.device.id }),
                  now.state == notice.device.state, now.decidedAt == notice.device.decidedAt else { return }
            prompts.showAgain(ApprovalPrompts.Notice(device: now, wasTrusted: notice.wasTrusted))
            updatePanel()
        }
    }
}

extension DevicesController: UNUserNotificationCenterDelegate {
    /// Clamshell has no Dock icon and is rarely the active app, but when it
    /// is (an alert is up), its notifications should still show.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            DispatchQueue.main.async { [weak self] in self?.opened(notification: identifier) }
        }
        completionHandler()
    }
}
