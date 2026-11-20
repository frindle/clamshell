import XCTest
import CryptoKit
@testable import Clamshell

final class LoginWindowAgentTests: XCTestCase {
    func testNoUserMeansLoginWindow() {
        XCTAssertEqual(LoginWindowAgent.console(forUserName: nil), .loginWindow)
        XCTAssertEqual(LoginWindowAgent.console(forUserName: ""), .loginWindow)
        XCTAssertEqual(LoginWindowAgent.console(forUserName: "loginwindow"), .loginWindow)
    }

    func testARealUserIsAUser() {
        XCTAssertEqual(LoginWindowAgent.console(forUserName: "example"), .user("example"))
        XCTAssertEqual(LoginWindowAgent.console(forUserName: "root"), .user("root"))
    }

    /// The agent must never serve next to a logged-in user's own Clamshell.
    func testServesOnlyAtTheLoginWindow() {
        XCTAssertTrue(LoginWindowAgent.shouldServe(.loginWindow))
        XCTAssertFalse(LoginWindowAgent.shouldServe(.user("example")))
        XCTAssertFalse(LoginWindowAgent.shouldServe(.user("root")))
    }

    /// Packaging ships both plist templates in the app, and the install code
    /// reads them from there.
    func testPackagingShipsTheAgentPlists() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("package.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("Contents/Resources/loginwindow-agent"))
        for label in [LoginWindowInstall.agentLabel, LoginWindowInstall.syncLabel] {
            let plist = root.appendingPathComponent("scripts/loginwindow-agent/\(label).plist")
            let text = try String(contentsOf: plist, encoding: .utf8)
            let data = try PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil)
            XCTAssertEqual((data as? [String: Any])?["Label"] as? String, label)
        }
    }

    func testAgentRefusesWithoutAMirroredHostKey() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lw-agent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNotNil(LoginWindowAgent.hostStateProblem(in: dir)) // no folder
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        XCTAssertNotNil(LoginWindowAgent.hostStateProblem(in: dir)) // folder, no key
        let key = P256.Signing.PrivateKey()
        try SecureFile.replace(dir.appendingPathComponent(HostIdentity.fileName), contents: key.rawRepresentation)
        XCTAssertNil(LoginWindowAgent.hostStateProblem(in: dir))
        chmod(dir.path, 0o755)
        XCTAssertNotNil(LoginWindowAgent.hostStateProblem(in: dir)) // open to others
    }
}
