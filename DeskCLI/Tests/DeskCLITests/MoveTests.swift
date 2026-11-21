import XCTest
import DeskPlacer
import DeskProtocol
@testable import DeskCLICore

final class MoveTests: XCTestCase {
    let claude = "com.anthropic.claudefordesktop"
    let brave = "com.brave.Browser"
    let firefox = "org.mozilla.firefox"

    /// Claude desktop runs here, beta is green with room.
    func rig(running: [String]? = nil) -> Rig {
        let r = Rig()
        r.peer()
        r.apps.running = Set(running ?? [claude])
        return r
    }

    // MARK: dry run

    func testDryRunIsTheDefaultAndChangesNothing() {
        let r = rig()
        r.apps.titles[claude] = ["Main"]
        XCTAssertEqual(r.run("move", "claude", "beta"), ExitCode.ok)
        XCTAssertTrue(r.out.text.contains("Dry run"), r.out.text)
        XCTAssertTrue(r.out.text.contains("--yes"))
        XCTAssertTrue(r.apps.quitRequests.isEmpty)
        XCTAssertTrue(r.remote.performed.isEmpty)
        XCTAssertTrue(r.defaults.sets.isEmpty)
        XCTAssertTrue(r.launcher.launches.isEmpty)
    }

    func testWarningShowsWhatIsLostAndAtRisk() {
        let r = rig()
        XCTAssertEqual(r.run("move", "claude", "beta"), ExitCode.ok)
        let t = r.out.text
        XCTAssertTrue(t.contains("Will be lost"), t)
        XCTAssertTrue(t.contains("Windows you had closed may open again"), t)
        XCTAssertTrue(t.contains("At risk"), t)
        XCTAssertTrue(t.contains("draft"), t)
        XCTAssertTrue(t.contains("4 to 8 seconds"), t)
    }

    func testBrowserWarningNamesTheViewReloadAndTheStartupSetting() {
        let r = rig(running: [brave])
        XCTAssertEqual(r.run("move", "Brave", "beta"), ExitCode.ok)
        let t = r.out.text
        XCTAssertTrue(t.contains("default view"), t)
        XCTAssertTrue(t.contains("startup setting is not changed"), t)
        XCTAssertTrue(t.contains("keychain"), t)
    }

    func testUnknownUnsavedStateIsTreatedAsAtRisk() {
        let r = rig()
        r.apps.editedKnown = false
        XCTAssertEqual(r.run("move", "claude", "beta"), ExitCode.ok)
        XCTAssertTrue(r.out.text.contains("cannot read which windows have unsaved changes"), r.out.text)
    }

    func testCallsAndTransfersNoteWhenTheProbeIsBlind() {
        let r = rig()
        r.probe.sees = false
        XCTAssertEqual(r.run("move", "claude", "beta"), ExitCode.ok)
        XCTAssertTrue(r.out.text.contains("cannot see calls or transfers"), r.out.text)
    }

    // MARK: a real move

    func testYesQuitsThenStartsThenClosesExtraWindows() {
        let r = rig()
        r.apps.titles[claude] = ["Main"]
        XCTAssertEqual(r.run("move", "claude", "beta", "--yes"), ExitCode.ok)
        XCTAssertEqual(r.apps.quitRequests, [claude])
        XCTAssertEqual(r.remote.performed, [.start(arguments: []), .closeExtraWindows(keep: ["Main"])])
        XCTAssertTrue(r.launcher.launches.isEmpty)
    }

    func testExtraWindowsAreHiddenWhenTitlesCannotBeRead() {
        let r = rig()
        r.apps.titlesKnown = false
        XCTAssertEqual(r.run("move", "claude", "beta", "--yes"), ExitCode.ok)
        XCTAssertEqual(r.remote.performed.last, .hideApp)
    }

    func testChromiumStartsWithTheOneTimeRestoreFlag() {
        let r = rig(running: [brave])
        XCTAssertEqual(r.run("move", "Brave", "beta", "--yes"), ExitCode.ok)
        XCTAssertEqual(r.remote.performed, [.copyProfile, .start(arguments: ["--restore-last-session"])])
        XCTAssertTrue(r.defaults.sets.isEmpty, "the user's startup settings are never changed")
    }

    func testFirefoxUsesTheOneTimePreferenceNotAFlag() {
        let r = rig(running: [firefox])
        XCTAssertEqual(r.run("move", "Firefox", "beta", "--yes"), ExitCode.ok)
        XCTAssertEqual(r.remote.performed, [.copyProfile, .firefoxResumeOnce, .start(arguments: [])])
    }

    func testWaitsForASlowQuit() {
        let r = rig()
        r.apps.pollsBeforeExit = 3
        XCTAssertEqual(r.run("move", "claude", "beta", "--yes"), ExitCode.ok)
        XCTAssertGreaterThan(r.clock.slept, 0)
        XCTAssertFalse(r.remote.performed.isEmpty)
    }

    func testAnAppThatWillNotQuitIsNeverForced() {
        let r = rig()
        r.apps.quitWorks = false
        XCTAssertEqual(r.run("move", "claude", "beta", "--yes"), ExitCode.failure)
        XCTAssertGreaterThanOrEqual(r.clock.slept, 30)
        XCTAssertTrue(r.remote.performed.isEmpty)
        XCTAssertTrue(r.out.errorText.contains("Nothing was forced"), r.out.errorText)
        XCTAssertTrue(r.launcher.launches.isEmpty)
    }

    func testFailedStartOpensTheAppAgainHere() {
        let r = rig()
        r.remote.failOn = { if case .start = $0 { return true } else { return false } }
        XCTAssertEqual(r.run("move", "claude", "beta", "--yes"), ExitCode.failure)
        XCTAssertEqual(r.launcher.launches.count, 1)
        XCTAssertEqual(r.launcher.launches[0].0, .app(bundleId: claude))
        XCTAssertTrue(r.out.errorText.contains("opened again"), r.out.errorText)
    }

    func testFailureAfterTheStartNeverStartsASecondCopy() {
        let r = rig()
        r.remote.failOn = { if case .closeExtraWindows = $0 { return true } else { return false } }
        XCTAssertEqual(r.run("move", "claude", "beta", "--yes"), ExitCode.failure)
        XCTAssertTrue(r.launcher.launches.isEmpty)
        XCTAssertTrue(r.out.errorText.contains("already running on beta"), r.out.errorText)
    }

    func testWithoutTheClientNothingIsQuit() {
        let r = rig()
        var p = r.ports
        p.remote = NoRemoteLauncher()
        XCTAssertEqual(Cli.run(["move", "claude", "beta", "--yes"], ports: p), ExitCode.refused)
        XCTAssertTrue(r.apps.quitRequests.isEmpty)
        // The dry run still shows the warning and says what is missing.
        r.out.lines = []
        XCTAssertEqual(Cli.run(["move", "claude", "beta"], ports: p), ExitCode.ok)
        XCTAssertTrue(r.out.text.contains("Cannot be done yet"), r.out.text)
        XCTAssertTrue(r.out.text.contains("Desk client"), r.out.text)
    }

    // MARK: refusals

    func assertRefused(_ r: Rig, _ args: [String], contains: String, file: StaticString = #filePath, line: UInt = #line) {
        for extra in [[], ["--yes"]] {
            r.out.errors = []
            let code = Cli.run(args + extra, ports: r.ports)
            XCTAssertEqual(code, ExitCode.refused, "args \(args + extra)", file: file, line: line)
            XCTAssertTrue(r.out.errorText.contains(contains), r.out.errorText, file: file, line: line)
            XCTAssertTrue(r.apps.quitRequests.isEmpty, "nothing may be quit", file: file, line: line)
            XCTAssertTrue(r.remote.performed.isEmpty, file: file, line: line)
        }
    }

    func testNeverMovesToAMacUnderMemoryPressure() {
        for pressure in [MemoryPressure.yellow, .red] {
            let r = rig()
            r.peer(pressure: pressure)
            assertRefused(r, ["move", "claude", "beta"], contains: "memory pressure")
        }
    }

    func testRefusesATargetThatHasNotReportedOrIsStale() {
        let r = rig()
        r.peers.list = []
        assertRefused(r, ["move", "claude", "beta"], contains: "has not reported")
        let s = rig()
        s.peer(age: 100)
        assertRefused(s, ["move", "claude", "beta"], contains: "too old")
    }

    func testRefusesATargetWithoutRoom() {
        let r = rig()
        r.peer(free: 11_000)
        assertRefused(r, ["move", "claude", "beta"], contains: "enough free memory")
    }

    func testNeverMovesDarkbloomTerminalOrClamshell() {
        let ids = ["io.darkbloom.node", "darkbloom", "com.apple.Terminal", "Terminal", "com.frindle.clamshell", "Clamshell"]
        for id in ids {
            let r = rig(running: [id])
            assertRefused(r, ["move", id, "beta"], contains: "never moved")
        }
    }

    func testRefusesAnAppWhoseRestoreIsUntested() {
        let r = rig(running: ["com.tinyspeck.slackmacgap"])
        assertRefused(r, ["move", "Slack", "beta"], contains: "not been tested")
    }

    func testRefusesAnAppThatNeverMoves() {
        let r = rig(running: ["bloomgauge"])
        assertRefused(r, ["move", "bloomgauge", "beta"], contains: "never moves")
    }

    func testRefusesWhileBlocked() {
        let r = rig()
        r.probe.blocked[claude] = [.inCall]
        assertRefused(r, ["move", "claude", "beta"], contains: "call")
    }

    func testRefusesWithUnsavedChangesUnlessToldToMoveAnyway() {
        let r = rig()
        r.apps.edited[claude] = ["Budget draft"]
        assertRefused(r, ["move", "claude", "beta"], contains: "Budget draft")
        XCTAssertEqual(r.run("move", "claude", "beta", "--move-anyway"), ExitCode.ok)
        XCTAssertTrue(r.out.text.contains("Budget draft"), r.out.text)
        XCTAssertTrue(r.out.text.contains("At risk"), r.out.text)
    }

    func testRefusesTheSameMacAnAppNotRunningHereAndOneRunningElsewhere() {
        let r = rig()
        assertRefused(r, ["move", "claude", "alpha"], contains: "this Mac")
        let n = rig(running: [])
        assertRefused(n, ["move", "claude", "beta"], contains: "not running")
        let e = rig(running: [])
        e.peer(apps: [appInfo(claude, "Claude", 1800)])
        assertRefused(e, ["move", "claude", "beta"], contains: "runs on beta")
    }

    func testRulesHoldAgainstAMove() {
        let hw = rig(running: ["com.hnc.Discord"])
        // Discord is untested too, but the hardware need is reported as well.
        hw.out.errors = []
        XCTAssertEqual(hw.run("move", "Discord", "beta"), ExitCode.refused)
        XCTAssertTrue(hw.out.errorText.contains("needs camera"), hw.out.errorText)

        let home = rig(running: [brave])
        assertRefused(home, ["move", "Brave", "gamma"], contains: "lives on beta")
    }

    func testUnknownAppAndBadArguments() {
        let r = rig()
        XCTAssertEqual(r.run("move", "no such app", "beta"), ExitCode.refused)
        XCTAssertEqual(r.run("move", "claude"), ExitCode.usage)
        XCTAssertEqual(r.run("move", "claude", "beta", "--force"), ExitCode.usage)
    }

    // MARK: planner details

    func ctx(_ r: Rig, extra: [AppProfile]) throws -> DeskContext {
        DeskContext(ports: r.ports, config: try RulesFile.parse(rulesText), thisMac: "alpha", catalog: E12a.catalog() + extra)
    }

    func testMacOSRestoreAppGetsItsOwnSettingAndTheSavedStateCopied() throws {
        let r = rig(running: ["com.apple.TextEdit"])
        r.defaults.keeps["com.apple.TextEdit"] = false
        let c = try ctx(r, extra: [AppProfile(key: "com.apple.TextEdit", name: "TextEdit", residentMB: 100, kind: .a, restore: .passed)])
        XCTAssertEqual(MoveCommand.move("TextEdit", to: "beta", yes: true, moveAnyway: false, ctx: c), ExitCode.ok)
        XCTAssertEqual(r.defaults.sets.count, 1)
        XCTAssertEqual(r.defaults.sets[0].0, "com.apple.TextEdit")
        XCTAssertEqual(r.defaults.sets[0].1, true)
        XCTAssertEqual(r.apps.quitRequests, ["com.apple.TextEdit"])
        XCTAssertEqual(r.remote.performed.first, .copySavedState)
        XCTAssertTrue(r.out.text.contains("NSQuitAlwaysKeepsWindows"), r.out.text)
    }

    func testRestoreSettingAlreadyOnIsLeftAlone() throws {
        let r = rig(running: ["com.apple.TextEdit"])
        r.defaults.keeps["com.apple.TextEdit"] = true
        let c = try ctx(r, extra: [AppProfile(key: "com.apple.TextEdit", name: "TextEdit", residentMB: 100, kind: .a, restore: .passed)])
        XCTAssertEqual(MoveCommand.move("TextEdit", to: "beta", yes: true, moveAnyway: false, ctx: c), ExitCode.ok)
        XCTAssertTrue(r.defaults.sets.isEmpty)
    }

    func testTerminalKindWarnsAboutTheWorkingFolder() throws {
        let r = rig(running: ["com.example.shell"])
        let c = try ctx(r, extra: [AppProfile(key: "com.example.shell", name: "Shell", residentMB: 100, kind: .f)])
        XCTAssertEqual(MoveCommand.move("Shell", to: "beta", yes: false, moveAnyway: false, ctx: c), ExitCode.ok)
        XCTAssertTrue(r.out.text.contains("working folder"), r.out.text)
        XCTAssertTrue(r.out.text.contains("tmux"), r.out.text)
    }

    func testClaudeCodeKindWarnsAboutAToolCallInFlight() throws {
        let r = rig(running: ["com.example.cc"])
        let c = try ctx(r, extra: [AppProfile(key: "com.example.cc", name: "Code", residentMB: 100, kind: .g)])
        XCTAssertEqual(MoveCommand.move("Code", to: "beta", yes: false, moveAnyway: false, ctx: c), ExitCode.ok)
        XCTAssertTrue(r.out.text.contains("tool call in flight"), r.out.text)
    }

    func testE12aOverlayLeavesPlacerCatalogAlone() {
        XCTAssertEqual(AppCatalog.profile(brave)?.restore, .untested)
        XCTAssertEqual(E12a.catalog().first { $0.key == brave }?.restore, .passed)
        XCTAssertEqual(E12a.catalog().first { $0.key == "com.tinyspeck.slackmacgap" }?.restore, .untested)
    }
}
