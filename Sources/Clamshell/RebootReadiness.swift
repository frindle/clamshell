import AppKit
import ServiceManagement

/// Pre-flight check for "will this Mac come back and be remotely reachable
/// after an unattended reboot / power outage while I'm away".
///
/// All checks are read-only — the settings that gate unattended recovery
/// (autorestart, FileVault, Screen Sharing, auto-login) are privileged/physical
/// decisions Clamshell can't and shouldn't silently change. This just surfaces
/// them so you can fix them before you leave, and prints the one command you
/// can copy.
///
/// See the "Surviving an unattended reboot" section of the README for the full
/// power-outage-vs-update-reboot / FileVault tradeoff.
enum RebootReadiness {
    /// The one thing a user can fix in a single command (needs admin).
    static let autorestartCommand = "sudo pmset -a autorestart 1"

    struct Report {
        let autorestartOn: Bool
        let fileVaultOn: Bool
        let screenSharing: Bool?   // nil = couldn't determine
        let loginItemOn: Bool
        let authRestartSupported: Bool
    }

    static func check() -> Report {
        Report(
            autorestartOn: shell("/usr/bin/pmset", ["-g"]).contains("autorestart") &&
                shell("/usr/bin/pmset", ["-g"]).range(of: #"autorestart\s+1"#, options: .regularExpression) != nil,
            fileVaultOn: shell("/usr/bin/fdesetup", ["status"]).contains("FileVault is On"),
            screenSharing: screenSharingEnabled(),
            loginItemOn: SMAppService.mainApp.status == .enabled,
            authRestartSupported: shell("/usr/bin/fdesetup", ["supportsauthrestart"]).contains("true")
        )
    }

    /// Reads the launchd disabled-override for Apple's Screen Sharing daemon.
    /// "not disabled" is our proxy for "Screen Sharing is on in System Settings".
    private static func screenSharingEnabled() -> Bool? {
        let out = shell("/bin/launchctl", ["print-disabled", "system"])
        guard let line = out.split(separator: "\n").first(where: { $0.contains("com.apple.screensharing") }) else {
            return nil
        }
        if line.contains("=> enabled") { return true }
        if line.contains("=> disabled") { return false }
        return nil
    }

    /// Human-readable multi-line summary plus a plain go/no-go for each of the
    /// two real scenarios (power outage vs. update-triggered reboot).
    static func summary(_ r: Report) -> String {
        func mark(_ ok: Bool) -> String { ok ? "✅" : "❌" }
        let ss = r.screenSharing.map { mark($0) } ?? "❓"

        // Power outage: needs autorestart, and FileVault must be OFF (pre-boot
        // unlock has no network — authrestart's stored key doesn't survive a
        // full power loss). Also needs a way in once it reaches the desktop.
        let outageOK = r.autorestartOn && !r.fileVaultOn && (r.screenSharing ?? true)
        // Update reboot: macOS uses authenticated restart to pass FileVault
        // back to the login window unattended, so FileVault-on is OK here.
        let updateOK = (r.screenSharing ?? true) && (r.authRestartSupported || !r.fileVaultOn)

        return """
        Reboot readiness

        \(mark(r.autorestartOn))  Start up after power failure (pmset autorestart)
        \(mark(!r.fileVaultOn))  FileVault OFF  (currently \(r.fileVaultOn ? "ON" : "OFF"))
        \(ss)  Apple Screen Sharing enabled
        \(mark(r.loginItemOn))  Clamshell "Start at Login" enabled
        \(mark(r.authRestartSupported))  Authenticated restart supported (for update reboots)

        Unattended recovery verdict:
        • Power outage while away: \(outageOK ? "SHOULD WORK" : "WILL NOT WORK unattended")
        • macOS-update reboot: \(updateOK ? "SHOULD WORK" : "WILL NOT WORK unattended")

        \(!r.autorestartOn ? "Fix autorestart (needs admin):\n\(autorestartCommand)\n\n" : "")\
        \(r.fileVaultOn ? "FileVault is ON: a Mac powered on after a full outage stops at the pre-boot unlock screen with no network — nobody can remote in until the FileVault password is typed at the machine. Update-triggered reboots still recover (macOS stores an authenticated-restart key). Turn FileVault OFF to make power-outage recovery possible — a security tradeoff only you can make.\n\n" : "")\
        See the README "Surviving an unattended reboot" section for the full tradeoff.
        """
    }

    private static func shell(_ path: String, _ args: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
