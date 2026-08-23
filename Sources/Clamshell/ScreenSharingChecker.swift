import Foundation

/// Checks whether native macOS Screen Sharing is enabled.
///
/// WHY NOT `launchctl print system/com.apple.screensharing`
/// --------------------------------------------------------
/// That was the first implementation and it is wrong in the ordinary case.
/// screensharingd is an ON-DEMAND job (`type = Submitted`): launchd holds the
/// listening socket and only spawns the daemon while a client is actually
/// connected. With Screen Sharing switched ON in System Settings and nobody
/// connected, that command reports:
///
///     active count = 0
///     state = not running
///     runs = 16            <- it has run 16 times and exited each time
///
/// So a `state = running` test returns false for an enabled-but-idle service,
/// which is its normal resting state. Verified 2026-08-23 on this Mac with
/// Screen Sharing enabled and port 5900 listening on both tcp4 and tcp6.
/// Shipping that check would have told the user "Screen Sharing is disabled"
/// and sent them to System Settings to enable something already enabled.
///
/// The authoritative question is whether the service is DISABLED, which
/// `launchctl print-disabled system` answers directly and without root.
struct ScreenSharingChecker {

    /// True if Screen Sharing is enabled. Conservative: on any doubt it returns
    /// true, so the caller falls back to a generic failure message rather than
    /// confidently telling the user to change a setting that is already correct.
    static func isScreenSharingEnabled() -> Bool {
        if let disabled = isDisabledAccordingToLaunchd() {
            return !disabled
        }
        // launchctl unavailable or unparseable -- fall back to the observable
        // fact: something is listening on the Screen Sharing port.
        return isListeningOnScreenSharingPort() ?? true
    }

    /// nil when the answer could not be determined.
    private static func isDisabledAccordingToLaunchd() -> Bool? {
        guard let out = run("/bin/launchctl", ["print-disabled", "system"]) else { return nil }
        // Lines look like:  "com.apple.screensharing" => enabled
        for line in out.split(separator: "\n") where line.contains("com.apple.screensharing") {
            if line.contains("=> disabled") { return true }
            if line.contains("=> enabled") { return false }
        }
        // Not listed at all means no override has ever been written, which for
        // this service means it is in its default state: disabled.
        return true
    }

    /// nil when the answer could not be determined.
    private static func isListeningOnScreenSharingPort() -> Bool? {
        guard let out = run("/usr/sbin/netstat", ["-an"]) else { return nil }
        return out.split(separator: "\n").contains { line in
            line.contains(".5900 ") && line.contains("LISTEN")
        }
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()   // separate, so stderr cannot corrupt stdout

        do {
            try task.run()
            // Read before waiting: a full pipe buffer would otherwise deadlock
            // the child against our wait.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            clog("ScreenSharingChecker: \(path) failed: \(error)")
            return nil
        }
    }
}
