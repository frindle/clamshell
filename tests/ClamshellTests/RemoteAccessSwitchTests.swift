import XCTest
@testable import Clamshell

final class RemoteAccessSwitchTests: XCTestCase {
    private let enabledOut = """
    disabled services = {
    \t"com.apple.example" => disabled
    \t"com.apple.screensharing" => enabled
    }
    """

    func testParsesEnabledAndDisabled() {
        XCTAssertEqual(RemoteAccessSwitch.parse(printDisabled: enabledOut), true)
        XCTAssertEqual(RemoteAccessSwitch.parse(printDisabled: enabledOut.replacingOccurrences(of: "screensharing\" => enabled", with: "screensharing\" => disabled")), false)
        XCTAssertEqual(RemoteAccessSwitch.parse(printDisabled: "\t\"com.apple.screensharing\" => true"), false)
        XCTAssertEqual(RemoteAccessSwitch.parse(printDisabled: "\t\"com.apple.screensharing\" => false"), true)
    }

    func testUnlistedOrUnreadableMeansOn() {
        XCTAssertNil(RemoteAccessSwitch.parse(printDisabled: "disabled services = {\n}"))
        XCTAssertTrue(RemoteAccessSwitch.resolve(nil), "a failed probe must not lock the owner out")
        XCTAssertFalse(RemoteAccessSwitch.resolve(false))
    }

    func testOffRefusesWithReasonTwoAndOnAdmits() {
        XCTAssertEqual(RemoteAccessSwitch.decision(enabled: true), .admit)
        XCTAssertEqual(RemoteAccessSwitch.decision(enabled: false), .refuse(.remoteAccessOff))
        XCTAssertEqual(HostBusyReason.remoteAccessOff.rawValue, 2)
    }

    func testChangeLineOnlyOnRealChange() {
        XCTAssertNil(RemoteAccessSwitch.changeLine(from: true, to: true))
        XCTAssertNil(RemoteAccessSwitch.changeLine(from: false, to: false))
        XCTAssertTrue(RemoteAccessSwitch.changeLine(from: true, to: false)!.contains("OFF"))
        XCTAssertTrue(RemoteAccessSwitch.changeLine(from: false, to: true)!.contains("ON"))
    }
}
