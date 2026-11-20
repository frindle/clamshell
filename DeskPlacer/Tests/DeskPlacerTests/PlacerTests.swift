import XCTest
@testable import DeskPlacer

// Recorded-style load samples. Names are neutral labels. Figures follow the plan's section 2 and 9.3
// (operator 64 GB with heavy swap; second Mac 96 GB with ~71 GB free). Darkbloom footprint 1,524 + 440 MB
// is the visible figure until experiment E2 measures the real one.
enum Samples {
    static let operatorPressured = HostSample(name: "op", totalMB: 65536, freeMB: 900, swapUsedMB: 9900, pressure: .red)
    static let operatorCalm = HostSample(name: "op", totalMB: 65536, freeMB: 30000, swapUsedMB: 200, pressure: .green)
    static let big = HostSample(name: "big", totalMB: 98304, freeMB: 71000, swapUsedMB: 0, pressure: .green)
    static let tight = HostSample(name: "tight", totalMB: 65536, freeMB: 9000, swapUsedMB: 0, pressure: .green)
    static let bigYellow = HostSample(name: "big", totalMB: 98304, freeMB: 71000, swapUsedMB: 0, pressure: .yellow)

    static func config() -> PlacementConfig {
        var c = PlacementConfig()
        c.darkbloomFootprintMB = ["op": 1964, "big": 1964, "tight": 1964]
        return c
    }
}

final class PlacerTests: XCTestCase {
    struct Case { let name: String; let rules: String; let app: String; let seat: String; let hosts: [HostSample]
                  var running: [String: String] = [:]; var expectedMB = 0; let want: PlacementDecision }

    func testTable() throws {
        let slackRule = "[app.\"slack\"]\nprefer = \"auto\"\n"
        let cases: [Case] = [
            Case(name: "unlisted app stays on the seat", rules: "", app: "finder", seat: "op", hosts: [Samples.operatorPressured, Samples.big],
                 want: .run(on: "op", reason: .localRule)),
            Case(name: "auto picks the Mac with most headroom", rules: slackRule, app: "slack", seat: "op",
                 hosts: [Samples.operatorCalm, Samples.big, Samples.tight], want: .run(on: "big", reason: .mostHeadroom)),
            Case(name: "headroom is after Darkbloom plus 8 GB: tight Mac has -1156", rules: slackRule, app: "slack", seat: "op",
                 hosts: [Samples.tight], want: .refused(.noHostQualifies)),
            Case(name: "a Mac not green is never chosen", rules: slackRule, app: "slack", seat: "op",
                 hosts: [Samples.operatorPressured, Samples.bigYellow], want: .refused(.noHostQualifies)),
            Case(name: "pressured seat is skipped even with the most free memory elsewhere being worse", rules: slackRule, app: "slack", seat: "op",
                 hosts: [Samples.operatorPressured, Samples.big], want: .run(on: "big", reason: .mostHeadroom)),
            Case(name: "home runs on its Mac", rules: "[app.\"ff\"]\nhome = \"big\"\n", app: "ff", seat: "op",
                 hosts: [Samples.operatorPressured, Samples.big], want: .run(on: "big", reason: .home)),
            Case(name: "pin is the same as home", rules: "[app.\"ff\"]\npin = \"big\"\n", app: "ff", seat: "op",
                 hosts: [Samples.big], want: .run(on: "big", reason: .home)),
            Case(name: "home Mac under pressure refuses", rules: "[app.\"ff\"]\nhome = \"big\"\n", app: "ff", seat: "op",
                 hosts: [Samples.bigYellow], want: .refused(.notGreen("big"))),
            Case(name: "home Mac unreachable refuses", rules: "[app.\"ff\"]\nhome = \"big\"\n", app: "ff", seat: "op",
                 hosts: [Samples.operatorCalm], want: .refused(.homeUnreachable("big"))),
            Case(name: "home Mac without room for the app refuses", rules: "[app.\"ff\"]\nhome = \"tight\"\n", app: "ff", seat: "op",
                 hosts: [Samples.tight], expectedMB: 0, want: .refused(.noRoom("tight"))),
            Case(name: "needs camera forces local even with a home", rules: "[app.\"zoom\"]\nhome = \"big\"\nneeds = [\"camera\"]\n", app: "zoom", seat: "op",
                 hosts: [Samples.big], want: .run(on: "op", reason: .hardwareNeed([.camera]))),
            Case(name: "already running elsewhere: open that copy", rules: slackRule, app: "slack", seat: "op",
                 hosts: [Samples.big], running: ["slack": "tight"], want: .alreadyRunning(on: "tight")),
            Case(name: "prefer host avoids the seat", rules: "[app.\"mail\"]\nprefer = \"host\"\n", app: "mail", seat: "big",
                 hosts: [Samples.big, HostSample(name: "other", totalMB: 98304, freeMB: 40000)], want: .run(on: "other", reason: .mostHeadroom)),
            Case(name: "prefer host falls back to the seat when it is the only one", rules: "[app.\"mail\"]\nprefer = \"host\"\n", app: "mail", seat: "big",
                 hosts: [Samples.big], want: .run(on: "big", reason: .onlyOtherChoiceWasSeat)),
            Case(name: "expected memory must fit in the headroom", rules: slackRule, app: "slack", seat: "op",
                 hosts: [Samples.big], expectedMB: 70000, want: .refused(.noHostQualifies)),
            Case(name: "default mode from the file", rules: "[defaults]\nmode = \"auto\"\n", app: "anything", seat: "op",
                 hosts: [Samples.operatorCalm, Samples.big], want: .run(on: "big", reason: .mostHeadroom)),
            Case(name: "tie goes to the lower name", rules: slackRule, app: "slack", seat: "op",
                 hosts: [HostSample(name: "b", totalMB: 1, freeMB: 20000), HostSample(name: "a", totalMB: 1, freeMB: 20000)],
                 want: .run(on: "a", reason: .mostHeadroom)),
        ]
        for c in cases {
            var cfg = try RulesFile.parse(c.rules)
            cfg.darkbloomFootprintMB = Samples.config().darkbloomFootprintMB
            let got = Placer.decide(app: c.app, config: cfg, input: PlacerInput(seat: c.seat, hosts: c.hosts, running: c.running, expectedMB: c.expectedMB))
            XCTAssertEqual(got, c.want, c.name)
        }
    }

    func testInputOrderNeverChangesTheAnswer() throws {
        let cfg = try RulesFile.parse("[app.\"slack\"]\nprefer = \"auto\"\n")
        let hosts = [Samples.operatorCalm, Samples.big, Samples.tight]
        var seen = Set<String>()
        for perm in [[0, 1, 2], [2, 1, 0], [1, 0, 2], [1, 2, 0]] {
            let d = Placer.decide(app: "slack", config: cfg, input: PlacerInput(seat: "op", hosts: perm.map { hosts[$0] }))
            if case .run(let on, _) = d { seen.insert(on) }
        }
        XCTAssertEqual(seen, ["big"])
    }

    func testHeadroomArithmetic() {
        let cfg = Samples.config()
        XCTAssertEqual(cfg.reserveMB(on: "big"), 8192 + 1964)
        XCTAssertEqual(cfg.headroomMB(Samples.big), 71000 - 8192 - 1964)
        XCTAssertEqual(cfg.headroomMB(Samples.tight), 9000 - 8192 - 1964)
        XCTAssertEqual(cfg.reserveMB(on: "unknown-mac"), 8192)
    }
}

final class RulesFileTests: XCTestCase {
    func testFullFile() throws {
        let text = """
        # operator rules
        [defaults]
        mode = "local"   # built-in anyway
        reserve_buffer_mb = 4096
        swap_threshold_mb = 2048

        [mac."big"]
        darkbloom_footprint_mb = 2500

        [app."org.mozilla.firefox"]
        home = "big"

        [app.us.zoom.xos]
        needs = ["camera", "drm"]

        [app."com.tinyspeck.slackmacgap"]
        mode = "anywhere"
        """
        let c = try RulesFile.parse(text)
        XCTAssertEqual(c.defaultPlacement, .local)
        XCTAssertEqual(c.reserveBufferMB, 4096)
        XCTAssertEqual(c.swapThresholdMB, 2048)
        XCTAssertEqual(c.darkbloomFootprintMB["big"], 2500)
        XCTAssertEqual(c.apps["org.mozilla.firefox"]?.placement, .home("big"))
        XCTAssertEqual(c.apps["us.zoom.xos"]?.needs, [.camera, .drm])
        XCTAssertEqual(c.apps["com.tinyspeck.slackmacgap"]?.placement, .anywhere(avoidSeat: false))
    }

    func testHashInsideStringIsNotAComment() throws {
        let c = try RulesFile.parse("[app.\"a#b\"]\nhome = \"x#y\"\n")
        XCTAssertEqual(c.apps["a#b"]?.placement, .home("x#y"))
    }

    func testErrorsCarryLineNumbers() {
        let bad: [(String, Int)] = [
            ("[nope]\n", 1),
            ("x = 1\n", 1),
            ("[defaults]\nmode = \"sideways\"\n", 2),
            ("[defaults]\nreserve_buffer_mb = -3\n", 2),
            ("[app.\"a\"]\nneeds = [\"toaster\"]\n", 2),
            ("[app.\"a\"]\nneeds = \"camera\"\n", 2),
            ("[app.\"a\"]\nhome = \"\"\n", 2),
            ("[app.\"a\"]\nfrobnicate = 1\n", 2),
            ("[app.\"a\"\n", 1),
            ("[app.\"a\"]\nhome\n", 2),
        ]
        for (text, line) in bad {
            XCTAssertThrowsError(try RulesFile.parse(text), text) { e in XCTAssertEqual((e as? RulesParseError)?.line, line, text) }
        }
    }

    func testNeedsBeatEverythingInResolve() throws {
        let c = try RulesFile.parse("[app.\"a\"]\nhome = \"big\"\nneeds = [\"usbkey\"]\n")
        XCTAssertEqual(c.resolve("a").placement, .local)
    }
}

final class StateCostTests: XCTestCase {
    func testCatalogMatchesTheSection2Totals() {
        XCTAssertEqual(AppCatalog.totalMB(AppCatalog.browsers), 11187)
        XCTAssertEqual(AppCatalog.totalMB(AppCatalog.chatAndMail), 3574)
        XCTAssertEqual(AppCatalog.totalMB(AppCatalog.claudeGroup), 3097)
        XCTAssertEqual(AppCatalog.profile("org.mozilla.firefox")?.residentMB, 6714)
        XCTAssertEqual(AppCatalog.profile("darkbloom")?.residentMB, 1524)
        XCTAssertEqual(AppCatalog.profile("darkbloom-sandbox")?.residentMB, 440)
    }

    func testCostTable() {
        func p(_ kind: StateKind, _ restore: RestoreScore, _ offer: OfferPolicy = .auto) -> AppProfile {
            AppProfile(key: "k", name: "k", residentMB: 100, kind: kind, offer: offer, restore: restore)
        }
        let rows: [(String, AppProfile, [Blocker], MoveCost)] = [
            ("service is free", p(.service, .untested), [], .free),
            ("terminal in persistent session is free", p(.f, .untested), [], .free),
            ("Claude Code idle is free", p(.g, .untested), [], .free),
            ("Claude Code mid tool call is blocked", p(.g, .untested), [.toolCallInFlight], .blocked([.toolCallInFlight])),
            ("plain terminal job blocks", p(.f, .untested), [.localTerminalJob], .blocked([.localTerminalJob])),
            ("chat app, restore passed: cheap", p(.c, .passed), [], .cheap),
            ("chat app in a call: blocked", p(.c, .passed), [.inCall], .blocked([.inCall])),
            ("chat app, restore failed: pinned", p(.c, .failed), [], .pinned(.restoreFailed)),
            ("chat app, restore untested: pinned", p(.c, .untested), [], .pinned(.restoreUntested)),
            ("document with unsaved edits: blocked", p(.d, .passed), [.unsavedEdits(["Budget draft"])], .blocked([.unsavedEdits(["Budget draft"])])),
            ("document saved: cheap", p(.d, .passed), [], .cheap),
            ("browser tab media (E) passed: cheap", p(.e, .passed), [], .cheap),
            ("layout-only app (A) passed: cheap", p(.a, .passed), [], .cheap),
            ("download in progress blocks", p(.b, .passed), [.transferInProgress], .blocked([.transferInProgress])),
            ("kind H is blocked even with nothing reported", p(.h, .passed), [], .blocked([.transferInProgress])),
            ("never-move app is pinned whatever else", p(.service, .passed, .never), [], .pinned(.neverMoves)),
            ("never-move app with a blocker is still pinned", p(.c, .passed, .never), [.inCall], .pinned(.neverMoves)),
        ]
        for (name, app, blockers, want) in rows { XCTAssertEqual(StateCostTable.cost(of: app, blockers: blockers), want, name) }
    }

    func testDarkbloomAndBloomGaugeAreNeverMovable() {
        for k in ["darkbloom", "darkbloom-sandbox", "bloomgauge"] {
            let a = AppCatalog.profile(k)!
            XCTAssertEqual(StateCostTable.cost(of: a), .pinned(.neverMoves), k)
        }
    }

    func scored(_ keys: [String]) -> [RunningApp] {
        keys.map { var p = AppCatalog.profile($0)!; if p.kind == .c { p.restore = .passed }; return RunningApp(profile: p) }
    }

    func testProposalPicksLargestMovableApp() {
        let running = scored(["com.tinyspeck.slackmacgap", "ch.protonmail.desktop", "com.anthropic.claudefordesktop", "org.mozilla.firefox", "darkbloom"])
        let cfg = Samples.config()
        let prop = MoveAdvisor.propose(from: Samples.operatorPressured, running: running, others: [Samples.big, Samples.tight], config: cfg)
        // Firefox is bigger but only moves on request; Darkbloom never. Claude desktop (1805) is next.
        XCTAssertEqual(prop?.app.key, "com.anthropic.claudefordesktop")
        XCTAssertEqual(prop?.to, "big")
        XCTAssertEqual(prop?.cost, .cheap)
    }

    func testProposalSkipsBlockedAndUntestedAndFallsToNext() {
        var running = scored(["com.tinyspeck.slackmacgap", "ch.protonmail.desktop", "com.anthropic.claudefordesktop"])
        running[2].blockers = [.inCall]                  // Claude desktop blocked
        running[0].profile.restore = .untested           // Slack never scored
        let prop = MoveAdvisor.propose(from: Samples.operatorPressured, running: running, others: [Samples.big], config: Samples.config())
        XCTAssertEqual(prop?.app.key, "ch.protonmail.desktop")
    }

    func testNoProposalWhenNotShortOrNowhereToGoOrNeverFor() {
        let running = scored(["com.tinyspeck.slackmacgap"])
        let cfg = Samples.config()
        XCTAssertNil(MoveAdvisor.propose(from: Samples.operatorCalm, running: running, others: [Samples.big], config: cfg))
        XCTAssertNil(MoveAdvisor.propose(from: Samples.operatorPressured, running: running, others: [Samples.tight, Samples.bigYellow], config: cfg))
        XCTAssertNil(MoveAdvisor.propose(from: Samples.operatorPressured, running: running, others: [Samples.big], config: cfg, neverFor: ["com.tinyspeck.slackmacgap"]))
    }

    func testSwapAloneMakesAMacShort() {
        var s = Samples.operatorCalm; s.swapUsedMB = 6000
        XCTAssertTrue(MoveAdvisor.isShort(s, Samples.config()))
        s.swapUsedMB = 100
        XCTAssertFalse(MoveAdvisor.isShort(s, Samples.config()))
    }

    func testTargetMustHoldTheApp() {
        // Only a Mac with 1,000 MB of headroom is available; the 1,805 MB app does not fit, the 440 MB one does.
        let small = HostSample(name: "small", totalMB: 16384, freeMB: 8192 + 1000)
        let running = scored(["com.anthropic.claudefordesktop", "de.tutao.tutanota"])
        let prop = MoveAdvisor.propose(from: Samples.operatorPressured, running: running, others: [small], config: Samples.config())
        XCTAssertEqual(prop?.app.key, "de.tutao.tutanota")
    }

    func testThrottle() {
        var t = OfferThrottle()
        XCTAssertTrue(t.shouldOffer("a", now: 0))
        XCTAssertFalse(t.shouldOffer("a", now: 3599))
        XCTAssertTrue(t.shouldOffer("a", now: 3600))
        XCTAssertTrue(t.shouldOffer("b", now: 10))
        t.neverOffer("a")
        XCTAssertFalse(t.shouldOffer("a", now: 100_000))
    }
}
