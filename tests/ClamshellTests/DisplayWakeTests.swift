import XCTest
@testable import Clamshell

final class DisplayWakeTests: XCTestCase {
    private final class FakePower: PowerAssertions {
        var activity: [String] = []
        var holds: [UInt32] = []
        var released: [UInt32] = []
        var next: UInt32 = 1
        var accept = true
        func declareUserActivity(_ reason: String) -> Bool { activity.append(reason); return accept }
        func holdDisplayAwake(_ reason: String) -> UInt32? { defer { next += 1 }; holds.append(next); return next }
        func release(_ id: UInt32) { released.append(id) }
    }

    private final class Token {}

    func testConnectWakesAndHoldsUntilTheLastDeviceLeaves() {
        let power = FakePower()
        let wake = DisplayWake(power: power)
        let a = Token(), b = Token()
        wake.connected(a)
        XCTAssertEqual(power.activity.count, 1, "a trusted connect declares user activity")
        XCTAssertTrue(wake.isHolding)
        wake.connected(b)
        XCTAssertEqual(power.holds.count, 1, "one hold for any number of devices")
        wake.disconnected(a)
        XCTAssertTrue(power.released.isEmpty)
        wake.disconnected(b)
        XCTAssertEqual(power.released, [1])
        XCTAssertFalse(wake.isHolding)
        wake.disconnected(b)
        XCTAssertEqual(power.released, [1], "a second release changes nothing")
    }

    func testSameDeviceTwiceIsOneHolder() {
        let power = FakePower()
        let wake = DisplayWake(power: power)
        let a = Token()
        wake.connected(a)
        wake.connected(a)
        XCTAssertEqual(wake.holderCount, 1)
        wake.disconnected(a)
        XCTAssertFalse(wake.isHolding)
    }

    func testRetryWakesBetweenTriesAndStopsWhenFound() async throws {
        var wakes = 0
        var sleeps: [TimeInterval] = []
        var tries = 0
        let found: Int? = try await DisplayWakeRetry.run(
            wake: { wakes += 1 }, sleep: { sleeps.append($0) },
            attempt: { tries += 1; return tries == 3 ? 42 : nil })
        XCTAssertEqual(found, 42)
        XCTAssertEqual(tries, 3)
        XCTAssertEqual(wakes, 2)
        XCTAssertEqual(sleeps, [0.5, 1])
    }

    func testRetryGivesUpAfterTheLastDelay() async throws {
        var tries = 0
        var wakes = 0
        let found: Int? = try await DisplayWakeRetry.run(wake: { wakes += 1 }, sleep: { _ in },
                                                          attempt: { tries += 1; return nil })
        XCTAssertNil(found)
        XCTAssertEqual(tries, DisplayWakeRetry.delays.count + 1)
        XCTAssertEqual(wakes, DisplayWakeRetry.delays.count)
    }

    func testFirstTrySuccessNeverWakes() async throws {
        var wakes = 0
        let found: Int? = try await DisplayWakeRetry.run(wake: { wakes += 1 }, sleep: { _ in }, attempt: { 7 })
        XCTAssertEqual(found, 7)
        XCTAssertEqual(wakes, 0)
    }

    func testErrorsAreNotRetried() async {
        struct Denied: Error {}
        var tries = 0
        do {
            let _: Int? = try await DisplayWakeRetry.run(wake: {}, sleep: { _ in }, attempt: { tries += 1; throw Denied() })
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(tries, 1)
        }
    }
}
