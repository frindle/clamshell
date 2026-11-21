import Foundation

/// "Can I reach this Mac with no screen and nobody there?" One list of
/// checks, shown in Diagnostics and by `clamshell remote-ready` (exit 1 when
/// any check fails). The checks are pure functions of `Inputs`, so they are
/// tested without a Mac; `Inputs.live()` reads the real machine.
enum RemoteReady {
    struct Inputs: Equatable {
        var nativeStreamingOn: Bool
        var nativeLockScreenOn: Bool
        /// The system accepted a request to wake the display.
        var displayWakeWorks: Bool
        /// The integrity key can be read without the Keychain asking.
        var keychainReadable: Bool
        var launchAgentInstalled: Bool
        var loginWindow: LoginWindowInstall.Status
    }

    struct Check: Equatable {
        let name: String
        let ok: Bool
        /// What to do, shown only when the check fails.
        let fix: String
    }

    static func checks(_ i: Inputs) -> [Check] {
        let lw = i.loginWindow
        let helperDetail = lw.installed
            ? (lw.healthy || lw.outdated ? "" : "run: sudo clamshell loginwindow sync (the copy of your host key or device list is stale)")
            : "run: sudo clamshell loginwindow install"
        return [
            Check(name: "Native streaming is on", ok: i.nativeStreamingOn,
                  fix: "turn on \"Native Streaming\" in the Clamshell menu"),
            Check(name: "Lock screen is carried by the stream", ok: i.nativeLockScreenOn,
                  fix: "run: defaults write com.frindle.clamshell nativeLockScreen -bool true"),
            Check(name: "Display wakes on request", ok: i.displayWakeWorks,
                  fix: "the system refused a wake request; check Energy settings and that the Mac is not in a forced sleep"),
            Check(name: "Keychain key readable without a prompt", ok: i.keychainReadable,
                  fix: "open Clamshell on the Mac and approve the Keychain prompt (Devices > Retry), or reinstall the update"),
            Check(name: "Clamshell restarts by itself (launch agent)", ok: i.launchAgentInstalled,
                  fix: "turn on \"Start at Login\" in the Clamshell menu"),
            Check(name: "Login-window helper installed and healthy", ok: lw.installed && lw.healthy,
                  fix: helperDetail.isEmpty ? "run: sudo clamshell loginwindow install" : helperDetail),
            Check(name: "Login-window helper is up to date", ok: lw.installed && !lw.outdated,
                  fix: "run: sudo clamshell loginwindow install"),
        ]
    }

    static func allPass(_ checks: [Check]) -> Bool { checks.allSatisfy { $0.ok } }

    static func render(_ checks: [Check]) -> String {
        var lines = checks.map { c in
            c.ok ? "ok    \(c.name)" : "FAIL  \(c.name)\n        -> \(c.fix)"
        }
        lines.append(allPass(checks) ? "Ready: this Mac can be reached with no screen attached."
                                     : "Not ready: fix the FAIL lines above.")
        return lines.joined(separator: "\n")
    }

    /// Reads the real machine.
    static func live(displayWake: () -> Bool = { SystemPowerAssertions().declareUserActivity("Clamshell remote-ready check") }) -> Inputs {
        let d = UserDefaults.standard
        let lw = LoginWindowInstall.status { label in
            ProcessRun.capture("/bin/launchctl", ["print", "system/\(label)"], timeout: 3)?.isEmpty == false
        }
        return Inputs(
            nativeStreamingOn: d.bool(forKey: "nativeStreaming"),
            nativeLockScreenOn: StreamMessage.nativeLockScreenEnabled(d),
            displayWakeWorks: displayWake(),
            keychainReadable: !HostAuth.shared.integrityKeyUnavailable,
            launchAgentInstalled: LaunchAgentSetup.isEnabled,
            loginWindow: lw)
    }

    static func runCommand() -> Int32 {
        let checks = checks(live())
        print(render(checks))
        return allPass(checks) ? 0 : 1
    }
}
