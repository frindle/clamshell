import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let coordinator = CollapseCoordinator()
    private let monitor = ConnectionMonitor()
    private var autoMode = UserDefaults.standard.object(forKey: "autoMode") as? Bool ?? true

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !WindowLayoutStore.hasAccessibilityPermission {
            WindowLayoutStore.requestAccessibilityPermission()
        }

        if let presetName = UserDefaults.standard.string(forKey: "preset"),
           let preset = DisplayPreset.all.first(where: { $0.name == presetName }) {
            coordinator.preset = preset
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon()
        rebuildMenu()

        coordinator.onStateChange = { [weak self] _ in
            self?.updateIcon()
            self?.rebuildMenu()
        }
        monitor.onChange = { [weak self] connected, _ in
            guard let self, self.autoMode else { return }
            self.coordinator.remoteSessionChanged(connected: connected)
        }
        monitor.start()
    }

    private func updateIcon() {
        let symbol = coordinator.state == .collapsed
            ? "rectangle.compress.vertical"
            : "rectangle.expand.vertical"
        statusItem.button?.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: "Clamshell"
        )
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let stateLine = NSMenuItem(
            title: coordinator.state == .collapsed ? "Collapsed (remote)" : "Desk mode",
            action: nil, keyEquivalent: ""
        )
        stateLine.isEnabled = false
        menu.addItem(stateLine)
        menu.addItem(.separator())

        if coordinator.state == .collapsed {
            menu.addItem(withTitle: "Restore Displays Now", action: #selector(restoreNow), keyEquivalent: "r")
                .target = self
        } else {
            menu.addItem(withTitle: "Collapse Now", action: #selector(collapseNow), keyEquivalent: "c")
                .target = self
        }

        let auto = NSMenuItem(title: "Auto (collapse on remote connect)", action: #selector(toggleAuto), keyEquivalent: "")
        auto.state = autoMode ? .on : .off
        auto.target = self
        menu.addItem(auto)

        let presetMenu = NSMenu()
        for preset in DisplayPreset.all {
            let item = NSMenuItem(title: preset.name, action: #selector(selectPreset(_:)), keyEquivalent: "")
            item.state = coordinator.preset == preset ? .on : .off
            item.representedObject = preset.name
            item.target = self
            presetMenu.addItem(item)
        }
        let presetItem = NSMenuItem(title: "Remote Screen Size", action: nil, keyEquivalent: "")
        menu.addItem(presetItem)
        menu.setSubmenu(presetMenu, for: presetItem)

        if !WindowLayoutStore.hasAccessibilityPermission {
            menu.addItem(.separator())
            let warn = NSMenuItem(
                title: "⚠ Grant Accessibility for window restore",
                action: #selector(openAccessibilitySettings), keyEquivalent: ""
            )
            warn.target = self
            menu.addItem(warn)
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Clamshell", action: #selector(quit), keyEquivalent: "q")
            .target = self

        statusItem.menu = menu
    }

    @objc private func collapseNow() { coordinator.collapse() }
    @objc private func restoreNow() { coordinator.restore() }

    @objc private func toggleAuto() {
        autoMode.toggle()
        UserDefaults.standard.set(autoMode, forKey: "autoMode")
        rebuildMenu()
    }

    @objc private func selectPreset(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let preset = DisplayPreset.all.first(where: { $0.name == name }) else { return }
        coordinator.preset = preset
        UserDefaults.standard.set(preset.name, forKey: "preset")
        rebuildMenu()
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        if coordinator.state == .collapsed {
            coordinator.restore()
        }
        NSApp.terminate(nil)
    }
}
