import XCTest
@testable import Clamshell

final class RestartServiceTests: XCTestCase {
    private final class Spy: @unchecked Sendable {
        var exe: String?
        var args: [String] = []
        var stdin = Data()
        var status: Int32? = 0
        var supports = true
        var runs = 0
        var runner: RestartService.Runner {
            .init(supportsAuthRestart: { self.supports },
                  run: { e, a, s in self.exe = e; self.args = a; self.stdin = s; self.runs += 1; return self.status })
        }
    }
    private let secret = "Zebra-Quartz-19-synthetic"

    func testPasswordGoesOnlyToStdin() {
        let spy = Spy()
        XCTAssertEqual(RestartService.restart(username: "tester", password: secret, runner: spy.runner), .restarting)
        XCTAssertEqual(spy.exe, RestartService.sudo)
        XCTAssertFalse(spy.args.joined(separator: " ").contains(secret))
        XCTAssertTrue(String(decoding: spy.stdin, as: UTF8.self).hasPrefix(secret + "\n<?xml"))
    }

    func testOutcomes() {
        let spy = Spy()
        spy.status = 1
        XCTAssertEqual(RestartService.restart(username: "tester", password: secret, runner: spy.runner), .refused)
        spy.status = nil
        XCTAssertEqual(RestartService.restart(username: "tester", password: secret, runner: spy.runner), .failed)
        spy.supports = false
        XCTAssertEqual(RestartService.restart(username: "tester", password: secret, runner: spy.runner), .unsupported)
    }

    func testBadInputNeverRuns() {
        let spy = Spy()
        for (u, p) in [("", secret), ("a b", secret), ("tester", ""), ("tester", "a\nb"), (String(repeating: "u", count: 65), secret)] {
            XCTAssertEqual(RestartService.restart(username: u, password: p, runner: spy.runner), .failed)
        }
        XCTAssertEqual(spy.runs, 0)
    }

    func testPlistEscapesSpecialCharacters() {
        let text = String(decoding: RestartService.stdinPayload(username: "tester", password: "a<b&c>d"), as: UTF8.self)
        XCTAssertTrue(text.contains("a&lt;b&amp;c&gt;d"))
    }
}

final class RebootReadinessVerdictTests: XCTestCase {
    private func report(auto: Bool, vault: Bool, ssh: Bool, authrestart: Bool) -> RebootReadiness.Report {
        .init(autorestartOn: auto, fileVaultOn: vault, sshOn: ssh, loginItemOn: true, authRestartSupported: authrestart)
    }

    func testOutageNeedsAutorestartAndSSHWhenFileVaultIsOn() {
        XCTAssertTrue(RebootReadiness.verdicts(report(auto: true, vault: true, ssh: true, authrestart: true)).outage)
        XCTAssertFalse(RebootReadiness.verdicts(report(auto: true, vault: true, ssh: false, authrestart: true)).outage)
        XCTAssertFalse(RebootReadiness.verdicts(report(auto: false, vault: true, ssh: true, authrestart: true)).outage)
        XCTAssertTrue(RebootReadiness.verdicts(report(auto: true, vault: false, ssh: false, authrestart: false)).outage)
    }

    func testPlannedNeedsAuthRestart() {
        XCTAssertTrue(RebootReadiness.verdicts(report(auto: false, vault: true, ssh: false, authrestart: true)).planned)
        XCTAssertFalse(RebootReadiness.verdicts(report(auto: true, vault: true, ssh: true, authrestart: false)).planned)
        XCTAssertTrue(RebootReadiness.verdicts(report(auto: false, vault: false, ssh: false, authrestart: false)).planned)
    }
}
