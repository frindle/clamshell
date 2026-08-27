import Foundation

/// Exercises SelfRelaunchGuard.shouldAttemptRelaunch — the crash-loop guard
/// that decides whether the self-heal path (VirtualDisplayController +
/// SelfHeal.swift) is allowed to relaunch the app.
///
/// This is the ONLY piece of the self-heal feature covered here. Explicitly
/// NOT covered, and not coverable by this project's framework-free
/// executable-test setup:
///   - PhantomDisplayDetector actually seeing a real WindowServer phantom
///     (needs a live orphaned virtual display on real hardware).
///   - SelfRelaunchGuard.performRelaunch actually spawning a new instance
///     and terminating this one (would kill the test process itself).
/// Those need a real repro on real hardware, per the task instructions.
enum SelfHealGuardSelfTest {
    static func run() -> Int32 {
        var passed = true
        let suiteName = "com.frindle.clamshell.selfheal-guard-selftest"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            print("FAILED: could not create isolated UserDefaults suite")
            return 1
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let t0 = Date()

        // First attempt ever (no prior timestamp recorded): must be allowed.
        if SelfRelaunchGuard.shouldAttemptRelaunch(defaults: defaults, now: t0) {
            print("PASS: first relaunch attempt (no prior record) is allowed")
        } else {
            print("FAILED: first relaunch attempt was blocked")
            passed = false
        }

        // Immediately after: must be blocked (still well inside cooldown).
        let t1 = t0.addingTimeInterval(1)
        if SelfRelaunchGuard.shouldAttemptRelaunch(defaults: defaults, now: t1) {
            print("FAILED: second relaunch attempt 1s later was allowed (crash-loop guard did not block it)")
            passed = false
        } else {
            print("PASS: second relaunch attempt 1s later is blocked")
        }

        // Partway through the cooldown: still blocked.
        let tMid = t0.addingTimeInterval(SelfRelaunchGuard.cooldown - 1)
        if SelfRelaunchGuard.shouldAttemptRelaunch(defaults: defaults, now: tMid) {
            print("FAILED: relaunch attempt 1s before cooldown expiry was allowed")
            passed = false
        } else {
            print("PASS: relaunch attempt 1s before cooldown expiry is still blocked")
        }

        // Blocked attempts above must NOT have reset the recorded timestamp —
        // confirm the cooldown is measured from the original relaunch, not
        // from the most recent blocked attempt.
        let tJustPastOriginalCooldown = t0.addingTimeInterval(SelfRelaunchGuard.cooldown + 1)
        if SelfRelaunchGuard.shouldAttemptRelaunch(defaults: defaults, now: tJustPastOriginalCooldown) {
            print("PASS: relaunch attempt just past the ORIGINAL cooldown window is allowed again (blocked attempts didn't extend the cooldown)")
        } else {
            print("FAILED: relaunch attempt past the original cooldown was still blocked — a blocked attempt incorrectly reset the timer")
            passed = false
        }

        // That successful attempt above recorded a NEW timestamp
        // (tJustPastOriginalCooldown); immediately after, must be blocked
        // again relative to the new record.
        let t2 = tJustPastOriginalCooldown.addingTimeInterval(1)
        if SelfRelaunchGuard.shouldAttemptRelaunch(defaults: defaults, now: t2) {
            print("FAILED: relaunch attempt 1s after the second successful relaunch was allowed")
            passed = false
        } else {
            print("PASS: guard re-armed after the second successful relaunch, blocking the next attempt")
        }

        print(passed ? "PASS: SelfRelaunchGuard crash-loop guard behaves correctly" : "FAILED: see above")
        return passed ? 0 : 1
    }
}
