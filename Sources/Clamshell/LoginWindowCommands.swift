import Foundation

/// `clamshell loginwindow install | uninstall | status | sync`.
///
/// install and uninstall need root (`sudo`). status needs none (it can say
/// less without root). sync is run by launchd as root; it is not meant to be
/// typed. See `LoginWindowInstall` for what is installed.
enum LoginWindowCommands {
    static let usage = """
        Usage: sudo clamshell loginwindow install [--user <name>]
               sudo clamshell loginwindow uninstall
                    clamshell loginwindow status
        """

    static func run(_ args: [String], layout: LoginWindowInstall.Layout = .init(),
                    out: (String) -> Void = { print($0) }) -> Int32 {
        guard let command = args.first else { out(usage); return 64 }
        switch command {
        case "install": return install(Array(args.dropFirst()), layout: layout, out: out)
        case "uninstall": return uninstall(layout: layout, out: out)
        case "status": return status(layout: layout, out: out)
        case "sync": return sync(layout: layout, out: out)
        default: out(usage); return 64
        }
    }

    // MARK: install

    private static func install(_ args: [String], layout: LoginWindowInstall.Layout, out: (String) -> Void) -> Int32 {
        guard geteuid() == 0 else { out("Run with sudo."); return 1 }
        var user = ProcessInfo.processInfo.environment["SUDO_USER"] ?? ""
        if let i = args.firstIndex(of: "--user") {
            guard i + 1 < args.count else { out(usage); return 64 }
            user = args[i + 1]
        }
        guard !user.isEmpty, user != "root", let pw = getpwnam(user) else {
            out("Say whose Clamshell to mirror: sudo clamshell loginwindow install --user <name>")
            return 64
        }
        let home = String(cString: pw.pointee.pw_dir)
        let config = LoginWindowInstall.Config(
            user: user, uid: pw.pointee.pw_uid,
            userStateDirectory: home + "/Library/Application Support/Clamshell")

        let appURL = Bundle.main.bundleURL
        guard appURL.pathExtension == "app", let resources = Bundle.main.resourceURL else {
            out("Run this from the installed app: /Applications/Clamshell.app/Contents/MacOS/Clamshell loginwindow install")
            return 1
        }
        do {
            let templates = resources.appendingPathComponent("loginwindow-agent", isDirectory: true)
            let agent = try String(contentsOf: templates.appendingPathComponent("\(LoginWindowInstall.agentLabel).plist"),
                                   encoding: .utf8)
            let syncer = try String(contentsOf: templates.appendingPathComponent("\(LoginWindowInstall.syncLabel).plist"),
                                    encoding: .utf8)
            let agentPlist = try LoginWindowInstall.render(template: agent, values: LoginWindowInstall.agentValues(layout))
            let syncPlist = try LoginWindowInstall.render(template: syncer, values: LoginWindowInstall.syncValues(layout, config))

            // 1. A root-owned copy of the app, put in place whole.
            try makeRootDirectory(layout.root)
            let staged = layout.root.appendingPathComponent("Clamshell.app.new", isDirectory: true)
            try? FileManager.default.removeItem(at: staged)
            try runTool("/usr/bin/ditto", [appURL.path, staged.path])
            try runTool("/usr/sbin/chown", ["-R", "root:wheel", staged.path])
            try runTool("/bin/chmod", ["-R", "go-w", staged.path])
            try? FileManager.default.removeItem(at: layout.appCopy)
            try FileManager.default.moveItem(at: staged, to: layout.appCopy)

            // 2. Whose state to mirror, then the first copy of it.
            try SecureFile.replace(layout.configFile, contents: try JSONEncoder().encode(config))
            try runTool("/bin/chmod", ["644", layout.configFile.path]) // names a user and a folder, no secret
            let outcome = try LoginWindowInstall.sync(userDirectory: URL(fileURLWithPath: config.userStateDirectory),
                                                      userUID: config.uid, mirror: layout.stateDirectory)
            out("Copied \(user)'s host key and device list (\(outcome)).")

            // 3. The two plists, then the sync daemon.
            try writePlist(agentPlist, to: layout.agentPlist)
            try writePlist(syncPlist, to: layout.syncPlist)
            _ = try? runTool("/bin/launchctl", ["bootout", "system/\(LoginWindowInstall.syncLabel)"])
            try runTool("/bin/launchctl", ["bootstrap", "system", layout.syncPlist.path])
        } catch {
            out("Install failed: \(error)")
            return 1
        }
        out("Installed. The agent starts the next time the login window appears (log out or restart).")
        out("Log: \(layout.log)")
        out("SSH is untouched; keep it on for the pre-boot disk unlock.")
        out("Remove with: sudo clamshell loginwindow uninstall")
        return 0
    }

    // MARK: uninstall

    private static func uninstall(layout: LoginWindowInstall.Layout, out: (String) -> Void) -> Int32 {
        guard geteuid() == 0 else { out("Run with sudo."); return 1 }
        _ = try? runTool("/bin/launchctl", ["bootout", "system/\(LoginWindowInstall.syncLabel)"])
        var failed = false
        for url in [layout.agentPlist, layout.syncPlist, layout.root] {
            do {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            } catch {
                out("Could not remove \(url.path): \(error)")
                failed = true
            }
        }
        out(failed ? "Removed what could be removed." : "Removed. The login-window agent will not start again.")
        return failed ? 1 : 0
    }

    // MARK: status

    private static func status(layout: LoginWindowInstall.Layout, out: (String) -> Void) -> Int32 {
        let s = LoginWindowInstall.status(layout) { label in
            (try? runTool("/bin/launchctl", ["print", "system/\(label)"])) == nil ? false : true
        }
        func yn(_ b: Bool) -> String { b ? "yes" : "NO" }
        out("Root-owned app copy:   \(yn(s.appCopy))")
        out("Agent plist:           \(yn(s.agentPlist))")
        out("Sync daemon plist:     \(yn(s.syncPlist))" + (s.syncLoaded == true ? " (loaded)" : s.syncPlist ? " (not loaded)" : ""))
        out("Mirrored user:         \(s.config?.user ?? "none")")
        out("Copied host key:       \(s.mirrorHostKey ? "yes" : "not readable or missing (needs sudo to be sure)")")
        switch s.mirrorMatchesUser {
        case .some(true): out("Copy matches user:     yes")
        case .some(false): out("Copy matches user:     NO (run: sudo clamshell loginwindow sync)")
        case .none: out("Copy matches user:     unknown without sudo")
        }
        out(s.installed ? (s.healthy ? "Installed." : "Installed, with a problem above.") : "Not installed.")
        return s.healthy ? 0 : 1
    }

    // MARK: sync (launchd, as root)

    private static func sync(layout: LoginWindowInstall.Layout, out: (String) -> Void) -> Int32 {
        guard geteuid() == 0 else { out("sync runs as root; it is started by launchd."); return 1 }
        guard let data = try? Data(contentsOf: layout.configFile),
              let config = try? JSONDecoder().decode(LoginWindowInstall.Config.self, from: data) else {
            out("No login-window install found.")
            return 1
        }
        do {
            let outcome = try LoginWindowInstall.sync(userDirectory: URL(fileURLWithPath: config.userStateDirectory),
                                                      userUID: config.uid, mirror: layout.stateDirectory)
            if outcome != .unchanged { clog("LOGINWINDOW-SYNC: \(outcome)") }
            return 0
        } catch {
            clog("LOGINWINDOW-SYNC: \(error)")
            return 1
        }
    }

    // MARK: helpers

    private static func makeRootDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
    }

    private static func writePlist(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
        try runTool("/usr/sbin/chown", ["root:wheel", url.path])
        try runTool("/bin/chmod", ["644", url.path])
        try runTool("/usr/bin/plutil", ["-lint", url.path])
    }

    @discardableResult
    private static func runTool(_ path: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw LoginWindowInstall.InstallError("\((path as NSString).lastPathComponent) failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return text
    }
}
