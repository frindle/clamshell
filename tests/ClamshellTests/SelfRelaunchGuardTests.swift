import XCTest
@testable import Clamshell

final class SelfRelaunchGuardTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "clamshell.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testFirstRelaunchIsAllowedAndRecorded() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(SelfRelaunchGuard.shouldAttemptRelaunch(defaults: defaults, now: now))
        XCTAssertEqual(defaults.object(forKey: SelfRelaunchGuard.lastRelaunchKey) as? Date, now)
    }

    func testSecondRelaunchInsideCooldownIsBlocked() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(SelfRelaunchGuard.shouldAttemptRelaunch(defaults: defaults, now: now))
        let soon = now.addingTimeInterval(SelfRelaunchGuard.cooldown - 1)
        XCTAssertFalse(SelfRelaunchGuard.shouldAttemptRelaunch(defaults: defaults, now: soon))
        // A blocked attempt must not push the cooldown window out.
        XCTAssertEqual(defaults.object(forKey: SelfRelaunchGuard.lastRelaunchKey) as? Date, now)
    }

    func testRelaunchAfterCooldownIsAllowed() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(SelfRelaunchGuard.shouldAttemptRelaunch(defaults: defaults, now: now))
        let later = now.addingTimeInterval(SelfRelaunchGuard.cooldown)
        XCTAssertTrue(SelfRelaunchGuard.shouldAttemptRelaunch(defaults: defaults, now: later))
        XCTAssertEqual(defaults.object(forKey: SelfRelaunchGuard.lastRelaunchKey) as? Date, later)
    }
}
