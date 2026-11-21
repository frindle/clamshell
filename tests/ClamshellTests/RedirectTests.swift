import XCTest
@testable import Clamshell

private final class FakeFilter: PacketFilter {
    var rules: String? = ""
    var enabled = false
    var conf: String? = "scrub-anchor \"com.apple/*\"\nnat-anchor \"com.apple/*\"\nrdr-anchor \"com.apple/*\"\n"
    var loads: [String] = []
    var failLoad = false

    func loadedRules() -> String? { rules }
    func isEnabled() -> Bool { enabled }
    func load(_ r: String) -> Bool {
        loads.append(r)
        if failLoad { return false }
        // pfctl prints the rule back in its own words.
        rules = "rdr pass inet proto tcp from any to any port = 5900 -> 127.0.0.1 port 5950\n"
        return true
    }
    func enable() -> Bool { enabled = true; return true }
    func remove() -> Bool { rules = ""; return true }
    func pfConf() -> String? { conf }
}

final class RedirectTests: XCTestCase {
    func testAnchorIsUnderComApple() {
        XCTAssertTrue(RedirectPolicy.anchor.hasPrefix("com.apple/"))
    }

    func testRuleSendsVNCPortToLoopbackBackend() {
        XCTAssertEqual(RedirectPolicy.rules(),
                       "rdr pass inet proto tcp from any to any port 5900 -> 127.0.0.1 port 5950\n")
    }

    func testPfConfCheck() {
        XCTAssertTrue(RedirectPolicy.pfConfEvaluatesAnchor("rdr-anchor \"com.apple/*\"\n"))
        XCTAssertFalse(RedirectPolicy.pfConfEvaluatesAnchor("# rdr-anchor \"com.apple/*\"\n"))
        XCTAssertFalse(RedirectPolicy.pfConfEvaluatesAnchor("nat-anchor \"com.apple/*\"\n"))
        XCTAssertFalse(RedirectPolicy.pfConfEvaluatesAnchor(""))
    }

    func testPfctlListingIsRecognised() {
        XCTAssertTrue(RedirectPolicy.hasRedirect("rdr pass inet proto tcp from any to any port = 5900 -> 127.0.0.1 port 5950\n"))
        XCTAssertTrue(RedirectPolicy.hasRedirect("rdr pass inet proto tcp from any to any port 5900 -> 127.0.0.1 port 5950"))
        XCTAssertFalse(RedirectPolicy.hasRedirect(""))
        XCTAssertFalse(RedirectPolicy.hasRedirect("rdr pass inet proto tcp from any to any port = 5900 -> 127.0.0.1 port 9999"))
        XCTAssertFalse(RedirectPolicy.hasRedirect("rdr pass inet proto tcp from any to any port = 80 -> 127.0.0.1 port 5950"))
    }

    func testDecisions() {
        let good = "rdr pass inet proto tcp from any to any port = 5900 -> 127.0.0.1 port 5950\n"
        XCTAssertEqual(RedirectPolicy.decide(loadedRules: good, pfEnabled: true), .nothing)
        guard case .load = RedirectPolicy.decide(loadedRules: "", pfEnabled: true) else { return XCTFail("missing rule must load") }
        guard case .load = RedirectPolicy.decide(loadedRules: good, pfEnabled: false) else { return XCTFail("pf off must load") }
        guard case .load = RedirectPolicy.decide(loadedRules: nil, pfEnabled: true) else { return XCTFail("unreadable must load") }
    }

    func testDaemonPutsTheRuleBackAfterAResetAndSaysSo() {
        let pf = FakeFilter()
        var logs: [String] = []
        RedirectDaemon.reconcile(pf, log: { logs.append($0) })
        XCTAssertEqual(pf.loads.count, 1)
        XCTAssertTrue(pf.enabled)
        XCTAssertTrue(logs.contains { $0.contains("redirect from port 5900") })

        // Steady state: nothing to do, nothing logged.
        logs = []
        XCTAssertEqual(RedirectDaemon.reconcile(pf, log: { logs.append($0) }), .nothing)
        XCTAssertEqual(pf.loads.count, 1)
        XCTAssertTrue(logs.isEmpty)

        // A macOS update resets pf: rules gone, pf off.
        pf.rules = ""
        pf.enabled = false
        RedirectDaemon.reconcile(pf, log: { logs.append($0) })
        XCTAssertEqual(pf.loads.count, 2)
        XCTAssertTrue(pf.enabled)
        XCTAssertTrue(logs.contains { $0.contains("missing") || $0.contains("reset") })
    }

    func testDaemonReportsAPfConfThatNoLongerEvaluatesTheAnchor() {
        let pf = FakeFilter()
        pf.conf = "nat-anchor \"com.apple/*\"\n"
        var logs: [String] = []
        RedirectDaemon.reconcile(pf, log: { logs.append($0) })
        XCTAssertTrue(logs.contains { $0.contains("no longer evaluates") })
    }

    func testFailedLoadIsLoggedNotHidden() {
        let pf = FakeFilter()
        pf.failLoad = true
        var logs: [String] = []
        RedirectDaemon.reconcile(pf, log: { logs.append($0) })
        XCTAssertTrue(logs.contains { $0.contains("failed") })
        XCTAssertFalse(pf.enabled)
    }

    func testThisBuildCarriesAnRFBServerSoTheGateCanOpen() {
        XCTAssertTrue(RFBServerGate.present)
        XCTAssertTrue(RFBServerGate.selfTest())
    }
}
