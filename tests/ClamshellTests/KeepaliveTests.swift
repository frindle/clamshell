import XCTest
@testable import Clamshell

final class KeepaliveTests: XCTestCase {
    func testPingsOnlyAfterIdleInterval() {
        var g = KeepaliveGate(now: 100)
        XCTAssertFalse(g.shouldPing(at: 100))
        XCTAssertFalse(g.shouldPing(at: 119.9))
        XCTAssertTrue(g.shouldPing(at: 120))
        g.noteSent(at: 120)
        XCTAssertFalse(g.shouldPing(at: 139))
        XCTAssertTrue(g.shouldPing(at: 140))
    }

    func testAnySendResetsTheClock() {
        var g = KeepaliveGate(now: 0)
        g.noteSent(at: 15)
        XCTAssertFalse(g.shouldPing(at: 34))
        XCTAssertTrue(g.shouldPing(at: 35))
    }

    func testBackwardsClockNeverPings() {
        let g = KeepaliveGate(now: 50)
        XCTAssertFalse(g.shouldPing(at: 10))
    }
}
