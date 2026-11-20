import Foundation
import SystemConfiguration
import CryptoKit

/// `Clamshell loginwindow-agent`: serve the stream at the login window, then
/// get out of the way.
///
/// Installed by `sudo clamshell loginwindow install` (see `LoginWindowInstall`):
/// launchd starts it in the login-window session only, as root, from a
/// root-owned copy of the app. It is headless: no NSApplication, no menu bar,
/// no windows.
///
/// It is the same web server and stream servers the menu-bar app runs, on the
/// same ports, so the tunnel and the web client need no changes. The new
/// logic is when to serve and whose identity to serve with:
/// - Serve only while nobody is logged in at the console.
/// - Use the host key and trusted-device list the installer mirrored into the
///   agent's own root-only state folder (never a fresh key: clients would
///   report a changed identity). Without a mirrored key, do not serve.
/// - Always require device approval, whatever the user's setting says.
/// - Accept a saved login from a trusted client (LOGIN_CREDENTIALS) and type
///   it into the login window.
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

        // The agent's state folder is CLAMSHELL_STATE_DIR (set by its plist).
        // The mirrored host key must be there already: never invent one.
        let directory = HostState.directory
        guard let reason = hostStateProblem(in: directory) else {
            let auth = HostAuth(directory: directory, requireApproval: true)
            let web = WebServer()
            web.start()
            // The login window is this agent's whole job, so it never tells the
            // client the host is "locked" (which makes the client fall back to VNC).
            let fleet = StreamFleet(basePort: streamDefaultPort, reportLockState: false, auth: auth)
            fleet.acceptsLoginCredentials = true
            fleet.rebuild()
            return serve(web: web, fleet: fleet)
        }
        clog("LOGINWINDOW-AGENT: \(reason) — not serving")
        print("loginwindow-agent: \(reason)")
        return 1
    }

    /// Why the agent cannot serve with this state folder, or nil. The folder
    /// must exist, be this user's and private, and hold a valid host key.
    static func hostStateProblem(in directory: URL) -> String? {
        var st = stat()
        guard lstat(directory.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            return "no state folder at \(directory.path); run: sudo clamshell loginwindow install"
        }
        guard st.st_uid == geteuid(), st.st_mode & 0o077 == 0 else {
            return "the state folder is not private to this user"
        }
        let key = directory.appendingPathComponent(HostIdentity.fileName)
        guard let raw = try? SecureFile.read(key, maxBytes: 64),
              (try? P256.Signing.PrivateKey(rawRepresentation: raw)) != nil else {
            return "the user's host key has not been copied yet; run: sudo clamshell loginwindow sync"
        }
        return nil
    }

    private static func serve(web: WebServer, fleet: StreamFleet) -> Int32 {
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
