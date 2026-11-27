import XCTest
@testable import Clamshell

private final class FakePowerAssertions: PowerAssertionBackend {
    var nextID: UInt32 = 100
    var live: Set<UInt32> = []
    var createCalls = 0
    var releaseCalls = 0
    var failCreate = false

    func createDisplaySleepAssertion(reason: String) -> UInt32? {
        createCalls += 1
        if failCreate { return nil }
        nextID += 1
        live.insert(nextID)
        return nextID
    }

    func declareUserActivity(reason: String, reusing id: UInt32) -> UInt32? {
        if id != 0 { return id }
        nextID += 1
        live.insert(nextID)
        return nextID
    }

    func release(_ id: UInt32) {
        releaseCalls += 1
        live.remove(id)
    }
}

final class DisplayAwakeGuardTests: XCTestCase {
    func testHoldIsCreatedOnceAndReleasedOnce() {
        let fake = FakePowerAssertions()
        let guardian = DisplayAwakeGuard(backend: fake)
        XCTAssertTrue(guardian.hold(reason: "t"))
        XCTAssertTrue(guardian.hold(reason: "t"))
        XCTAssertEqual(fake.createCalls, 1)
        XCTAssertEqual(fake.live.count, 1)
        XCTAssertTrue(guardian.releaseHold())
        XCTAssertTrue(fake.live.isEmpty)
        XCTAssertFalse(guardian.isHolding)
    }

    func testReleasingTwiceIsHarmless() {
        let fake = FakePowerAssertions()
        let guardian = DisplayAwakeGuard(backend: fake)
        guardian.hold(reason: "t")
        guardian.wake(reason: "t")
        XCTAssertTrue(guardian.releaseAll())
        XCTAssertFalse(guardian.releaseAll())
        XCTAssertEqual(fake.releaseCalls, 2)
        XCTAssertTrue(fake.live.isEmpty)
    }

    func testReleaseWithNothingHeldDoesNothing() {
        let fake = FakePowerAssertions()
        let guardian = DisplayAwakeGuard(backend: fake)
        XCTAssertFalse(guardian.releaseAll())
        XCTAssertEqual(fake.releaseCalls, 0)
    }

    func testFailedCreateLeavesNothingToReleaseAndCanRetry() {
        let fake = FakePowerAssertions()
        fake.failCreate = true
        let guardian = DisplayAwakeGuard(backend: fake)
        XCTAssertFalse(guardian.hold(reason: "t"))
        XCTAssertFalse(guardian.isHolding)
        XCTAssertFalse(guardian.releaseHold())
        fake.failCreate = false
        XCTAssertTrue(guardian.hold(reason: "t"))
        XCTAssertEqual(fake.live.count, 1)
    }

    func testRepeatedWakeReusesOneAssertion() {
        let fake = FakePowerAssertions()
        let guardian = DisplayAwakeGuard(backend: fake)
        guardian.wake(reason: "t")
        guardian.wake(reason: "t")
        XCTAssertEqual(fake.live.count, 1)
        XCTAssertTrue(guardian.releaseWake())
        XCTAssertFalse(guardian.isWakeDeclared)
        XCTAssertTrue(fake.live.isEmpty)
    }

    func testReleaseAllDropsHoldAndWakeTogether() {
        let fake = FakePowerAssertions()
        let guardian = DisplayAwakeGuard(backend: fake)
        guardian.hold(reason: "t")
        guardian.wake(reason: "t")
        XCTAssertEqual(fake.live.count, 2)
        XCTAssertTrue(guardian.releaseAll())
        XCTAssertTrue(fake.live.isEmpty)
        XCTAssertFalse(guardian.isHolding)
        XCTAssertFalse(guardian.isWakeDeclared)
    }

    func testOverlappingSessionStartKeepsASingleHold() {
        let fake = FakePowerAssertions()
        let guardian = DisplayAwakeGuard(backend: fake)
        guardian.hold(reason: "first")
        guardian.hold(reason: "second")
        guardian.releaseAll()
        XCTAssertTrue(fake.live.isEmpty)
        XCTAssertEqual(fake.createCalls, 1)
    }

    // MARK: - SessionComfort

    func testSessionStartHoldsDisplayByDefault() {
        let fake = FakePowerAssertions()
        let comfort = SessionComfort(awake: DisplayAwakeGuard(backend: fake))
        comfort.sessionDidStart()
        XCTAssertEqual(fake.createCalls, 1)
        comfort.sessionDidEnd()
        XCTAssertTrue(fake.live.isEmpty)
    }

    func testExternalCollapseTakesNoHoldButKeepsWake() {
        let fake = FakePowerAssertions()
        let comfort = SessionComfort(awake: DisplayAwakeGuard(backend: fake))
        comfort.holdDisplayAwake = false
        comfort.wakeDisplayForCollapse()
        comfort.sessionDidStart()
        XCTAssertEqual(fake.createCalls, 0)
        XCTAssertEqual(fake.live.count, 1) // the wake declaration
        comfort.displayWakeDone()
        XCTAssertTrue(fake.live.isEmpty)
    }

    func testStaleWakeReleaseOnlyAffectsTheWake() {
        // A stale retry chain is stopped by the coordinator's generation
        // check; this pins that a wake release never drops the session hold.
        let fake = FakePowerAssertions()
        let comfort = SessionComfort(awake: DisplayAwakeGuard(backend: fake))
        comfort.sessionDidStart()
        comfort.wakeDisplayForCollapse()
        comfort.displayWakeDone()
        XCTAssertEqual(fake.live.count, 1)
        comfort.releasePowerAssertions()
        XCTAssertTrue(fake.live.isEmpty)
    }
}
