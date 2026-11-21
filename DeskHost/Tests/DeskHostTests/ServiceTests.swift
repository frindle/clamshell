import XCTest
import DeskProtocol
@testable import DeskHost

final class ServiceTests: XCTestCase {
    let bundle = "org.example.browser"

    func launch(_ op: OperatorConnection, _ conn: FakeConnection, request: UInt32 = 1) -> [DeskMessage] {
        op.say(.appLaunch(requestId: request, bundleId: bundle, activate: true, targets: ["https://example.org/"]))
        return conn.drain()
    }

    // MARK: launch

    func testLaunchReportsResultAndAppList() {
        let rig = Rig()
        let (conn, opt) = rig.connect(); let op = opt!
        XCTAssertEqual(conn.drain(), [.appList([])])
        let out = launch(op, conn)
        XCTAssertEqual(out.first, .appLaunchResult(requestId: 1, status: 0, appId: 1))
        guard case .appList(let apps)? = out.last else { return XCTFail("no app list") }
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].pid, 4242)
        XCTAssertTrue(apps[0].running)
        XCTAssertEqual(apps[0].name, "Browser")
        XCTAssertEqual(rig.launcher.calls.first?.targets, ["https://example.org/"])
        XCTAssertEqual(rig.launcher.calls.first?.activate, true)
    }

    func testLaunchTwiceKeepsOneSession() {
        let rig = Rig()
        let (conn, opt) = rig.connect(); let op = opt!
        _ = conn.drain()
        _ = launch(op, conn, request: 1)
        let out = launch(op, conn, request: 2)
        XCTAssertEqual(out.first, .appLaunchResult(requestId: 2, status: 0, appId: 1))
        XCTAssertEqual(rig.service.sessions.count, 1)
        // The app list did not change, so it is not sent again.
        XCTAssertEqual(out.count, 1)
    }

    func testLaunchStatuses() {
        let rig = Rig()
        rig.launcher.outcomes["missing"] = .notInstalled
        rig.launcher.outcomes["refused"] = .refused
        rig.launcher.outcomes["broken"] = .failed
        let (conn, opt) = rig.connect(); let op = opt!
        _ = conn.drain()
        for (i, (b, status)) in [("missing", UInt8(1)), ("refused", 2), ("broken", 3)].enumerated() {
            op.say(.appLaunch(requestId: UInt32(i), bundleId: b, activate: false, targets: []))
            XCTAssertEqual(conn.drain().first, .appLaunchResult(requestId: UInt32(i), status: status, appId: 0))
        }
        XCTAssertTrue(rig.service.sessions.isEmpty)
    }

    func testPolicyCanRefuseWithoutCallingLauncher() {
        let rig = Rig()
        rig.service.config.allowLaunch = { $0 != "org.example.browser" }
        let (conn, opt) = rig.connect(); let op = opt!
        _ = conn.drain()
        XCTAssertEqual(launch(op, conn).first, .appLaunchResult(requestId: 1, status: 2, appId: 0))
        XCTAssertTrue(rig.launcher.calls.isEmpty)
    }

    func testResultIsDroppedIfOperatorLeftBeforeLaunchFinished() {
        let rig = Rig()
        rig.launcher.holdCompletions = true
        let (conn, opt) = rig.connect(); let op = opt!
        _ = conn.drain()
        op.say(.appLaunch(requestId: 9, bundleId: bundle, activate: true, targets: []))
        op.close()
        rig.launcher.finish()
        XCTAssertTrue(conn.drain().isEmpty)
        XCTAssertEqual(rig.service.sessions.count, 1)   // the app still runs
    }

    // MARK: windows

    func launched() -> (Rig, FakeConnection, OperatorConnection) {
        let rig = Rig()
        let (conn, opt) = rig.connect()
        let op = opt!
        _ = conn.drain()
        _ = launch(op, conn)
        return (rig, conn, op)
    }

    func testWindowAppearsMovesResizesRetitlesAndCloses() {
        let (rig, conn, _) = launched()
        rig.windows.byPid[4242] = [mainWindow(10)]
        rig.service.pollWindows()
        let added = conn.drain()
        XCTAssertEqual(added.first, .windowAdded(windowId: 10, appId: 1, kind: .main, parentId: 0, title: "Main",
                                                  geometry: Geometry(x: 100, y: 100, width: 800, height: 600, scale: 2)))
        // The app list now says one window.
        guard case .appList(let apps)? = added.last else { return XCTFail("expected app list") }
        XCTAssertEqual(apps[0].windowCount, 1)

        rig.windows.byPid[4242] = [mainWindow(10, x: 50, y: 60)]
        rig.service.pollWindows()
        XCTAssertEqual(conn.drain(), [.windowMoved(windowId: 10, x: 50, y: 60)])

        rig.windows.byPid[4242] = [mainWindow(10, x: 50, y: 60, w: 900, h: 700)]
        rig.service.pollWindows()
        XCTAssertEqual(conn.drain(), [.windowResized(windowId: 10, width: 900, height: 700, scale: 2)])

        rig.windows.byPid[4242] = [mainWindow(10, x: 50, y: 60, w: 900, h: 700, title: "Inbox")]
        rig.service.pollWindows()
        XCTAssertEqual(conn.drain(), [.windowTitle(windowId: 10, title: "Inbox")])

        rig.windows.byPid[4242] = []
        rig.service.pollWindows()
        XCTAssertEqual(conn.drain().first, .windowClosed(windowId: 10))
    }

    func testNothingChangedSendsNothing() {
        let (rig, conn, _) = launched()
        rig.windows.byPid[4242] = [mainWindow(10)]
        rig.service.pollWindows()
        _ = conn.drain()
        rig.service.pollWindows()
        XCTAssertTrue(conn.drain().isEmpty)
    }

    func testClosedIdIsNeverAddedAgain() {
        let (rig, conn, _) = launched()
        rig.windows.byPid[4242] = [mainWindow(10)]
        rig.service.pollWindows()
        rig.windows.byPid[4242] = []
        rig.service.pollWindows()
        _ = conn.drain()
        rig.windows.byPid[4242] = [mainWindow(10)]
        rig.service.pollWindows()
        XCTAssertTrue(conn.drain().isEmpty)
    }

    func testWindowListResponse() {
        let (rig, conn, op) = launched()
        rig.windows.byPid[4242] = [mainWindow(10, w: 800, h: 600, title: "Doc")]
        rig.service.pollWindows()
        _ = conn.drain()
        op.say(.windowListRequest)
        XCTAssertEqual(conn.drain(), [.windowListResponse([WindowInfo(windowId: 10, title: "Doc", appName: "Browser", widthPx: 1600, heightPx: 1200)])])
    }

    // MARK: resize

    func testResizeRequestIsAnsweredWithTheSizeTheAppGot() {
        let (rig, conn, op) = launched()
        rig.windows.byPid[4242] = [mainWindow(10)]
        rig.service.pollWindows()
        _ = conn.drain()
        op.say(.windowResizeRequest(windowId: 10, width: 1000, height: 640))
        XCTAssertEqual(rig.resizer.calls.count, 1)
        XCTAssertEqual(conn.drain(), [.windowResized(windowId: 10, width: 1000, height: 640, scale: 2)])
        // The next look finds nothing new.
        rig.service.pollWindows()
        XCTAssertTrue(conn.drain().isEmpty)
    }

    func testResizeRequestAnsweredEvenIfAppRefuses() {
        let (rig, conn, op) = launched()
        rig.resizer.obey = false
        rig.windows.byPid[4242] = [mainWindow(10)]
        rig.service.pollWindows()
        _ = conn.drain()
        op.say(.windowResizeRequest(windowId: 10, width: 1000, height: 640))
        XCTAssertEqual(conn.drain(), [.windowResized(windowId: 10, width: 800, height: 600, scale: 2)])
    }

    func testResizeRequestForUnknownWindowIsIgnored() {
        let (rig, conn, op) = launched()
        op.say(.windowResizeRequest(windowId: 77, width: 1000, height: 640))
        XCTAssertTrue(rig.resizer.calls.isEmpty)
        XCTAssertTrue(conn.drain().isEmpty)
    }

    // MARK: child windows

    func testSheetArrivesAfterItsParentWithOffset() {
        let (rig, conn, _) = launched()
        let sheet = HostWindowSnapshot(windowId: 11, title: "Save", role: "AXSheet", subrole: nil, level: 0, x: 150, y: 120, width: 500, height: 300)
        // The sheet is listed first (it is frontmost); the parent must still be announced first.
        rig.windows.byPid[4242] = [sheet, mainWindow(10)]
        rig.service.pollWindows()
        let out = conn.drain()
        XCTAssertEqual(out[0], .windowAdded(windowId: 10, appId: 1, kind: .main, parentId: 0, title: "Main",
                                             geometry: Geometry(x: 100, y: 100, width: 800, height: 600, scale: 2)))
        XCTAssertEqual(out[1], .windowAdded(windowId: 11, appId: 1, kind: .sheet, parentId: 10, title: "Save",
                                             geometry: Geometry(x: 150, y: 120, width: 500, height: 300, scale: 2)))
        XCTAssertEqual(out[2], .childWindow(windowId: 11, parentId: 10, offsetX: 50, offsetY: 20, kind: .sheet))
    }

    func testMenuByLevelOnlyIsAChildAndCanExtendPastParent() {
        let (rig, conn, _) = launched()
        rig.windows.byPid[4242] = [mainWindow(10)]
        rig.service.pollWindows()
        _ = conn.drain()
        let menu = HostWindowSnapshot(windowId: 12, title: "", role: nil, subrole: nil, level: 101, x: 880, y: 150, width: 200, height: 300)
        rig.windows.byPid[4242] = [menu, mainWindow(10)]
        rig.service.pollWindows()
        let out = conn.drain()
        XCTAssertEqual(out[0], .windowAdded(windowId: 12, appId: 1, kind: .menu, parentId: 10, title: "",
                                             geometry: Geometry(x: 880, y: 150, width: 200, height: 300, scale: 2)))
        XCTAssertEqual(out[1], .childWindow(windowId: 12, parentId: 10, offsetX: 780, offsetY: 50, kind: .menu))
    }

    func testParentHintWins() {
        let (rig, conn, _) = launched()
        let tip = HostWindowSnapshot(windowId: 13, role: "AXHelpTag", subrole: nil, level: 200, x: 5, y: 5, width: 40, height: 20, parentHint: 11)
        rig.windows.byPid[4242] = [tip, mainWindow(10), mainWindow(11, x: 0, y: 0)]
        rig.service.pollWindows()
        let out = conn.drain()
        XCTAssertTrue(out.contains(.childWindow(windowId: 13, parentId: 11, offsetX: 5, offsetY: 5, kind: .tooltip)))
    }

    func testChildClosesBeforeParent() {
        let (rig, conn, _) = launched()
        let sheet = HostWindowSnapshot(windowId: 11, role: "AXSheet", subrole: nil, x: 120, y: 120, width: 300, height: 200)
        rig.windows.byPid[4242] = [sheet, mainWindow(10)]
        rig.service.pollWindows()
        _ = conn.drain()
        rig.windows.byPid[4242] = []
        rig.service.pollWindows()
        let closes = conn.drain().filter { if case .windowClosed = $0 { return true } else { return false } }
        XCTAssertEqual(closes, [.windowClosed(windowId: 11), .windowClosed(windowId: 10)])
    }

    // MARK: app exit

    func testAppQuitClosesWindowsAndMarksNotRunning() {
        let (rig, conn, _) = launched()
        rig.windows.byPid[4242] = [mainWindow(10)]
        rig.service.pollWindows()
        _ = conn.drain()
        rig.windows.running = []
        rig.service.pollWindows()
        let out = conn.drain()
        XCTAssertEqual(out.first, .windowClosed(windowId: 10))
        guard case .appList(let apps)? = out.last else { return XCTFail("expected app list") }
        XCTAssertEqual(apps[0].pid, -1)
        XCTAssertFalse(apps[0].running)
        XCTAssertEqual(apps[0].windowCount, 0)
    }

    // MARK: streams

    func testStreamStartFramesAndStopOnClose() {
        let (rig, conn, op) = launched()
        rig.windows.byPid[4242] = [mainWindow(10)]
        rig.service.pollWindows()
        _ = conn.drain()
        op.say(.windowStreamStart(windowId: 10))
        XCTAssertEqual(rig.streamer.started, [10])
        rig.streamer.sinks[10]?(true, 5000, [0, 0, 0, 2, 0x65, 0x88])
        XCTAssertEqual(conn.drain(), [.windowStreamFrame(windowId: 10, flags: 1, ptsMicros: 5000, nal: [0, 0, 0, 2, 0x65, 0x88])])
        rig.windows.byPid[4242] = []
        rig.service.pollWindows()
        XCTAssertEqual(rig.streamer.stopped, [10])
    }

    func testHandoffReturnStopsTheStream() {
        let (rig, conn, op) = launched()
        rig.windows.byPid[4242] = [mainWindow(10)]
        rig.service.pollWindows()
        _ = conn.drain()
        op.say(.windowStreamStart(windowId: 10))
        op.say(.handoffReturn(windowId: 10))
        XCTAssertEqual(rig.streamer.stopped, [10])
        // The window itself is still there.
        rig.windows.byPid[4242] = [mainWindow(10, x: 1, y: 1)]
        rig.service.pollWindows()
        XCTAssertEqual(conn.drain(), [.windowMoved(windowId: 10, x: 1, y: 1)])
    }

    func testStreamStartForUnknownWindowIsIgnored() {
        let (rig, _, op) = launched()
        op.say(.windowStreamStart(windowId: 99))
        XCTAssertTrue(rig.streamer.started.isEmpty)
    }

    func testTwoOperatorsShareOneStream() {
        let (rig, c1, op1) = launched()
        let (c2, op2o) = rig.connect("op2"); let op2 = op2o!
        rig.windows.byPid[4242] = [mainWindow(10)]
        rig.service.pollWindows()
        _ = c1.drain(); _ = c2.drain()
        op1.say(.windowStreamStart(windowId: 10))
        op2.say(.windowStreamStart(windowId: 10))
        XCTAssertEqual(rig.streamer.started, [10])
        XCTAssertEqual(rig.streamer.keyframeRequests, [10])
        rig.streamer.sinks[10]?(false, 1, [1])
        XCTAssertEqual(c1.drain().count, 1)
        XCTAssertEqual(c2.drain().count, 1)
        op1.close()
        XCTAssertTrue(rig.streamer.stopped.isEmpty)   // op2 still watching
        op2.close()
        XCTAssertEqual(rig.streamer.stopped, [10])
    }

    // MARK: input

    func testInputGoesToTheFirstViableRoute() {
        let (rig, _, op) = launched()
        rig.windows.byPid[4242] = [mainWindow(10)]
        rig.service.pollWindows()
        op.say(.windowInputKey(windowId: 10, macKeyCode: 0, down: true, cgEventFlags: 0))
        op.say(.windowInputMouseButton(windowId: 10, button: 0, down: true, x: 0.5, y: 0.5))
        op.say(.windowInputMouseMove(windowId: 10, x: 0.1, y: 0.2))
        op.say(.windowInputScroll(windowId: 10, dx: 0, dy: -3))
        XCTAssertEqual(rig.input.delivered.count, 4)
        XCTAssertTrue(rig.input.delivered.allSatisfy { $0.2 == .virtualDisplayGlobal && $0.1 == 10 })
    }

    func testInputFallsBackWhenARouteFails() {
        let (rig, _, op) = launched()
        rig.windows.byPid[4242] = [mainWindow(10)]
        rig.service.pollWindows()
        rig.input.failing = ["virtualDisplayGlobal"]
        op.say(.windowInputMouseButton(windowId: 10, button: 0, down: true, x: 0.5, y: 0.5))
        XCTAssertEqual(rig.input.attempts, [.virtualDisplayGlobal, .perProcessEvent])
        XCTAssertEqual(rig.input.delivered.first?.2, .perProcessEvent)
    }

    func testRoutePreferenceFromConfig() {
        let (rig, _, op) = launched()
        rig.service.config.routePreference = .prefer(.perProcessEvent)
        rig.windows.byPid[4242] = [mainWindow(10)]
        rig.service.pollWindows()
        op.say(.windowInputKey(windowId: 10, macKeyCode: 1, down: true, cgEventFlags: 0))
        XCTAssertEqual(rig.input.delivered.first?.2, .perProcessEvent)
    }

    func testInputForUnknownOrClosedWindowIsIgnored() {
        let (rig, _, op) = launched()
        rig.windows.byPid[4242] = [mainWindow(10)]
        rig.service.pollWindows()
        op.say(.windowInputKey(windowId: 99, macKeyCode: 0, down: true, cgEventFlags: 0))
        rig.windows.byPid[4242] = []
        rig.service.pollWindows()
        op.say(.windowInputKey(windowId: 10, macKeyCode: 0, down: true, cgEventFlags: 0))
        XCTAssertTrue(rig.input.attempts.isEmpty)
    }

    func testInputNotDeliveredWhenNoRouteIsViable() {
        let (rig, _, op) = launched()
        rig.windows.byPid[4242] = [mainWindow(10)]
        rig.service.pollWindows()
        rig.input.caps = InputCapabilities(frontmostOnHostedDisplay: false, perProcessEventAvailable: false, accessibilityTrusted: true)
        op.say(.windowInputKey(windowId: 10, macKeyCode: 0, down: true, cgEventFlags: 0))
        XCTAssertTrue(rig.input.attempts.isEmpty)
        op.say(.windowInputMouseButton(windowId: 10, button: 0, down: true, x: 0.5, y: 0.5))
        XCTAssertEqual(rig.input.delivered.first?.2, .accessibility)
    }

    // MARK: protocol errors

    func testMalformedKnownMessageClosesConnection() {
        let (_, conn, op) = launched()
        // WINDOW_MOVED with a 2-byte payload.
        op.receive(try! Framing.encode(type: DeskType.windowMoved.rawValue, payload: [0, 1]))
        XCTAssertTrue(conn.closed)
        XCTAssertFalse(op.isOpen)
    }

    func testOutOfRangeValueClosesConnection() {
        let (_, conn, op) = launched()
        var w = ByteWriter()
        w.u32(10); w.f32(2.5); w.f32(0.5)   // mouse x outside 0...1
        op.receive(try! Framing.encode(type: DeskType.windowInputMouseMove.rawValue, payload: w.bytes))
        XCTAssertTrue(conn.closed)
    }

    func testOversizeFrameClosesConnection() {
        let (_, conn, op) = launched()
        op.receive([0x71, 0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertTrue(conn.closed)
    }

    func testUnknownTypeIsSkipped() {
        let (rig, conn, op) = launched()
        op.receive(try! Framing.encode(type: 0xEE, payload: [1, 2, 3]))
        XCTAssertFalse(conn.closed)
        op.say(.appListRequest)
        XCTAssertEqual(conn.drain().count, 1)
        _ = rig
    }

    func testMessagesSplitAcrossReadsAreReassembled() {
        let (rig, conn, op) = launched()
        rig.windows.byPid[4242] = [mainWindow(10)]
        rig.service.pollWindows()
        _ = conn.drain()
        let bytes = try! DeskMessage.windowInputKey(windowId: 10, macKeyCode: 3, down: true, cgEventFlags: 0).encodeFrame()
        for b in bytes { op.receive([b]) }
        XCTAssertEqual(rig.input.delivered.count, 1)
    }

    func testPeerWithoutCapabilityIsClosed() {
        let rig = Rig()
        let (conn, op) = rig.connect(caps: 0)
        XCTAssertNil(op)
        XCTAssertTrue(conn.closed)
        XCTAssertTrue(conn.sent.isEmpty)
    }

    // MARK: reconnect

    func testReconnectReplaysAppsAndWindowsAsNew() {
        let (rig, c1, op1) = launched()
        rig.windows.byPid[4242] = [mainWindow(10), HostWindowSnapshot(windowId: 11, role: "AXSheet", subrole: nil, x: 120, y: 120, width: 300, height: 200)]
        rig.service.pollWindows()
        op1.say(.windowStreamStart(windowId: 10))
        _ = c1.drain()

        // The link drops. The app keeps running; the stream stops.
        op1.close()
        XCTAssertEqual(rig.streamer.stopped, [10])
        XCTAssertTrue(rig.service.session(bundleId: bundle)!.running)

        let (c2, op2o) = rig.connect("op1"); let op2 = op2o!
        let out = c2.drain()
        guard case .appList(let apps)? = out.first else { return XCTFail("app list first") }
        XCTAssertEqual(apps[0].appId, 1)            // same app id as before
        XCTAssertEqual(apps[0].windowCount, 1)
        let added = out.compactMap { m -> UInt32? in if case .windowAdded(let id, _, _, _, _, _) = m { return id } else { return nil } }
        XCTAssertEqual(added, [10, 11])             // parent before child
        // Streams do not resume by themselves; the operator asks again.
        XCTAssertEqual(rig.streamer.started, [10])
        op2.say(.windowStreamStart(windowId: 10))
        XCTAssertEqual(rig.streamer.started, [10, 10])
        // And the old connection object is dead.
        XCTAssertFalse(op1.isOpen)
    }

    func testSecondConnectionFromSameOperatorReplacesFirst() {
        let rig = Rig()
        let (c1, _) = rig.connect("op1")
        let (c2, op2) = rig.connect("op1")
        XCTAssertTrue(c1.closed)
        XCTAssertFalse(c2.closed)
        XCTAssertTrue(rig.service.connection(operatorId: "op1") === op2)
    }

    func testReconnectAfterAppQuitShowsNotRunning() {
        let (rig, _, op1) = launched()
        rig.windows.byPid[4242] = [mainWindow(10)]
        rig.service.pollWindows()
        op1.close()
        rig.windows.running = []
        rig.service.pollWindows()
        let (c2, _) = rig.connect("op1")
        let out = c2.drain()
        XCTAssertEqual(out.count, 1)
        guard case .appList(let apps)? = out.first else { return XCTFail("app list") }
        XCTAssertFalse(apps[0].running)
    }

    func testRelaunchAfterQuitKeepsAppId() {
        let (rig, conn, op) = launched()
        rig.windows.running = []
        rig.service.pollWindows()
        _ = conn.drain()
        rig.launcher.outcomes[bundle] = .started(pid: 5000, name: "Browser")
        rig.windows.running = [5000]
        op.say(.appLaunch(requestId: 3, bundleId: bundle, activate: true, targets: []))
        XCTAssertEqual(conn.drain().first, .appLaunchResult(requestId: 3, status: 0, appId: 1))
    }

    // MARK: whole flow

    func testWholeFlow() {
        let rig = Rig()
        let (conn, opt) = rig.connect(); let op = opt!
        _ = conn.drain()
        op.say(.appLaunch(requestId: 1, bundleId: bundle, activate: true, targets: []))
        XCTAssertEqual(conn.drain().first, .appLaunchResult(requestId: 1, status: 0, appId: 1))
        rig.windows.byPid[4242] = [mainWindow(10)]
        rig.service.pollWindows()
        XCTAssertTrue(conn.drain().contains { if case .windowAdded(10, _, _, _, _, _) = $0 { return true } else { return false } })
        op.say(.windowResizeRequest(windowId: 10, width: 1024, height: 768))
        XCTAssertEqual(conn.drain(), [.windowResized(windowId: 10, width: 1024, height: 768, scale: 2)])
        rig.windows.byPid[4242] = [HostWindowSnapshot(windowId: 11, role: "AXSheet", subrole: nil, x: 200, y: 150, width: 400, height: 300),
                                   mainWindow(10, w: 1024, h: 768)]
        rig.service.pollWindows()
        XCTAssertTrue(conn.drain().contains(.childWindow(windowId: 11, parentId: 10, offsetX: 100, offsetY: 50, kind: .sheet)))
        rig.windows.byPid[4242] = []
        rig.service.pollWindows()
        XCTAssertEqual(conn.drain().prefix(2), [.windowClosed(windowId: 11), .windowClosed(windowId: 10)])
    }
}
