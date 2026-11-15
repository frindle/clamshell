import XCTest
@testable import Clamshell

final class DisplayReportTests: XCTestCase {
    private func r(_ w: UInt32, _ h: UInt32, second: Bool = false, _ sw: UInt32 = 0, _ sh: UInt32 = 0) -> DisplayReport {
        DisplayReport(width: w, height: h, secondDisplay: second, secondWidth: sw, secondHeight: sh)
    }

    func testIdenticalIsNotDifferent() {
        XCTAssertFalse(DisplayReport.differs(sent: r(2360, 1640), now: r(2360, 1640)))
        XCTAssertFalse(DisplayReport.differs(sent: nil, now: nil))
    }

    func testThreePercentRule() {
        XCTAssertFalse(DisplayReport.differs(sent: r(2000, 1000), now: r(2050, 1020))) // under 3%
        XCTAssertTrue(DisplayReport.differs(sent: r(2000, 1000), now: r(2061, 1000)))
        XCTAssertTrue(DisplayReport.differs(sent: r(2000, 1000), now: r(2000, 1031)))
        XCTAssertTrue(DisplayReport.differs(sent: r(2000, 1000), now: r(1000, 700)))
    }

    func testSecondDisplayFlagAndSize() {
        XCTAssertTrue(DisplayReport.differs(sent: r(2000, 1000), now: r(2000, 1000, second: true, 1920, 1080)))
        XCTAssertTrue(DisplayReport.differs(sent: r(2000, 1000, second: true, 1920, 1080), now: r(2000, 1000)))
        XCTAssertTrue(DisplayReport.differs(sent: r(2000, 1000, second: true, 1920, 1080),
                                            now: r(2000, 1000, second: true, 2560, 1440)))
        XCTAssertFalse(DisplayReport.differs(sent: r(2000, 1000, second: true, 1920, 1080),
                                             now: r(2000, 1000, second: true, 1930, 1085)))
        // The second size is ignored when there is no second display.
        XCTAssertFalse(DisplayReport.differs(sent: r(2000, 1000, second: false, 100, 100),
                                             now: r(2000, 1000, second: false, 900, 900)))
    }

    func testAppearingOrVanishingReport() {
        XCTAssertTrue(DisplayReport.differs(sent: nil, now: r(2000, 1000)))
        XCTAssertTrue(DisplayReport.differs(sent: r(2000, 1000), now: nil))
    }
}
