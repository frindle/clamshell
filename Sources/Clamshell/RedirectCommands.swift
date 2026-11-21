import Foundation

/// Whether this build carries Clamshell's own RFB server, and whether it
/// works. The redirect must never go in without one: it would send VNC
/// clients to a closed port. `selfTest` starts the server on a scratch
/// loopback port and drives a client through the handshake, ARD login and a
/// ZRLE framebuffer update.
enum RFBServerGate {
    static let present = true
    static func selfTest() -> Bool { RFBSelfTest.run(out: { _ in }) }
}

/// `clamshell redirect run | install | uninstall | status | check`.
/// run is started by launchd as root; install and uninstall need sudo; the
/// cutover script drives them. None of them touches SSH.
enum RedirectCommands {
    static let usage = """
        Usage: sudo clamshell redirect install
               sudo clamshell redirect uninstall
                    clamshell redirect status
        """

    static var plistURL: URL { URL(fileURLWithPath: "/Library/LaunchDaemons/\(RedirectPolicy.daemonLabel).plist") }

    static func run(_ args: [String], pf: PacketFilter = SystemPacketFilter(),
                    layout: LoginWindowInstall.Layout = .init(),
                    out: (String) -> Void = { print($0) }) -> Int32 {
        guard let command = args.first else { out(usage); return 64 }
        switch command {
        case "run":
            guard geteuid() == 0 else { out("run is started by launchd as root."); return 1 }
            RedirectDaemon.run(pf)
        case "install": return install(pf: pf, layout: layout, out: out)
        case "uninstall": return uninstall(pf: pf, out: out)
        case "status": return status(pf: pf, out: out)
        default: out(usage); return 64
        }
    }

    private static func install(pf: PacketFilter, layout: LoginWindowInstall.Layout, out: (String) -> Void) -> Int32 {
        guard geteuid() == 0 else { out("Run with sudo."); return 1 }
        guard RFBServerGate.present, RFBServerGate.selfTest() else {
            out("This build has no working Clamshell RFB server, so it will not redirect VNC clients to it. Nothing changed.")
            return 1
        }
        let helper = LoginWindowInstall.status(layout)
        guard helper.installed, !helper.outdated else {
            out("Install the login-window helper first (sudo clamshell loginwindow install); the redirect daemon runs from its root-owned app copy.")
            return 1
        }
        guard let resources = Bundle.main.resourceURL else { out("Run this from the installed app."); return 1 }
        do {
            let template = resources.appendingPathComponent("redirect-daemon/\(RedirectPolicy.daemonLabel).plist")
            let text = try LoginWindowInstall.render(
                template: try String(contentsOf: template, encoding: .utf8),
                values: ["APP_BINARY": layout.binary.path, "LOG": layout.log])
            try Data(text.utf8).write(to: plistURL, options: .atomic)
            try LoginWindowInstall.runProcess("/usr/sbin/chown", ["root:wheel", plistURL.path])
            try LoginWindowInstall.runProcess("/bin/chmod", ["644", plistURL.path])
            try LoginWindowInstall.runProcess("/usr/bin/plutil", ["-lint", plistURL.path])
            _ = try? LoginWindowInstall.runProcess("/bin/launchctl", ["bootout", "system/\(RedirectPolicy.daemonLabel)"])
            try LoginWindowInstall.runProcess("/bin/launchctl", ["bootstrap", "system", plistURL.path])
        } catch {
            out("Install failed: \(error)")
            return 1
        }
        out("Installed. Port \(RedirectPolicy.vncPort) now reaches Clamshell. Remove with: sudo clamshell redirect uninstall")
        return 0
    }

    private static func uninstall(pf: PacketFilter, out: (String) -> Void) -> Int32 {
        guard geteuid() == 0 else { out("Run with sudo."); return 1 }
        _ = try? LoginWindowInstall.runProcess("/bin/launchctl", ["bootout", "system/\(RedirectPolicy.daemonLabel)"])
        if FileManager.default.fileExists(atPath: plistURL.path) { try? FileManager.default.removeItem(at: plistURL) }
        // Take our rule out. The packet filter itself stays as it is.
        let flushed = pf.remove()
        out(flushed ? "Removed the redirect." : "Removed the daemon; could not flush the redirect rule (it goes at the next reboot).")
        return flushed ? 0 : 1
    }

    private static func status(pf: PacketFilter, out: (String) -> Void) -> Int32 {
        let rules = pf.loadedRules()
        let there = rules.map(RedirectPolicy.hasRedirect) ?? false
        out("Redirect daemon plist: \(FileManager.default.fileExists(atPath: plistURL.path) ? "yes" : "no")")
        out("Redirect rule loaded:  \(there ? "yes" : (rules == nil ? "unknown without sudo" : "no"))")
        out("Packet filter on:      \(pf.isEnabled() ? "yes" : "no or unknown without sudo")")
        out("Stock pf.conf evaluates com.apple/* redirects: \(pf.pfConf().map { RedirectPolicy.pfConfEvaluatesAnchor($0) ? "yes" : "NO" } ?? "unknown")")
        out("RFB server in this build: \(RFBServerGate.present ? "yes" : "no")")
        return there ? 0 : 1
    }
}
