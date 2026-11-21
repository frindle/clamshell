import XCTest
import DeskProtocol
@testable import DeskClient

final class PlacementTests: XCTestCase {
    private func win(_ local: UInt64, kind: WindowKind = .main, parent: UInt64? = nil, geometry: Geometry,
                     offset: DeskPoint? = nil) -> RemoteWindow {
        RemoteWindow(localId: local, windowId: UInt32(local), appId: 7, bundleId: "org.example.editor", kind: kind,
                     parentLocalId: parent, title: "", geometry: geometry, childOffset: offset)
    }

    private let screen = DeskRect(x: 0, y: 0, width: 1000, height: 800)

    func testSheetSitsAtItsOffsetInsideTheParent() {
        let parent = win(1, geometry: geo(0, 0, 600, 400))
        let sheet = win(2, kind: .sheet, parent: 1, geometry: geo(0, 0, 300, 150), offset: DeskPoint(x: 150, y: 0))
        let parentFrame = DeskRect(x: 100, y: 200, width: 600, height: 400)
        let f = ChildPlacement.frame(of: sheet, parent: parent, parentFrame: parentFrame, screen: screen)
        XCTAssertEqual(f, DeskRect(x: 250, y: 200, width: 300, height: 150))
    }

    func testPopoverMayHangPastTheParentEdge() {
        let parent = win(1, geometry: geo(0, 0, 400, 300))
        let pop = win(2, kind: .popover, parent: 1, geometry: geo(0, 0, 200, 150), offset: DeskPoint(x: 350, y: 100))
        let parentFrame = DeskRect(x: 100, y: 100, width: 400, height: 300)
        let f = ChildPlacement.frame(of: pop, parent: parent, parentFrame: parentFrame, screen: screen)
        XCTAssertEqual(f.minX, 450)
        XCTAssertEqual(f.maxX, 650)
        XCTAssertGreaterThan(f.maxX, parentFrame.maxX)
    }

    func testMenuNegativeOffsetIsAllowedAboveTheParent() {
        let parent = win(1, geometry: geo(0, 0, 400, 300))
        let menu = win(2, kind: .menu, parent: 1, geometry: geo(0, 0, 200, 100), offset: DeskPoint(x: 10, y: -50))
        let parentFrame = DeskRect(x: 100, y: 100, width: 400, height: 300)
        let f = ChildPlacement.frame(of: menu, parent: parent, parentFrame: parentFrame, screen: screen)
        XCTAssertEqual(f.minY, 50)
    }

    func testMenuNearTheScreenEdgeIsShiftedNotResized() {
        let parent = win(1, geometry: geo(0, 0, 400, 300))
        let menu = win(2, kind: .menu, parent: 1, geometry: geo(0, 0, 200, 100), offset: DeskPoint(x: 300, y: 250))
        let parentFrame = DeskRect(x: 700, y: 650, width: 400, height: 300)
        let f = ChildPlacement.frame(of: menu, parent: parent, parentFrame: parentFrame, screen: screen)
        XCTAssertEqual(f.size, DeskSize(width: 200, height: 100))
        XCTAssertEqual(f.maxX, 1000)
        XCTAssertEqual(f.maxY, 800)
    }

    func testSheetIsNotShiftedOntoTheScreen() {
        let parent = win(1, geometry: geo(0, 0, 400, 300))
        let sheet = win(2, kind: .sheet, parent: 1, geometry: geo(0, 0, 200, 100), offset: DeskPoint(x: 300, y: 250))
        let parentFrame = DeskRect(x: 700, y: 650, width: 400, height: 300)
        let f = ChildPlacement.frame(of: sheet, parent: parent, parentFrame: parentFrame, screen: screen)
        XCTAssertEqual(f.origin, DeskPoint(x: 1000, y: 900))
    }

    func testStretchedParentScalesTheChild() {
        let parent = win(1, geometry: geo(0, 0, 400, 300))
        let tip = win(2, kind: .tooltip, parent: 1, geometry: geo(0, 0, 100, 40), offset: DeskPoint(x: 100, y: 100))
        let parentFrame = DeskRect(x: 0, y: 0, width: 800, height: 600)
        let f = ChildPlacement.frame(of: tip, parent: parent, parentFrame: parentFrame, screen: screen)
        XCTAssertEqual(f, DeskRect(x: 200, y: 200, width: 200, height: 80))
    }

    func testBehaviorPerKind() {
        XCTAssertTrue(ChildPlacement.behavior(for: .tooltip).ignoresMouse)
        XCTAssertFalse(ChildPlacement.behavior(for: .tooltip).becomesKey)
        XCTAssertFalse(ChildPlacement.behavior(for: .menu).becomesKey)
        XCTAssertTrue(ChildPlacement.behavior(for: .sheet).becomesKey)
        XCTAssertFalse(ChildPlacement.behavior(for: .sheet).keepsOnScreen)
        XCTAssertTrue(ChildPlacement.behavior(for: .popover).keepsOnScreen)
    }

    func testSubmenuFollowsItsMenuThroughTheChain() {
        let top = win(1, geometry: geo(0, 0, 400, 300))
        let menu = win(2, kind: .menu, parent: 1, geometry: geo(0, 0, 100, 100), offset: DeskPoint(x: 10, y: 20))
        let sub = win(3, kind: .menu, parent: 2, geometry: geo(0, 0, 80, 60), offset: DeskPoint(x: 100, y: 5))
        let all: [UInt64: RemoteWindow] = [1: top, 2: menu, 3: sub]
        let f = ChildPlacement.resolve(sub, windows: { all[$0] }, topLevelFrame: { $0 == 1 ? DeskRect(x: 50, y: 50, width: 400, height: 300) : nil }, screen: screen)
        XCTAssertEqual(f, DeskRect(x: 160, y: 75, width: 80, height: 60))
    }

    func testBrokenOrLoopingChainsGiveNil() {
        let a = win(2, kind: .menu, parent: 3, geometry: geo(0, 0, 10, 10), offset: DeskPoint(x: 0, y: 0))
        let b = win(3, kind: .menu, parent: 2, geometry: geo(0, 0, 10, 10), offset: DeskPoint(x: 0, y: 0))
        let all: [UInt64: RemoteWindow] = [2: a, 3: b]
        XCTAssertNil(ChildPlacement.resolve(a, windows: { all[$0] }, topLevelFrame: { _ in nil }, screen: screen))
        let orphan = win(4, kind: .menu, parent: 99, geometry: geo(0, 0, 10, 10))
        XCTAssertNil(ChildPlacement.resolve(orphan, windows: { all[$0] }, topLevelFrame: { _ in nil }, screen: screen))
    }

    func testShiftedAlignsAnOversizeSideToTheEdge() {
        let r = DeskRect(x: 500, y: 500, width: 1200, height: 100)
        let s = ChildPlacement.shifted(r, into: screen)
        XCTAssertEqual(s.minX, 0)
        XCTAssertEqual(s.minY, 500)
    }

    func testChildOffsetFromCHILD_WINDOWReachesTheModel() {
        let h = Harness()
        h.startWithWindow()
        h.host.addWindow(HostWindow(id: 120, appId: 7, kind: .popover, parentId: 100, title: "", geometry: geo(0, 0, 100, 80), offset: (30, 40)))
        let child = h.conn.model.liveWindows.first(where: { $0.windowId == 120 })
        XCTAssertEqual(child?.childOffset, DeskPoint(x: 30, y: 40))
        XCTAssertEqual(child?.parentLocalId, h.window?.localId)
    }

    func testClosingTheParentClosesItsChildrenFirst() {
        let h = Harness()
        h.startWithWindow()
        h.host.addWindow(HostWindow(id: 121, appId: 7, kind: .sheet, parentId: 100, title: "Sheet", geometry: geo(0, 0, 100, 80), offset: (0, 0)))
        let parentLocal = h.conn.model.localId(forWindowId: 100) ?? 0
        let childLocal = h.conn.model.localId(forWindowId: 121) ?? 0
        h.log.clear()
        h.host.closeWindow(100)
        XCTAssertEqual(h.log.closed(), [childLocal, parentLocal])
    }
}

final class ResizeTests: XCTestCase {
    private let config = ResizeConfig()
    private let host = DeskSize(width: 800, height: 600)

    func testFirstResizeIsSentAtOnceAndStretches() {
        var st = ResizeState()
        let a = ResizePolicy.userResized(&st, to: DeskSize(width: 900, height: 700), hostSize: host, now: 10, config: config)
        XCTAssertEqual(a, .send(DeskSize(width: 900, height: 700)))
        XCTAssertTrue(st.isStretching)
    }

    func testNoChangeSendsNothing() {
        var st = ResizeState()
        let a = ResizePolicy.userResized(&st, to: DeskSize(width: 800.5, height: 600), hostSize: host, now: 10, config: config)
        XCTAssertEqual(a, .none)
        XCTAssertFalse(st.isStretching)
    }

    func testADragIsCoalescedAndTheNewestSizeIsSentLast() {
        var st = ResizeState()
        _ = ResizePolicy.userResized(&st, to: DeskSize(width: 810, height: 600), hostSize: host, now: 10, config: config)
        let a = ResizePolicy.userResized(&st, to: DeskSize(width: 830, height: 600), hostSize: host, now: 10.01, config: config)
        guard case .sendLater(let after) = a else { return XCTFail("expected sendLater") }
        XCTAssertEqual(after, 0.03, accuracy: 0.0001)
        XCTAssertNil(ResizePolicy.flushDue(&st, now: 10.02, config: config))
        XCTAssertEqual(ResizePolicy.flushDue(&st, now: 10.05, config: config), DeskSize(width: 830, height: 600))
    }

    func testStretchesUntilTheHostCatchesUp() {
        var st = ResizeState()
        _ = ResizePolicy.userResized(&st, to: DeskSize(width: 810, height: 600), hostSize: host, now: 10, config: config)
        _ = ResizePolicy.userResized(&st, to: DeskSize(width: 830, height: 600), hostSize: host, now: 10.05, config: config)
        XCTAssertEqual(ResizePolicy.hostResized(&st, to: DeskSize(width: 810, height: 600), config: config), .stillStretching)
        XCTAssertTrue(st.isStretching)
        XCTAssertEqual(ResizePolicy.hostResized(&st, to: DeskSize(width: 830, height: 600), config: config), .caughtUp)
        XCTAssertFalse(st.isStretching)
    }

    func testHostChoosingAnotherSizeIsAdopted() {
        var st = ResizeState()
        _ = ResizePolicy.userResized(&st, to: DeskSize(width: 100, height: 100), hostSize: host, now: 10, config: ResizeConfig(minSize: DeskSize(width: 10, height: 10)))
        XCTAssertEqual(ResizePolicy.hostResized(&st, to: DeskSize(width: 320, height: 240), config: config), .adopted)
        XCTAssertFalse(st.isStretching)
    }

    func testHostMovingByItselfIsAdopted() {
        var st = ResizeState()
        XCTAssertEqual(ResizePolicy.hostResized(&st, to: DeskSize(width: 500, height: 500), config: config), .adopted)
    }

    func testSilentHostTimesOut() {
        var st = ResizeState()
        _ = ResizePolicy.userResized(&st, to: DeskSize(width: 900, height: 700), hostSize: host, now: 10, config: config)
        XCTAssertFalse(ResizePolicy.expired(&st, now: 11))
        XCTAssertEqual(ResizePolicy.nextWake(st, config: config), 11.5)
        XCTAssertTrue(ResizePolicy.expired(&st, now: 11.5))
        XCTAssertFalse(st.isStretching)
    }

    func testSizesAreClamped() {
        let c = ResizeConfig(minSize: DeskSize(width: 100, height: 100), maxSize: DeskSize(width: 2000, height: 2000))
        XCTAssertEqual(ResizePolicy.clamp(DeskSize(width: 5, height: 5000), c), DeskSize(width: 100, height: 2000))
    }

    // End to end through the connection and the fake host.

    func testConnectionSendsTheSizeAndStopsStretchingWhenTheHostAnswers() {
        let h = Harness()
        h.startWithWindow()
        let local = h.window?.localId ?? 0
        h.conn.userResized(localId: local, to: DeskSize(width: 900, height: 700))
        XCTAssertEqual(h.host.resizeRequests.count, 1)
        XCTAssertEqual(h.conn.model.window(localId: local)?.resize.isStretching, true)
        h.advance(0.2)
        XCTAssertEqual(h.conn.model.window(localId: local)?.resize.isStretching, false)
        XCTAssertEqual(h.window?.hostSize, DeskSize(width: 900, height: 700))
        XCTAssertEqual(h.log.changes(.resized(.caughtUp)).count, 1)
    }

    func testConnectionGivesUpWhenTheHostNeverAnswers() {
        let h = Harness()
        h.host.resizeLatency = nil
        h.startWithWindow()
        let local = h.window?.localId ?? 0
        h.conn.userResized(localId: local, to: DeskSize(width: 900, height: 700))
        h.advance(1)
        XCTAssertEqual(h.conn.model.window(localId: local)?.resize.isStretching, true)
        h.advance(1)
        XCTAssertEqual(h.conn.model.window(localId: local)?.resize.isStretching, false)
        XCTAssertEqual(h.log.changes(.resizeTimedOut).count, 1)
    }

    func testConnectionAdoptsTheHostsMinimumSize() {
        let h = Harness()
        h.host.minSize = (width: 400, height: 300)
        h.startWithWindow()
        let local = h.window?.localId ?? 0
        h.conn.userResized(localId: local, to: DeskSize(width: 200, height: 200))
        h.advance(0.3)
        XCTAssertEqual(h.window?.hostSize, DeskSize(width: 400, height: 300))
        XCTAssertEqual(h.conn.model.window(localId: local)?.resize.isStretching, false)
    }
}
