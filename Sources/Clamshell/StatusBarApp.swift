import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var updateAvailable: String? // e.g. "v0.4.0" when newer than us
    private let coordinator = CollapseCoordinator()
    private let monitor = ConnectionMonitor()
    private let webServer = WebServer()
    private var autoMode = UserDefaults.standard.object(forKey: "autoMode") as? Bool ?? true

    // Remote-session state is the OR of the two signals: polled VNC/Jump
    // detection and live browser (noVNC) sessions. Either alone keeps the
    // collapse active.
    private var vncSessionActive = false
    private var webSessionActive = false

    /// The current collapse was commanded externally (Sunshine prep-command).
    /// The poller can't see a live Moonlight stream (Sunshine's serverinfo is
    /// arm-only, see ConnectionMonitor), so suppress poll-driven restore until
    /// the matching external restore — cleared whenever the coordinator
    /// returns to idle by any path.
    private var externallyCollapsed = false

    /// The current collapse was driven by a native-stream client (source ==
    /// "stream"); only then may a stream-side restore request tear it down.
    private var streamCollapsed = false

    /// When on (default), a native-stream client reporting a second display
    /// surface auto-enables dual display mode for that session (and reporting
    /// none auto-disables it). Off = the manual Dual Display Mode toggle
    /// alone decides, exactly as before.
    private var autoDualDetect = UserDefaults.standard.object(forKey: "autoDualDetect") as? Bool ?? true

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !WindowLayoutStore.hasAccessibilityPermission {
            WindowLayoutStore.requestAccessibilityPermission()
        }

        if let presetName = UserDefaults.standard.string(forKey: "preset"),
           let preset = DisplayPreset.all.first(where: { $0.name == presetName }) {
            coordinator.preset = preset
        }
        coordinator.dualMode = UserDefaults.standard.bool(forKey: "dualMode")
        if let presetBName = UserDefaults.standard.string(forKey: "presetB"),
           let presetB = DisplayPreset.all.first(where: { $0.name == presetBName }) {
            coordinator.presetB = presetB
        }
        syncDualPresets()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon()
        rebuildMenu()

        coordinator.onStateChange = { [weak self] state in
            guard let self else { return }
            if state == .idle {
                self.externallyCollapsed = false
                self.streamCollapsed = false
                self.restoreSavedPreset() // undo any client-dimension/dual override
            }
            self.updateIcon()
            self.rebuildMenu()
        }
        monitor.onChange = { [weak self] connected, _ in
            guard let self else { return }
            self.vncSessionActive = connected
            self.recomputeSessionState()
        }
        webServer.onSessionChange = { [weak self] active in
            guard let self else { return }
            self.webSessionActive = active
            self.recomputeSessionState()
        }
        monitor.start()
        webServer.bindHosts = UserDefaults.standard.stringArray(forKey: "bindHosts")
            ?? UserDefaults.standard.string(forKey: "bindHost").map { [$0] } // migrate pre-multi-select key
            ?? []
        // Optional token gating the /clipboard endpoint (see README):
        //   defaults write com.frindle.clamshell clipboardToken <secret>
        webServer.clipboardToken = UserDefaults.standard.string(forKey: "clipboardToken")
        if UserDefaults.standard.bool(forKey: "webAccess") {
            webServer.start()
        }

        // A system sleep kills any live remote stream. On wake, drop the
        // external-collapse latch (Sunshine can't send its undo command for
        // a stream that died in sleep) and re-evaluate — the poller then
        // schedules a restore if nothing reconnects, instead of leaving the
        // Mac collapsed forever.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.coordinator.state != .idle else { return }
            clog("system woke while collapsed — re-evaluating session state")
            self.externallyCollapsed = false
            self.recomputeSessionState()
        }

        // External collapse/restore commands (`Clamshell collapse|restore`),
        // used by Sunshine prep-commands for event-driven triggering.
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.frindle.clamshell.collapse"), object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            // Optional client pixel dimensions (Sunshine prep-command env
            // vars, or a native-stream client's HELLO report) — size the
            // virtual display to the connecting device.
            var preset = self.coordinator.preset
            if let w = (note.userInfo?["width"] as? String).flatMap(UInt32.init),
               let h = (note.userInfo?["height"] as? String).flatMap(UInt32.init),
               w >= 640, h >= 480 {
                // Floor odd client dimensions to even so points * 2 == pixels.
                let ew = w & ~1, eh = h & ~1
                preset = DisplayPreset(
                    name: "Client (\(ew)×\(eh))", pointsWide: ew / 2, pointsHigh: eh / 2
                )
            }
            let fromStream = (note.userInfo?["source"] as? String) == "stream"
            // A native-stream client also reports whether it has a second
            // display surface (external monitor on the iPad) — auto-drive
            // dual mode from that, unless the user turned auto-detect off.
            var dual = UserDefaults.standard.bool(forKey: "dualMode")
            if fromStream, self.autoDualDetect, let ext = note.userInfo?["external"] as? String {
                dual = ext == "1"
            }
            // When the client reports the external monitor's real pixel size,
            // size Display B to it (same treatment as Display A above) instead
            // of the fixed presetB.
            var presetB: DisplayPreset? = nil
            if dual, let bw = (note.userInfo?["widthB"] as? String).flatMap(UInt32.init),
               let bh = (note.userInfo?["heightB"] as? String).flatMap(UInt32.init),
               bw >= 640, bh >= 480 {
                let ew = bw & ~1, eh = bh & ~1
                presetB = DisplayPreset(name: "Client B (\(ew)×\(eh))", pointsWide: ew / 2, pointsHigh: eh / 2)
            }
            clog("external collapse command (\(preset.name), dual \(dual)\(presetB.map { ", B \($0.name)" } ?? "")\(fromStream ? ", stream" : ""))")
            self.applyExternalCollapse(preset: preset, presetB: presetB, dual: dual, fromStream: fromStream)
        }
        dnc.addObserver(forName: Notification.Name("com.frindle.clamshell.restore"), object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            let fromStream = (note.userInfo?["source"] as? String) == "stream"
            // A stream-side restore (client gone for the grace period) may
            // only undo a collapse the stream itself drove — never one the
            // user or Sunshine owns.
            if fromStream && !self.streamCollapsed { return }
            clog("external restore command\(fromStream ? " (stream client gone)" : "")")
            self.coordinator.restore()
        }

        checkForUpdate()
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.checkForUpdate()
        }
    }

    /// Compares the running bundle version against the latest GitHub release
    /// tag. Skipped for the bare dev binary (no bundle version).
    private func checkForUpdate() {
        guard let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return }
        let url = URL(string: "https://api.github.com/repos/frindle/clamshell/releases/latest")!
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { return }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateAvailable = latest.compare(current, options: .numeric) == .orderedDescending ? tag : nil
                if self.updateAvailable != nil { clog("update available: \(tag) (running \(current))") }
                self.rebuildMenu()
                self.maybeAutoInstall()
            }
        }.resume()
    }

    private func recomputeSessionState() {
        guard autoMode else { return }
        let connected = vncSessionActive || webSessionActive
        // An externally-commanded collapse owns its lifecycle; don't restore
        // out from under a stream the poller can't see.
        if !connected && externallyCollapsed { return }
        coordinator.remoteSessionChanged(connected: connected)
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

    private let menu = NSMenu()

    private func rebuildMenu() {
        menu.removeAllItems()

        let stateLine = NSMenuItem(
            title: coordinator.state == .collapsed ? "Collapsed (remote)" : "Desk mode",
            action: nil, keyEquivalent: ""
        )
        stateLine.isEnabled = false
        menu.addItem(stateLine)
        if let tag = updateAvailable {
            let item = NSMenuItem(
                title: installingUpdate ? "Installing \(tag)…" : "⬆ Install Update \(tag)",
                action: installingUpdate ? nil : #selector(installUpdate), keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
        }
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
        let presetItem = NSMenuItem(
            title: coordinator.dualMode ? "Remote Screen Size (Display A)" : "Remote Screen Size",
            action: nil, keyEquivalent: ""
        )
        menu.addItem(presetItem)
        menu.setSubmenu(presetMenu, for: presetItem)

        let dual = NSMenuItem(title: "Dual Display Mode (two virtual screens)", action: #selector(toggleDual), keyEquivalent: "")
        dual.state = coordinator.dualMode ? .on : .off
        dual.target = self
        menu.addItem(dual)

        let autoDual = NSMenuItem(title: "Auto-Detect Dual Display (native stream)", action: #selector(toggleAutoDual), keyEquivalent: "")
        autoDual.state = autoDualDetect ? .on : .off
        autoDual.target = self
        menu.addItem(autoDual)

        if coordinator.dualMode {
            let presetBMenu = NSMenu()
            for preset in DisplayPreset.all {
                let item = NSMenuItem(title: preset.name, action: #selector(selectPresetB(_:)), keyEquivalent: "")
                item.state = coordinator.presetB == preset ? .on : .off
                item.representedObject = preset.name
                item.target = self
                presetBMenu.addItem(item)
            }
            let presetBItem = NSMenuItem(title: "External Monitor Size (Display B)", action: nil, keyEquivalent: "")
            menu.addItem(presetBItem)
            menu.setSubmenu(presetBMenu, for: presetBItem)
        }

        let web = NSMenuItem(
            title: webServer.isRunning
                ? "Web Access On — http://\(webServer.displayHost):\(webServer.httpPort)"
                : "Enable Web Access (browser remote desktop)",
            action: #selector(toggleWeb), keyEquivalent: ""
        )
        web.state = webServer.isRunning ? .on : .off
        web.target = self
        menu.addItem(web)

        // Bind-address picker — only interesting with more than one LAN IP.
        // Multi-select: each interface toggles independently; "All Interfaces"
        // clears the selection (empty selection = bind everything).
        let ips = WebServer.lanIPv4s()
        if ips.count > 1 {
            let bindMenu = NSMenu()
            let all = NSMenuItem(title: "All Interfaces", action: #selector(selectBind(_:)), keyEquivalent: "")
            all.state = webServer.bindHosts.isEmpty ? .on : .off
            all.target = self
            bindMenu.addItem(all)
            for (name, ip) in ips {
                let item = NSMenuItem(title: "\(ip) (\(name))", action: #selector(selectBind(_:)), keyEquivalent: "")
                item.representedObject = ip
                item.state = webServer.bindHosts.contains(ip) ? .on : .off
                item.target = self
                bindMenu.addItem(item)
            }
            let bindItem = NSMenuItem(title: "Listen On", action: nil, keyEquivalent: "")
            menu.addItem(bindItem)
            menu.setSubmenu(bindMenu, for: bindItem)
        }

        let mute = NSMenuItem(title: "Mute Speakers While Remote", action: #selector(toggleMute), keyEquivalent: "")
        mute.state = coordinator.comfort.muteWhileCollapsed ? .on : .off
        mute.target = self
        menu.addItem(mute)

        // SMAppService only works from a real .app bundle; hide the toggle
        // when running the bare SwiftPM binary during development.
        if Bundle.main.bundleIdentifier != nil {
            let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            login.target = self
            menu.addItem(login)

            menu.addItem(withTitle: "Check Reboot Readiness…", action: #selector(checkRebootReadiness), keyEquivalent: "")
                .target = self
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Log File", action: #selector(openLog), keyEquivalent: "l")
            .target = self

        if !WindowLayoutStore.hasAccessibilityPermission {
            menu.addItem(.separator())
            let warn = NSMenuItem(
                title: "⚠ Grant Accessibility for window restore",
                action: #selector(openAccessibilitySettings), keyEquivalent: ""
            )
            warn.target = self
            menu.addItem(warn)
            // macOS only re-evaluates the TCC grant at process launch.
            let hint = NSMenuItem(title: "   (already granted? quit & reopen Clamshell)", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Clamshell", action: #selector(quit), keyEquivalent: "q")
            .target = self

        menu.delegate = self // re-check permissions/state every open
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Repopulate on every open so the Accessibility warning clears
        // without waiting for a state change.
        rebuildMenu()
    }

    private var installingUpdate = false

    /// Auto-install when nothing is at stake: not collapsed, no live
    /// sessions. A surprise relaunch mid-remote-session would drop the
    /// user's connection.
    private func maybeAutoInstall() {
        guard updateAvailable != nil, !installingUpdate,
              UpdateInstaller.canInstall,
              coordinator.state == .idle,
              !vncSessionActive, !webSessionActive else { return }
        installUpdate()
    }

    @objc private func installUpdate() {
        guard !installingUpdate else { return }
        installingUpdate = true
        rebuildMenu()
        UpdateInstaller.install { [weak self] errorMessage in
            // Only called on failure — success relaunches the app.
            self?.installingUpdate = false
            self?.rebuildMenu()
            clog("update aborted: \(errorMessage) — opening releases page")
            NSWorkspace.shared.open(URL(string: "https://github.com/frindle/clamshell/releases")!)
        }
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
        syncDualPresets()
        rebuildMenu()
    }

    /// The web server needs the two display sizes to build the dual-mode
    /// picker and cropped views; nil switches it back to the classic flow.
    private func syncDualPresets() {
        webServer.dualPresets = coordinator.dualMode ? (coordinator.preset, coordinator.presetB) : nil
    }

    @objc private func toggleAutoDual() {
        autoDualDetect.toggle()
        UserDefaults.standard.set(autoDualDetect, forKey: "autoDualDetect")
        rebuildMenu()
    }

    @objc private func toggleDual() {
        coordinator.dualMode.toggle()
        UserDefaults.standard.set(coordinator.dualMode, forKey: "dualMode")
        syncDualPresets()
        rebuildMenu()
    }

    @objc private func selectPresetB(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let preset = DisplayPreset.all.first(where: { $0.name == name }) else { return }
        coordinator.presetB = preset
        UserDefaults.standard.set(preset.name, forKey: "presetB")
        syncDualPresets()
        rebuildMenu()
    }

    @objc private func toggleWeb() {
        if webServer.isRunning {
            webServer.stop()
        } else {
            webServer.start()
        }
        UserDefaults.standard.set(webServer.isRunning, forKey: "webAccess")
        rebuildMenu()
    }

    @objc private func selectBind(_ sender: NSMenuItem) {
        if let ip = sender.representedObject as? String {
            // Toggle this interface in/out of the selection.
            if let idx = webServer.bindHosts.firstIndex(of: ip) {
                webServer.bindHosts.remove(at: idx)
            } else {
                webServer.bindHosts.append(ip)
            }
        } else {
            webServer.bindHosts = [] // All Interfaces
        }
        UserDefaults.standard.set(webServer.bindHosts, forKey: "bindHosts")
        UserDefaults.standard.removeObject(forKey: "bindHost") // superseded single-choice key
        if webServer.isRunning { // rebind live
            webServer.stop()
            webServer.start()
        }
        rebuildMenu()
    }

    @objc private func toggleMute() {
        coordinator.comfort.muteWhileCollapsed.toggle()
        UserDefaults.standard.set(coordinator.comfort.muteWhileCollapsed, forKey: "muteWhileCollapsed")
        rebuildMenu()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            clog("start-at-login toggle failed: \(error)")
        }
        rebuildMenu()
    }

    @objc private func checkRebootReadiness() {
        let report = RebootReadiness.check()
        let alert = NSAlert()
        alert.messageText = "Reboot Readiness"
        alert.informativeText = RebootReadiness.summary(report)
        alert.addButton(withTitle: "OK")
        if !report.autorestartOn {
            alert.addButton(withTitle: "Copy pmset command")
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(RebootReadiness.autorestartCommand, forType: .string)
        }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: clamshellLogPath))
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// Every terminate path (menu Quit, update relaunch, logout) waits for
    /// the restore — including the deferred window-layout pass — before the
    /// process dies. Terminating immediately used to kill the 2s-delayed
    /// window restore, leaving windows stranded on a dead virtual display.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if coordinator.state == .idle { return .terminateNow }
        coordinator.restore {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Applies an externally-commanded collapse (Sunshine prep-command or a
    /// native-stream client's display report). Already collapsed with the
    /// same geometry: keep it (and cancel any pending grace-period restore).
    /// Geometry changed mid-collapse (new client resolution, or a second
    /// screen appeared/vanished): rebuild the collapse with the new shape.
    private func applyExternalCollapse(preset: DisplayPreset, presetB: DisplayPreset? = nil, dual: Bool, fromStream: Bool) {
        if coordinator.state != .idle {
            if coordinator.preset == preset && coordinator.dualMode == dual
                && (presetB == nil || coordinator.presetB == presetB) {
                externallyCollapsed = true
                if fromStream { streamCollapsed = true }
                coordinator.collapse() // no-op that cancels a pending restore
                return
            }
            clog("external collapse geometry changed — recollapsing")
            coordinator.restore { [weak self] in
                self?.applyExternalCollapse(preset: preset, presetB: presetB, dual: dual, fromStream: fromStream)
            }
            return
        }
        coordinator.preset = preset
        if let presetB { coordinator.presetB = presetB }
        coordinator.dualMode = dual
        syncDualPresets()
        externallyCollapsed = true
        if fromStream { streamCollapsed = true }
        coordinator.collapse()
    }

    /// Re-apply the user's saved preset (and manual dual-mode choice) after
    /// any collapse ends, so a client-dimension/auto-dual override doesn't
    /// stick for later manual collapses.
    private func restoreSavedPreset() {
        let name = UserDefaults.standard.string(forKey: "preset")
        let saved = DisplayPreset.all.first { $0.name == name } ?? .iPadAir13
        let savedDual = UserDefaults.standard.bool(forKey: "dualMode")
        guard coordinator.preset != saved || coordinator.dualMode != savedDual else { return }
        coordinator.preset = saved
        coordinator.dualMode = savedDual
        syncDualPresets()
    }
}
