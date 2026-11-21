import XCTest
@testable import Clamshell

final class VNCParkPolicyTests: XCTestCase {
    func testParksOnlyWhenUnlockedAndUpstreamAlive() {
        XCTAssertTrue(VNCParkPolicy.shouldPark(hostLocked: false, upstreamAlive: true))
        XCTAssertFalse(VNCParkPolicy.shouldPark(hostLocked: true, upstreamAlive: true))
        XCTAssertFalse(VNCParkPolicy.shouldPark(hostLocked: false, upstreamAlive: false))
    }

    func testKeptWhileViewerConnected() {
        var p = VNCParkPolicy()
        XCTAssertNil(p.closeReason(parkedAt: 0, now: 1, hostLocked: false, viewerConnected: true))
        XCTAssertNil(p.closeReason(parkedAt: 0, now: 3600, hostLocked: false, viewerConnected: true))
    }

    func testLockClosesImmediately() {
        var p = VNCParkPolicy()
        XCTAssertEqual(p.closeReason(parkedAt: 0, now: 1, hostLocked: true, viewerConnected: true), .hostLocked)
    }

    func testNoViewerClosesOnlyAfterGrace() {
        var p = VNCParkPolicy()
        XCTAssertNil(p.closeReason(parkedAt: 0, now: 10, hostLocked: false, viewerConnected: false))
        XCTAssertNil(p.closeReason(parkedAt: 0, now: 39.9, hostLocked: false, viewerConnected: false))
        XCTAssertEqual(p.closeReason(parkedAt: 0, now: 40, hostLocked: false, viewerConnected: false), .noViewers)
    }

    func testReloadWithinGraceKeepsConnection() {
        var p = VNCParkPolicy()
        XCTAssertNil(p.closeReason(parkedAt: 0, now: 10, hostLocked: false, viewerConnected: false))
        XCTAssertNil(p.closeReason(parkedAt: 0, now: 25, hostLocked: false, viewerConnected: true))
        // The clock restarts: 30 s from the next gap, not from the first.
        XCTAssertNil(p.closeReason(parkedAt: 0, now: 50, hostLocked: false, viewerConnected: false))
        XCTAssertNil(p.closeReason(parkedAt: 0, now: 79, hostLocked: false, viewerConnected: false))
        XCTAssertEqual(p.closeReason(parkedAt: 0, now: 80, hostLocked: false, viewerConnected: false), .noViewers)
    }

    func testMaxHold() {
        var p = VNCParkPolicy()
        XCTAssertNil(p.closeReason(parkedAt: 0, now: 12 * 3600 - 1, hostLocked: false, viewerConnected: true))
        XCTAssertEqual(p.closeReason(parkedAt: 0, now: 12 * 3600, hostLocked: false, viewerConnected: true), .maxHold)
    }

    func testResetClearsNoViewerClock() {
        var p = VNCParkPolicy()
        XCTAssertNil(p.closeReason(parkedAt: 0, now: 10, hostLocked: false, viewerConnected: false))
        p.reset()
        XCTAssertNil(p.closeReason(parkedAt: 0, now: 45, hostLocked: false, viewerConnected: false))
    }
}
