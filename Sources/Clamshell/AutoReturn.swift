import Foundation
import AppKit

/// Clamshell is the only way into a Mac with no screen, so after a crash,
/// a quit or a reboot it has to come back by itself. That is the per-user
/// launch agent (`LaunchAgentSetup`). It is installed by default; turning
/// "Start at Login" off in the menu is the opt-out, and it sticks.
enum AutoReturnPolicy {
    static let optOutKey = "autoReturnOptOut"

    static func isOptedOut(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: optOutKey) }
    static func setOptedOut(_ value: Bool, _ defaults: UserDefaults = .standard) { defaults.set(value, forKey: optOutKey) }

    /// Install the agent now? Never for a bare binary (no bundle to point at),
    /// never when the user opted out, never when it is already there.
    static func shouldInstall(optedOut: Bool, alreadyEnabled: Bool, isInstalledApp: Bool) -> Bool {
        isInstalledApp && !optedOut && !alreadyEnabled
    }

    /// Run once per launch, a few seconds after start.
    static func installIfNeeded() {
        let go = shouldInstall(optedOut: isOptedOut(), alreadyEnabled: LaunchAgentSetup.isEnabled,
                               isInstalledApp: Bundle.main.bundleIdentifier != nil
                                   && Bundle.main.bundlePath.hasSuffix(".app"))
        guard go else { return }
        guard LaunchAgentSetup.enable() != nil else {
            clog("auto-return: could not install the launch agent; Clamshell will not restart by itself")
            return
        }
        clog("auto-return: installed the launch agent (turn \"Start at Login\" off to opt out)")
        LaunchAgentSetup.handOff()
    }
}

/// One Clamshell per user. A second copy would fight over the same ports, so
/// it waits for the old one to finish (the updater starts the new build while
/// the old one is still quitting) and gives up only if the old one stays.
enum SingleInstancePolicy {
    enum Step: Equatable { case proceed, wait, yield }
    static let patience: TimeInterval = 20

    static func decide(others: [Int32], elapsed: TimeInterval) -> Step {
        if others.isEmpty { return .proceed }
        return elapsed < patience ? .wait : .yield
    }
}

enum SingleInstance {
    static func others() -> [Int32] {
        guard let id = Bundle.main.bundleIdentifier else { return [] }
        let me = getpid()
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != me && !$0.isTerminated }
            .map { $0.processIdentifier }
    }

    /// Blocks until no other copy is running. Exits quietly when one stays.
    static func waitForOthersOrExit() {
        let start = Date()
        var logged = false
        while true {
            let running = others()
            switch SingleInstancePolicy.decide(others: running, elapsed: Date().timeIntervalSince(start)) {
            case .proceed:
                return
            case .wait:
                if !logged {
                    logged = true
                    clog("single-instance: another Clamshell (\(running.map(String.init).joined(separator: ", "))) is still running; waiting for it to finish")
                }
                Thread.sleep(forTimeInterval: 0.25)
            case .yield:
                clog("single-instance: another Clamshell is still running after \(Int(SingleInstancePolicy.patience)) s; this copy is exiting")
                exit(0)
            }
        }
    }
}
