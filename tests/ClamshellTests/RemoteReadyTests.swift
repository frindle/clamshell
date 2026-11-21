import XCTest
@testable import Clamshell

final class RemoteReadyTests: XCTestCase {
    private func healthyHelper() -> LoginWindowInstall.Status {
        var s = LoginWindowInstall.Status()
        s.appCopy = true; s.agentPlist = true; s.syncPlist = true
        s.config = .init(user: "u", uid: 501, userStateDirectory: "/x", appPath: nil)
        s.mirrorHostKey = true; s.mirrorMatchesUser = true
        s.copyVersion = "1 1"; s.installedVersion = "1 1"
        return s
    }

    private func ready() -> RemoteReady.Inputs {
        .init(nativeStreamingOn: true, nativeLockScreenOn: true, displayWakeWorks: true,
              keychainReadable: true, launchAgentInstalled: true, loginWindow: healthyHelper())
    }

    private func failing(_ i: RemoteReady.Inputs) -> [String] {
        RemoteReady.checks(i).filter { !$0.ok }.map { $0.name }
    }

    func testEverythingGoodPasses() {
        XCTAssertTrue(RemoteReady.allPass(RemoteReady.checks(ready())))
        XCTAssertTrue(RemoteReady.render(RemoteReady.checks(ready())).contains("Ready:"))
    }

    func testEachFailureIsReportedOnItsOwn() {
        var i = ready(); i.nativeStreamingOn = false
        XCTAssertEqual(failing(i), ["Native streaming is on"])
        i = ready(); i.nativeLockScreenOn = false
        XCTAssertEqual(failing(i), ["Lock screen is carried by the stream"])
        i = ready(); i.displayWakeWorks = false
        XCTAssertEqual(failing(i), ["Display wakes on request"])
        i = ready(); i.keychainReadable = false
        XCTAssertEqual(failing(i), ["Keychain key readable without a prompt"])
        i = ready(); i.launchAgentInstalled = false
        XCTAssertEqual(failing(i), ["Clamshell restarts by itself (launch agent)"])
    }

    func testMissingHelperFailsBothHelperChecks() {
        var i = ready(); i.loginWindow = LoginWindowInstall.Status()
        XCTAssertEqual(failing(i).count, 2)
        XCTAssertTrue(RemoteReady.render(RemoteReady.checks(i)).contains("sudo clamshell loginwindow install"))
    }

    func testOutdatedHelperFailsBothChecks() {
        var i = ready(); i.loginWindow.installedVersion = "2 2"
        XCTAssertEqual(failing(i), ["Login-window helper installed and healthy", "Login-window helper is up to date"])
    }

    func testStaleMirrorFailsHealthOnly() {
        var i = ready(); i.loginWindow.mirrorMatchesUser = false
        XCTAssertEqual(failing(i), ["Login-window helper installed and healthy"])
    }

    func testNoScreenSharingCheckExists() {
        XCTAssertFalse(RemoteReady.checks(ready()).contains { $0.name.lowercased().contains("screen sharing") })
    }
}
