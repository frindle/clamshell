import XCTest
@testable import Clamshell

final class LoginWindowAgentTests: XCTestCase {
    func testNoUserMeansLoginWindow() {
        XCTAssertEqual(LoginWindowAgent.console(forUserName: nil), .loginWindow)
        XCTAssertEqual(LoginWindowAgent.console(forUserName: ""), .loginWindow)
        XCTAssertEqual(LoginWindowAgent.console(forUserName: "loginwindow"), .loginWindow)
    }

    func testARealUserIsAUser() {
        XCTAssertEqual(LoginWindowAgent.console(forUserName: "penn"), .user("penn"))
        XCTAssertEqual(LoginWindowAgent.console(forUserName: "root"), .user("root"))
    }

    /// The agent must never serve next to a logged-in user's own Clamshell.
    func testServesOnlyAtTheLoginWindow() {
        XCTAssertTrue(LoginWindowAgent.shouldServe(.loginWindow))
        XCTAssertFalse(LoginWindowAgent.shouldServe(.user("penn")))
        XCTAssertFalse(LoginWindowAgent.shouldServe(.user("root")))
    }

    /// Guards the "not installed" promise: the plist stays out of the bundle.
    func testPackagingDoesNotShipTheAgentPlist() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("package.sh"), encoding: .utf8)
        XCTAssertFalse(script.contains("loginwindow-agent"))
    }
}
