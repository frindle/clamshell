import XCTest
@testable import Clamshell

final class LoginWindowRefreshTests: XCTestCase {
    private let layout = LoginWindowInstall.Layout()
    private let config = LoginWindowInstall.Config(user: "u", uid: 501, userStateDirectory: "/tmp/x", appPath: "/Applications/Clamshell.app")

    private func run(theirs: String?, ours: String?, same: Bool, replaceFails: Bool = false) -> (LoginWindowInstall.Refresh, Bool) {
        var replaced = false
        let result = LoginWindowInstall.refreshAppCopy(
            layout: layout, config: config,
            versionOf: { $0 == "/Applications/Clamshell.app" ? theirs : ours },
            sameIdentity: { _, _ in same },
            replace: { _, _ in
                replaced = true
                if replaceFails { throw LoginWindowInstall.InstallError("disk") }
            })
        return (result, replaced)
    }

    func testSameVersionDoesNothing() {
        let (r, replaced) = run(theirs: "1.0 1", ours: "1.0 1", same: true)
        XCTAssertEqual(r, .upToDate)
        XCTAssertFalse(replaced)
    }

    func testNewVersionWithSameSignerIsCopied() {
        let (r, replaced) = run(theirs: "1.1 2", ours: "1.0 1", same: true)
        XCTAssertEqual(r, .refreshed(from: "1.0 1", to: "1.1 2"))
        XCTAssertTrue(replaced)
    }

    func testNewVersionFromAnotherSignerIsNeverCopied() {
        let (r, replaced) = run(theirs: "1.1 2", ours: "1.0 1", same: false)
        guard case .skipped = r else { return XCTFail("expected skipped, got \(r)") }
        XCTAssertFalse(replaced)
    }

    func testUnreadableAppOrMissingCopyIsSkipped() {
        for (t, o) in [(nil, "1.0 1"), ("1.1 2", nil)] as [(String?, String?)] {
            let (r, replaced) = run(theirs: t, ours: o, same: true)
            guard case .skipped = r else { return XCTFail("expected skipped, got \(r)") }
            XCTAssertFalse(replaced)
        }
    }

    func testFailedCopyIsReportedNotRefreshed() {
        let (r, _) = run(theirs: "1.1 2", ours: "1.0 1", same: true, replaceFails: true)
        guard case .skipped = r else { return XCTFail("expected skipped, got \(r)") }
    }

    func testOutdatedCopyMakesStatusUnhealthy() {
        var s = LoginWindowInstall.Status()
        s.appCopy = true; s.agentPlist = true; s.syncPlist = true
        s.config = config; s.mirrorHostKey = true; s.mirrorMatchesUser = true
        s.copyVersion = "1.0 1"; s.installedVersion = "1.0 1"
        XCTAssertTrue(s.healthy)
        s.installedVersion = "1.1 2"
        XCTAssertTrue(s.outdated)
        XCTAssertFalse(s.healthy)
    }
}
