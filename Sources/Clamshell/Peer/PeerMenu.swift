import AppKit

// "Shared Desk" submenu for the menu bar app: turn the peer link on/off,
// show this Mac's pairing PIN, pick the edge the peer sits beyond, pair /
// connect to discovered machines, and the file / window actions. Owns the
// PeerManager while enabled (persisted like Native Streaming).

final class PeerMenuController: NSObject {
    private(set) var manager: PeerManager?
    /// Rebuild the status-item menu (AppDelegate's rebuildMenu).
    var onChange: () -> Void = {}
    var isEnabled: Bool { manager != nil }

    func startIfEnabled() {
        if UserDefaults.standard.bool(forKey: "sharedDesk") { start() }
    }

    private func start() {
        guard manager == nil else { return }
        do {
            let m = try PeerManager.makeDefault()
            PeerFeatures.install(on: m)
            m.onChange = { [weak self] in self?.onChange() }
            try m.start()
            manager = m
        } catch {
            clog("PEER: could not start shared desk: \(error)")
            let alert = NSAlert()
            alert.messageText = "Shared Desk could not start"
            alert.informativeText = "\(error.localizedDescription)\n\nIs another copy of Clamshell (or `clamshell peer`) already using port \(peerLinkDefaultPort)?"
            alert.runModal()
        }
        onChange()
    }

    func stop() {
        manager?.stop()
        manager = nil
        onChange()
    }

    func makeMenuItem() -> NSMenuItem {
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Enable Shared Desk", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.state = isEnabled ? .on : .off
        toggle.target = self
        menu.addItem(toggle)

        if let m = manager {
            menu.addItem(.separator())
            menu.addItem(disabled(m.statusLine))
            menu.addItem(disabled("This Mac's pairing PIN: \(m.link.pairingPIN)"))

            let edgeMenu = NSMenu()
            for e in [PeerEdge.left, .right, .top, .bottom] {
                let item = NSMenuItem(title: e.name.capitalized, action: #selector(selectEdge(_:)), keyEquivalent: "")
                item.tag = Int(e.rawValue)
                item.state = m.edgeController.edge == e ? .on : .off
                item.target = self
                edgeMenu.addItem(item)
            }
            let edgeItem = NSMenuItem(title: "Peer Is Beyond This Mac's…", action: nil, keyEquivalent: "")
            menu.addItem(edgeItem)
            menu.setSubmenu(edgeMenu, for: edgeItem)

            menu.addItem(.separator())
            if m.discovered.isEmpty {
                menu.addItem(disabled("No machines found on this network"))
            }
            for (i, p) in m.discovered.enumerated() {
                let paired = p.id.flatMap { m.trust.peer(id: $0) } != nil
                let item = NSMenuItem(title: paired ? "Connect to \(p.name)" : "Pair with \(p.name)…",
                                      action: #selector(connectPeer(_:)), keyEquivalent: "")
                item.tag = i
                item.target = self
                menu.addItem(item)
            }
            menu.addItem(withTitle: "Connect by Address…", action: #selector(connectByAddress), keyEquivalent: "").target = self
            if m.state.isLinked {
                menu.addItem(withTitle: "Disconnect", action: #selector(disconnect), keyEquivalent: "").target = self
            }
            for extra in PeerFeatures.menuItems(for: m) { menu.addItem(extra) }
            if !m.trust.peers.isEmpty {
                menu.addItem(.separator())
                menu.addItem(withTitle: "Forget Paired Machines", action: #selector(forgetAll), keyEquivalent: "").target = self
            }
            if !AXIsProcessTrusted() {
                menu.addItem(.separator())
                menu.addItem(disabled("⚠ Needs Accessibility to control the peer"))
            }
        }

        let item = NSMenuItem(title: "Shared Desk", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    @objc private func toggleEnabled() {
        let on = !isEnabled
        UserDefaults.standard.set(on, forKey: "sharedDesk")
        if on { start() } else { stop() }
    }

    @objc private func selectEdge(_ sender: NSMenuItem) {
        guard let e = PeerEdge(rawValue: UInt8(sender.tag)) else { return }
        manager?.setEdge(e)
    }

    @objc private func connectPeer(_ sender: NSMenuItem) {
        guard let m = manager, sender.tag < m.discovered.count else { return }
        let peer = m.discovered[sender.tag]
        let paired = peer.id.flatMap { m.trust.peer(id: $0) } != nil
        if paired { m.connect(to: peer, pin: nil); return }
        guard let pin = Self.askPIN(for: peer.name) else { return }
        m.connect(to: peer, pin: pin)
    }

    @objc private func connectByAddress() {
        guard let m = manager else { return }
        let alert = NSAlert()
        alert.messageText = "Connect to a machine by address"
        alert.informativeText = "host or host:port (default port \(peerLinkDefaultPort)). Leave the PIN empty for an already-paired machine."
        let host = NSTextField(frame: NSRect(x: 0, y: 30, width: 240, height: 24))
        host.placeholderString = "192.168.1.20"
        let pin = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        pin.placeholderString = "PIN shown on that machine"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 54))
        box.addSubview(host); box.addSubview(pin)
        alert.accessoryView = box
        alert.addButton(withTitle: "Connect"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, !host.stringValue.isEmpty else { return }
        let (h, p) = PeerCommand.parseHostPort(host.stringValue.trimmingCharacters(in: .whitespaces))
        let code = pin.stringValue.filter(\.isNumber)
        m.connect(host: h, port: p, pin: code.count == 6 ? code : nil)
    }

    @objc private func disconnect() { manager?.disconnect() }

    @objc private func forgetAll() {
        guard let m = manager else { return }
        m.disconnect()
        for p in m.trust.peers { m.trust.forget(id: p.id) }
        onChange()
    }

    static func askPIN(for name: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Pair with \(name)"
        alert.informativeText = "Enter the 6-digit pairing PIN shown on \(name) (Shared Desk menu, or printed by `clamshell peer` / the Windows tray)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        field.placeholderString = "123456"
        alert.accessoryView = field
        alert.addButton(withTitle: "Pair"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let pin = field.stringValue.filter(\.isNumber)
        return pin.count == 6 ? pin : nil
    }
}
