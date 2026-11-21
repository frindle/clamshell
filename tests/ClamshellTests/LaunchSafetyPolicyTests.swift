import XCTest
@testable import Clamshell

final class LaunchSafetyPolicyTests: XCTestCase {
    // MARK: asking for the key

    func testAsksOnlyWhenUnreadableUnlockedAndIdle() {
        XCTAssertTrue(IntegrityKeyPolicy.shouldAsk(keyUnreadable: true, screenLocked: false, askInFlight: false))
        XCTAssertFalse(IntegrityKeyPolicy.shouldAsk(keyUnreadable: true, screenLocked: true, askInFlight: false))
        XCTAssertFalse(IntegrityKeyPolicy.shouldAsk(keyUnreadable: true, screenLocked: false, askInFlight: true))
        XCTAssertFalse(IntegrityKeyPolicy.shouldAsk(keyUnreadable: false, screenLocked: false, askInFlight: false))
    }

    // MARK: bounded quiet read

    func testQuickReadReturnsItsValue() throws {
        let r = BoundedRead()
        XCTAssertEqual(try r.run(timeout: 2) { Data([1, 2]) }, Data([1, 2]))
        XCTAssertNil(try r.run(timeout: 2) { nil })
    }

    func testReadErrorIsPassedOn() {
        struct Boom: Error {}
        let r = BoundedRead()
        XCTAssertThrowsError(try r.run(timeout: 2) { throw Boom() })
    }

    func testStuckReadTimesOutAndLaterReadsFailAtOnce() throws {
        let r = BoundedRead()
        let release = DispatchSemaphore(value: 0)
        let t0 = Date()
        XCTAssertThrowsError(try r.run(timeout: 0.2) { release.wait(); return nil }) { e in
            XCTAssertEqual((e as? BoundedRead.TimedOut)?.waited, true)
        }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2)
        // Still stuck: the next read does not wait at all.
        let t1 = Date()
        XCTAssertThrowsError(try r.run(timeout: 5) { Data() }) { e in
            XCTAssertEqual((e as? BoundedRead.TimedOut)?.waited, false)
        }
        XCTAssertLessThan(Date().timeIntervalSince(t1), 1)
        // Once the dialog is answered, reading works again.
        release.signal()
        let deadline = Date().addingTimeInterval(5)
        var value: Data?
        while Date() < deadline {
            if let v = try? r.run(timeout: 1, { Data([9]) }) { value = v; break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(value, Data([9]))
    }

    // MARK: no reinstall loop

    private func record(to: String, result: String) -> SafeUpdate.Record {
        SafeUpdate.Record(at: Date(), from: "0.9.17", to: to, result: result, reason: nil)
    }

    func testSkipsVersionThatWasRolledBack() {
        let r = record(to: "0.9.20", result: "rolled-back")
        XCTAssertTrue(SafeUpdate.shouldSkipAutoInstall(tag: "v0.9.20", lastRecord: r))
        XCTAssertTrue(SafeUpdate.shouldSkipAutoInstall(tag: "0.9.20", lastRecord: r))
    }

    func testDoesNotSkipOtherVersionsOrResults() {
        let r = record(to: "0.9.20", result: "rolled-back")
        XCTAssertFalse(SafeUpdate.shouldSkipAutoInstall(tag: "v0.9.21", lastRecord: r))
        XCTAssertFalse(SafeUpdate.shouldSkipAutoInstall(tag: "v0.9.20", lastRecord: record(to: "0.9.20", result: "ok")))
        XCTAssertFalse(SafeUpdate.shouldSkipAutoInstall(tag: "v0.9.20", lastRecord: record(to: "0.9.20", result: "manual-rollback")))
        XCTAssertFalse(SafeUpdate.shouldSkipAutoInstall(tag: "v0.9.20", lastRecord: nil))
    }

    // MARK: rollback restart

    func testEndsWhenNothingIsLeft() {
        XCTAssertEqual(RollbackRestart.nextStep(alive: [], elapsed: 0), .done)
    }

    func testWaitsThenKills() {
        XCTAssertEqual(RollbackRestart.nextStep(alive: [10], elapsed: 4.9), .wait)
        XCTAssertEqual(RollbackRestart.nextStep(alive: [10, 11], elapsed: 5), .kill([10, 11]))
    }

    func testRelaunchNeedsANewProcess() {
        XCTAssertFalse(RollbackRestart.relaunched(before: [10], now: []))
        XCTAssertFalse(RollbackRestart.relaunched(before: [10], now: [10]))
        XCTAssertFalse(RollbackRestart.relaunched(before: [10], now: [10, 12]))
        XCTAssertTrue(RollbackRestart.relaunched(before: [10], now: [12]))
        XCTAssertTrue(RollbackRestart.relaunched(before: [], now: [12]))
    }
}
