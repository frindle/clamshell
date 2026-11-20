import AppKit
import ServiceManagement

/// Pre-flight check for "will this Mac come back and be remotely reachable
/// after a reboot while I'm away".
///
/// The chain with FileVault on (and Screen Sharing off):
///
/// * Planned restart: Clamshell's "Restart" runs `fdesetup authrestart`, which skips
///   the pre-boot disk unlock once. Needs authrestart support.
/// * Power cut or crash: `pmset autorestart 1` powers the Mac on by itself, and Remote Login
///   (SSH) lets macOS 26 and later unlock the disk over the network before it boots. The
///   iPad and Windows Clamshell apps offer that as "Unlock disk" (direct SSH to port 22).
///   So the outage path needs autorestart and SSH. FileVault being on is fine and expected.
///
/// All checks are read-only: these settings are privileged or physical decisions
/// Clamshell does not change silently. The summary prints the one command to fix
/// autorestart.
enum RebootReadiness {
    /// The one thing a user can fix in a single command (needs admin).
    static let autorestartCommand = "sudo pmset -a autorestart 1"

    struct Report {
        let autorestartOn: Bool
        let fileVaultOn: Bool
        let sshOn: Bool
        let loginItemOn: Bool
        let authRestartSupported: Bool
    }

    static func check() -> Report {
        let pmset = shell("/usr/bin/pmset", ["-g"])
        return Report(
            autorestartOn: pmset.range(of: #"autorestart\s+1"#, options: .regularExpression) != nil,
            fileVaultOn: shell("/usr/bin/fdesetup", ["status"]).contains("FileVault is On"),
            sshOn: sshListening(),
            loginItemOn: SMAppService.mainApp.status == .enabled,
            authRestartSupported: shell("/usr/bin/fdesetup", ["supportsauthrestart"]).contains("true")
        )
    }

    /// Go/no-go for the two real scenarios. Pure, so it is tested.
    static func verdicts(_ r: Report) -> (outage: Bool, planned: Bool) {
        // Outage: it must power on by itself, and SSH must be on for the pre-boot unlock to be
        // possible. With FileVault off no unlock is needed.
        let outage = r.autorestartOn && (r.fileVaultOn ? r.sshOn : true)
        // Planned: authrestart works, or FileVault is off and a plain restart is enough.
        let planned = r.authRestartSupported || !r.fileVaultOn
        return (outage, planned)
    }

    static func summary(_ r: Report) -> String {
        func mark(_ ok: Bool) -> String { ok ? "✅" : "❌" }
        let v = verdicts(r)
        return """
        Reboot readiness

        \(mark(r.autorestartOn))  Start up after power failure (pmset autorestart)
        \(mark(r.sshOn))  Remote Login (SSH) on: macOS can unlock the disk over SSH before it boots
        \(mark(r.authRestartSupported))  Authenticated restart supported (planned restarts skip the disk unlock)
        \(mark(r.loginItemOn))  Clamshell "Start at Login" enabled
        FileVault is \(r.fileVaultOn ? "ON (fine: Unlock disk in the iPad or Windows app unlocks it over SSH)" : "OFF")

        Unattended recovery verdict:
        • Power outage while away: \(v.outage ? "SHOULD WORK" : "WILL NOT WORK unattended")
        • Planned restart (Clamshell Restart, macOS updates): \(v.planned ? "SHOULD WORK" : "WILL NOT WORK unattended")

        \(!r.autorestartOn ? "Fix autorestart (needs admin):\n\(autorestartCommand)\n\n" : "")\
        \(r.fileVaultOn && !r.sshOn ? "Turn on Remote Login (System Settings > General > Sharing): without it the disk cannot be unlocked over the network.\n\n" : "")\
        \(r.fileVaultOn ? "After a power cut a FileVault Mac waits at the disk unlock until someone unlocks it. Use \"Unlock disk\" in the iPad or Windows app.\n\n" : "")\
        See the README "Surviving an unattended reboot" section.
        """
    }

    private static func sshListening() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        task.arguments = ["-z", "-w", "1", "127.0.0.1", "22"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
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
