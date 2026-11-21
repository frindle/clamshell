import XCTest
import DeskProtocol
@testable import DeskHost

final class ClassifierTests: XCTestCase {
    func testTable() {
        let rows: [(String?, String?, Int, WindowKind)] = [
            ("AXWindow", "AXStandardWindow", 0, .main),
            ("AXWindow", "AXDialog", 0, .main),
            ("AXWindow", "AXFloatingWindow", 3, .main),
            ("AXWindow", "AXSystemDialog", 8, .main),
            ("AXWindow", "AXSystemDialog", 101, .other),
            ("AXWindow", "AXSystemFloatingWindow", 3, .other),
            ("AXWindow", "AXUnknown", 0, .main),
            ("AXWindow", nil, 3, .main),
            ("AXWindow", nil, 25, .other),
            ("AXWindow", nil, 101, .menu),
            ("AXWindow", nil, 200, .tooltip),
            ("AXSheet", nil, 0, .sheet),
            ("AXSheet", "AXStandardWindow", 8, .sheet),
            ("AXPopover", nil, 101, .popover),
            ("AXMenu", nil, 0, .menu),
            ("AXMenuItem", nil, 101, .menu),
            ("AXHelpTag", nil, 0, .tooltip),
            ("AXScrollArea", nil, 0, .other),
            (nil, nil, 0, .other),
            (nil, nil, 24, .other),
            (nil, nil, 101, .menu),
            (nil, nil, 150, .menu),
            (nil, nil, 200, .tooltip),
            (nil, nil, 499, .tooltip),
            (nil, nil, 500, .other),
            (nil, nil, 1000, .other),
            (nil, nil, -5, .other),
        ]
        for (role, sub, level, want) in rows {
            XCTAssertEqual(WindowClassifier.classify(role: role, subrole: sub, level: level), want,
                           "role \(role ?? "nil") subrole \(sub ?? "nil") level \(level)")
        }
    }

    func testChildKinds() {
        XCTAssertTrue(WindowClassifier.isChildKind(.sheet))
        XCTAssertTrue(WindowClassifier.isChildKind(.popover))
        XCTAssertTrue(WindowClassifier.isChildKind(.menu))
        XCTAssertTrue(WindowClassifier.isChildKind(.tooltip))
        XCTAssertFalse(WindowClassifier.isChildKind(.main))
        XCTAssertFalse(WindowClassifier.isChildKind(.other))
    }
}

final class RouterTests: XCTestCase {
    func caps(_ a: Bool, _ b: Bool, _ c: Bool) -> InputCapabilities {
        InputCapabilities(frontmostOnHostedDisplay: a, perProcessEventAvailable: b, accessibilityTrusted: c)
    }

    func testPlanOrder() {
        XCTAssertEqual(InputRouter.candidates(event: .pointerButton, capabilities: caps(true, true, true)),
                       [.virtualDisplayGlobal, .perProcessEvent, .accessibility])
    }

    func testAccessibilityOnlyForClicksAndMenuPicks() {
        let c = caps(false, false, true)
        XCTAssertEqual(InputRouter.candidates(event: .pointerButton, capabilities: c), [.accessibility])
        XCTAssertEqual(InputRouter.candidates(event: .menuPick, capabilities: c), [.accessibility])
        for e: InputEventKind in [.pointerMove, .key, .scroll] {
            XCTAssertEqual(InputRouter.candidates(event: e, capabilities: c), [], "\(e)")
        }
    }

    func testRoutesNeedTheirConditions() {
        XCTAssertEqual(InputRouter.candidates(event: .key, capabilities: caps(false, true, true)), [.perProcessEvent])
        XCTAssertEqual(InputRouter.candidates(event: .key, capabilities: caps(true, false, false)), [.virtualDisplayGlobal])
        XCTAssertEqual(InputRouter.candidates(event: .key, capabilities: caps(false, false, false)), [])
    }

    func testPreferenceMovesARouteFirstOnlyIfViable() {
        XCTAssertEqual(InputRouter.candidates(event: .pointerButton, capabilities: caps(true, true, true), preference: .prefer(.perProcessEvent)),
                       [.perProcessEvent, .virtualDisplayGlobal, .accessibility])
        XCTAssertEqual(InputRouter.candidates(event: .key, capabilities: caps(true, true, true), preference: .prefer(.accessibility)),
                       [.virtualDisplayGlobal, .perProcessEvent])
        XCTAssertEqual(InputRouter.candidates(event: .key, capabilities: caps(false, false, false), preference: .prefer(.perProcessEvent)), [])
    }
}

final class TrackerTests: XCTestCase {
    func testFirstLookAddsMainsBeforeChildren() {
        var t = WindowTracker()
        let tip = HostWindowSnapshot(windowId: 3, role: "AXHelpTag", subrole: nil, level: 200, x: 110, y: 110, width: 30, height: 10)
        let ev = t.update([tip, mainWindow(1), mainWindow(2, x: 900)])
        let ids = ev.compactMap { e -> UInt32? in if case .added(let id, _, _, _, _, _) = e { return id } else { return nil } }
        XCTAssertEqual(ids, [1, 2, 3])
        // The tooltip hangs on the frontmost ordinary window in the list.
        if case .added(_, .tooltip, let parent, _, _, let off) = ev[2] {
            XCTAssertEqual(parent, 1)
            XCTAssertEqual(off, ChildOffset(x: 10, y: 10))
        } else { XCTFail("expected tooltip add") }
        XCTAssertEqual(t.mainWindowCount, 2)
    }

    func testChildWithNoParentGetsParentZeroAndNoOffset() {
        var t = WindowTracker()
        let menu = HostWindowSnapshot(windowId: 5, role: nil, subrole: nil, level: 101)
        let ev = t.update([menu])
        guard case .added(5, .menu, 0, _, _, .none) = ev[0] else { return XCTFail("\(ev)") }
    }

    func testIdZeroIsIgnored() {
        var t = WindowTracker()
        XCTAssertTrue(t.update([mainWindow(0)]).isEmpty)
    }

    func testResetForgetsRetiredIds() {
        var t = WindowTracker()
        _ = t.update([mainWindow(1)])
        _ = t.update([])
        XCTAssertTrue(t.update([mainWindow(1)]).isEmpty)
        t.reset()
        XCTAssertEqual(t.update([mainWindow(1)]).count, 1)
    }
}
