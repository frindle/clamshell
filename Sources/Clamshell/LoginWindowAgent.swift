import Foundation
import SystemConfiguration

/// `Clamshell loginwindow-agent`: serve the stream at the login window, then
/// get out of the way.
///
/// EXPERIMENTAL AND NOT INSTALLED. Nothing in the app registers, installs or
/// starts this; it only runs if someone loads the plist in
/// `scripts/loginwindow-agent/` by hand. It exists so the "Clamshell at the
/// login window" plan can be tried once the `loginwindow-probe` results are in.
///
/// It is the same web server and stream servers the menu-bar app runs, on the
/// same ports, so the tunnel and the web client need no changes. The only new
/// logic is when to serve:
/// - Serve only while nobody is logged in at the console.
/// - The moment someone logs in, exit. Exiting closes every listening socket
///   at once, so the user's own Clamshell (a login item) can bind the same
///   ports without racing a slow listener shutdown.
/// - Started in a normal logged-in session, it exits straight away and never
///   opens a port.
enum LoginWindowAgent {
    /// Who is at the console, as the agent cares about it.
    enum Console: Equatable {
        case loginWindow
        case user(String)
    }

    /// Maps the SystemConfiguration console-user name to a state. No user,
    /// an empty name and the literal "loginwindow" all mean the login window.
    static func console(forUserName name: String?) -> Console {
        guard let name, !name.isEmpty, name != "loginwindow" else { return .loginWindow }
        return .user(name)
    }

    static func shouldServe(_ console: Console) -> Bool { console == .loginWindow }

    static func currentConsole() -> Console {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return console(forUserName: SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String?)
    }

    /// Never returns while serving; returns an exit code otherwise.
    static func run() -> Int32 {
        let start = currentConsole()
        guard shouldServe(start) else {
            print("loginwindow-agent: a user is logged in (\(start)) — nothing to do")
            return 0
        }
        clog("LOGINWINDOW-AGENT: nobody logged in — serving (uid \(getuid()))")

        let web = WebServer()
        web.start()
        // The login window is this agent's whole job, so it never tells the
        // client the host is "locked" (which makes the client fall back to VNC).
        let fleet = StreamFleet(basePort: streamDefaultPort, reportLockState: false)
        fleet.rebuild()

        let yield: (String) -> Void = { reason in
            clog("LOGINWINDOW-AGENT: \(reason) — exiting so the user's Clamshell can take the ports")
            exit(0)
        }

        // Event-driven: the console-user key changes at login.
        var context = SCDynamicStoreContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        let callback: SCDynamicStoreCallBack = { _, _, _ in
            let now = LoginWindowAgent.currentConsole()
            if !LoginWindowAgent.shouldServe(now) {
                clog("LOGINWINDOW-AGENT: console user changed (\(now)) — exiting so the user's Clamshell can take the ports")
                exit(0)
            }
        }
        if let store = SCDynamicStoreCreate(nil, "com.frindle.clamshell.loginwindow-agent" as CFString, callback, &context) {
            let key = SCDynamicStoreKeyCreateConsoleUser(nil)
            SCDynamicStoreSetNotificationKeys(store, [key] as CFArray, nil)
            if let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            }
        }
        // Belt and braces in case the notification is missed.
        let timer = Timer(timeInterval: 2, repeats: true) { _ in
            let now = currentConsole()
            if !shouldServe(now) { yield("console user is now \(now)") }
        }
        RunLoop.main.add(timer, forMode: .default)

        withExtendedLifetime((web, fleet)) { RunLoop.main.run() }
        return 0
    }
}
