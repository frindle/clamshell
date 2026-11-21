import XCTest
import Foundation
import DeskPlacer
import DeskProtocol
@testable import DeskCLICore

final class MemTests: XCTestCase {
    let claude = "com.anthropic.claudefordesktop"

    func bigApps() -> [AppInfo] {
        [
            appInfo(claude, "Claude", 1800),
            appInfo("com.brave.Browser", "Brave", 2900),
            appInfo("com.tinyspeck.slackmacgap", "Slack", 1100),
            appInfo("io.darkbloom.node", "DarkbloomNode", 1500),
            appInfo("com.apple.Terminal", "Terminal", 400),
            appInfo("com.frindle.clamshell", "Clamshell", 300),
        ]
    }

    func testReportsPressureSwapAndMovableAppsBiggestFirst() {
        let r = Rig(apps: bigApps())
        r.peer()
        XCTAssertEqual(r.run("mem"), ExitCode.ok)
        let t = r.out.text
        XCTAssertTrue(t.contains("alpha (this Mac)"), t)
        XCTAssertTrue(t.contains("memory pressure: green"), t)
        XCTAssertTrue(t.contains("swap used:"), t)
        XCTAssertTrue(t.contains("Darkbloom 2.0 GB from the rules file"), t)
        let brave = t.range(of: "Brave"), claude = t.range(of: "Claude")
        XCTAssertNotNil(brave); XCTAssertNotNil(claude)
        XCTAssertTrue(brave!.lowerBound < claude!.lowerBound, "biggest first")
        XCTAssertTrue(t.contains("beta"), t)
    }

    func testDarkbloomTerminalAndClamshellNeverAppearAsMovable() {
        let r = Rig(apps: bigApps())
        r.peer()
        r.run("mem")
        let t = r.out.text
        XCTAssertFalse(t.contains("DarkbloomNode"), t)
        XCTAssertFalse(t.contains("Terminal"), t)
        XCTAssertFalse(t.contains("Clamshell"), t)
        // Untested restore means pinned, so Slack is not listed either.
        XCTAssertFalse(t.contains("Slack"), t)
    }

    func testSuggestsAMoveWhenShortOfMemory() {
        let r = Rig(localPressureLevel: 2, swapMB: 6000, apps: [appInfo(claude, "Claude", 1800)])
        r.peer()
        XCTAssertEqual(r.run("mem"), ExitCode.ok)
        let t = r.out.text
        XCTAssertTrue(t.contains("memory pressure: yellow"), t)
        XCTAssertTrue(t.contains("move Claude (1.8 GB) to beta"), t)
        XCTAssertTrue(r.apps.quitRequests.isEmpty, "mem is read-only")
        XCTAssertTrue(r.remote.performed.isEmpty)
    }

    func testNoSuggestionWhenNotShort() {
        let r = Rig(apps: [appInfo(claude, "Claude", 1800)])
        r.peer()
        r.run("mem")
        XCTAssertTrue(r.out.text.contains("not short of memory"), r.out.text)
    }

    func testNoSuggestionWhenTheOtherMacIsUnderPressure() {
        let r = Rig(localPressureLevel: 4, apps: [appInfo(claude, "Claude", 1800)])
        r.peer(pressure: .yellow)
        r.run("mem")
        XCTAssertTrue(r.out.text.contains("no app can move"), r.out.text)
    }

    func testStalePeerReportIsNotShown() {
        let r = Rig()
        r.peer(age: 100, apps: [appInfo(claude, "Claude", 1800)])
        XCTAssertEqual(r.run("mem"), ExitCode.ok)
        XCTAssertTrue(r.out.text.contains("too old"), r.out.text)
    }

    func testFootprintNotMeasuredIsSaid() {
        let r = Rig()
        r.files.files = [:]
        XCTAssertEqual(r.run("mem"), ExitCode.ok)
        XCTAssertTrue(r.out.text.contains("not measured"), r.out.text)
    }

    func testUnreadableMemoryIsAnError() {
        let r = Rig()
        r.memory.error = DeskError("no sysctl")
        XCTAssertEqual(r.run("mem"), ExitCode.failure)
        XCTAssertTrue(r.out.errorText.contains("no sysctl"), r.out.errorText)
    }

    func testMemTakesNoArguments() {
        XCTAssertEqual(Rig().run("mem", "extra"), ExitCode.usage)
    }

    func testPressureFromTheKernelLevelAndThePercentFallback() {
        func p(_ vm: Int?, _ pct: Int) -> MemoryPressure {
            MemoryReading(totalMB: 1, freeMB: 1, swapUsedMB: 0, levelPercent: pct, vmPressureLevel: vm).pressure
        }
        XCTAssertEqual(p(1, 5), .green)
        XCTAssertEqual(p(2, 90), .yellow)
        XCTAssertEqual(p(4, 90), .red)
        XCTAssertEqual(p(nil, 60), .green)
        XCTAssertEqual(p(nil, 15), .yellow)
        XCTAssertEqual(p(nil, 3), .red)
    }

    func testSizeText() {
        XCTAssertEqual(Text.mb(512), "512 MB")
        XCTAssertEqual(Text.mb(1800), "1.8 GB")
        XCTAssertEqual(Text.mb(6714), "6.6 GB")
        XCTAssertEqual(Text.mb(-2048), "-2.0 GB")
    }
}
