import XCTest
@testable import Clamshell

final class AutoReturnTests: XCTestCase {
    func testInstalledByDefaultWhenNothingSaid() {
        XCTAssertTrue(AutoReturnPolicy.shouldInstall(optedOut: false, alreadyEnabled: false, isInstalledApp: true))
    }

    func testOptOutAndAlreadyThereAndBareBinaryDoNothing() {
        XCTAssertFalse(AutoReturnPolicy.shouldInstall(optedOut: true, alreadyEnabled: false, isInstalledApp: true))
        XCTAssertFalse(AutoReturnPolicy.shouldInstall(optedOut: false, alreadyEnabled: true, isInstalledApp: true))
        XCTAssertFalse(AutoReturnPolicy.shouldInstall(optedOut: false, alreadyEnabled: false, isInstalledApp: false))
    }

    func testOptOutIsRememberedAndUnsetMeansIn() {
        let suite = "autoReturnTest-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertFalse(AutoReturnPolicy.isOptedOut(d), "an upgrade with nothing saved is opted in")
        AutoReturnPolicy.setOptedOut(true, d)
        XCTAssertTrue(AutoReturnPolicy.isOptedOut(d))
        AutoReturnPolicy.setOptedOut(false, d)
        XCTAssertFalse(AutoReturnPolicy.isOptedOut(d))
    }

    func testSingleInstanceWaitsForTheOldCopyThenYields() {
        XCTAssertEqual(SingleInstancePolicy.decide(others: [], elapsed: 0), .proceed)
        XCTAssertEqual(SingleInstancePolicy.decide(others: [123], elapsed: 0), .wait)
        XCTAssertEqual(SingleInstancePolicy.decide(others: [123], elapsed: SingleInstancePolicy.patience - 1), .wait)
        XCTAssertEqual(SingleInstancePolicy.decide(others: [123], elapsed: SingleInstancePolicy.patience), .yield)
        XCTAssertEqual(SingleInstancePolicy.decide(others: [], elapsed: 999), .proceed, "gone is gone")
    }
}
