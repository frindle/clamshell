import XCTest
import DeskProtocol
@testable import DeskClient

final class ConnectionTests: XCTestCase {
    func testConnectsAndListsApps() {
        let h = Harness()
        XCTAssertEqual(h.conn.state, .idle)
        h.conn.start()
        h.advance(0.2)
        XCTAssertEqual(h.conn.state, .ready)
        XCTAssertEqual(h.conn.model.apps, [editorApp])
        XCTAssertTrue(h.host.received.contains(.appListRequest))
        XCTAssertTrue(h.log.list.contains(.apps(hostId: "h1", [editorApp])))
    }

    func testHostWithoutAppHostCapabilityIsAPermanentFailure() {
        let h = Harness()
        h.host.capabilities = 0
        h.conn.start()
        h.advance(60)
        XCTAssertEqual(h.conn.state, .failed("the host does not host apps"))
        XCTAssertEqual(h.host.connectCount, 1)
    }

    func testLaunchStartsAppAndItsWindowOpens() {
        let h = Harness(apps: [AppInfo(appId: 7, bundleId: "org.example.editor", name: "Editor", pid: -1, windowCount: 0, residentMB: 0, running: false)])
        h.conn.start()
        h.advance(0.2)
        XCTAssertNil(h.window)
        let id = h.conn.launch(bundleId: "org.example.editor", activate: true, targets: ["/shared/doc.txt"])
        XCTAssertNotNil(id)
        h.advance(0.1)
        XCTAssertEqual(h.window?.title, "Untitled")
        XCTAssertEqual(h.window?.bundleId, "org.example.editor")
        XCTAssertEqual(h.host.streamStarts, [h.window?.windowId ?? 0])
        XCTAssertTrue(h.log.list.contains(.launchResult(hostId: "h1", requestId: id ?? 0, status: 0, appId: 7)))
        XCTAssertEqual(h.conn.model.apps.first?.running, true)
    }

    func testLaunchOfUnknownAppReportsNotInstalled() {
        let h = Harness()
        h.conn.start()
        h.advance(0.2)
        let id = h.conn.launch(bundleId: "org.example.missing")
        h.advance(0.1)
        XCTAssertTrue(h.log.list.contains(.launchResult(hostId: "h1", requestId: id ?? 0, status: 1, appId: 0)))
    }

    func testLaunchWhileNotReadyReturnsNil() {
        let h = Harness()
        XCTAssertNil(h.conn.launch(bundleId: "org.example.editor"))
    }

    func testWindowAddedMovedResizedTitledClosed() {
        let h = Harness()
        h.startWithWindow()
        let w = h.window
        XCTAssertEqual(w?.windowId, 100)
        XCTAssertEqual(w?.title, "Doc")
        XCTAssertEqual(w?.kind, .main)
        XCTAssertEqual(w?.geometry, geo(50, 60, 800, 600))
        XCTAssertEqual(h.host.streamStarts, [100])
        let local = w?.localId ?? 0

        h.host.moveWindow(100, x: 300, y: 400)
        XCTAssertEqual(h.window?.geometry.x, 300)
        XCTAssertEqual(h.window?.geometry.y, 400)
        XCTAssertEqual(h.log.changes(.moved).count, 1)

        h.host.resizeWindow(100, width: 640, height: 480)
        XCTAssertEqual(h.window?.hostSize, DeskSize(width: 640, height: 480))
        XCTAssertEqual(h.log.changes(.resized(.adopted)).count, 1)

        h.host.retitleWindow(100, "Renamed")
        XCTAssertEqual(h.window?.title, "Renamed")
        XCTAssertEqual(h.log.changes(.retitled).count, 1)

        h.host.closeWindow(100)
        XCTAssertNil(h.window)
        XCTAssertEqual(h.log.closed(), [local])
    }

    func testMessagesForUnknownWindowsAreIgnored() {
        let h = Harness()
        h.startWithWindow()
        h.log.clear()
        h.host.deliver(.windowMoved(windowId: 999, x: 1, y: 1))
        h.host.deliver(.windowResized(windowId: 999, width: 10, height: 10, scale: 1))
        h.host.deliver(.windowTitle(windowId: 999, title: "x"))
        h.host.deliver(.windowClosed(windowId: 999))
        h.host.deliver(.childWindow(windowId: 999, parentId: 100, offsetX: 0, offsetY: 0, kind: .sheet))
        h.host.deliver(.windowStreamFrame(windowId: 999, flags: 1, ptsMicros: 0, nal: [1]))
        XCTAssertEqual(h.log.list, [])
        XCTAssertEqual(h.conn.state, .ready)
    }

    func testStreamFramesForOpenWindowsArePassedOn() {
        let h = Harness()
        h.startWithWindow()
        h.log.clear()
        h.host.deliver(.windowStreamFrame(windowId: 100, flags: 1, ptsMicros: 5, nal: [1, 2, 3]))
        XCTAssertEqual(h.log.list, [.message(hostId: "h1", .windowStreamFrame(windowId: 100, flags: 1, ptsMicros: 5, nal: [1, 2, 3]))])
    }

    func testUnknownTypeIsSkippedAndDoesNotCloseTheConnection() {
        let h = Harness()
        h.startWithWindow()
        h.host.deliverRaw((try? Framing.encode(type: 0xFE, payload: [1, 2, 3])) ?? [])
        XCTAssertEqual(h.conn.state, .ready)
    }

    func testKnownTypeThatFailsToDecodeClosesTheConnectionAndItReconnects() {
        let h = Harness()
        h.startWithWindow()
        h.host.deliverRaw((try? Framing.encode(type: DeskType.windowAdded.rawValue, payload: [0, 0])) ?? [])
        if case .waiting = h.conn.state {} else { XCTFail("expected waiting, got \(h.conn.state)") }
        h.advance(1)
        XCTAssertEqual(h.conn.state, .ready)
        XCTAssertEqual(h.window?.windowId, 100)
    }

    func testRepeatedWindowIdIsAProtocolError() {
        let h = Harness()
        h.startWithWindow()
        h.host.deliver(.windowAdded(windowId: 100, appId: 7, kind: .main, parentId: 0, title: "Again", geometry: geo(0, 0, 10, 10)))
        if case .waiting = h.conn.state {} else { XCTFail("expected waiting, got \(h.conn.state)") }
    }

    func testSplitBytesAreReassembled() {
        let h = Harness()
        h.startWithWindow()
        let bytes = (try? DeskMessage.windowTitle(windowId: 100, title: "Split").encodeFrame()) ?? []
        h.host.deliverRaw(Array(bytes.prefix(3)))
        XCTAssertEqual(h.window?.title, "Doc")
        h.host.deliverRaw(Array(bytes.dropFirst(3)))
        XCTAssertEqual(h.window?.title, "Split")
    }

    func testStopClosesEveryWindow() {
        let h = Harness()
        h.startWithWindow()
        let local = h.window?.localId ?? 0
        h.conn.stop()
        XCTAssertEqual(h.conn.state, .idle)
        XCTAssertEqual(h.log.closed(), [local])
        h.advance(60)
        XCTAssertEqual(h.host.connectCount, 1)
    }

    func testHubKeepsASessionListPerHost() {
        let sched = FakeScheduler()
        let hostA = FakeHost(scheduler: sched)
        hostA.apps = [editorApp]
        hostA.windows = [HostWindow(id: 100, appId: 7, title: "Doc", geometry: geo(0, 0, 100, 100))]
        let log = EventLog()
        let hub = DeskHub(factory: hostA, scheduler: sched, onEvent: { log.list.append($0) })
        hub.addHost(id: "a", name: "Alpha")
        hub.addHost(id: "b", name: "Beta")
        XCTAssertTrue(hub.addHost(id: "a", name: "Alpha") === hub.connection("a"))
        sched.advance(0.3)
        let s = hub.sessions
        XCTAssertEqual(s.map { $0.hostId }, ["a", "b"])
        XCTAssertEqual(s.map { $0.name }, ["Alpha", "Beta"])
        XCTAssertEqual(s.map { $0.state }, [.ready, .ready])
        XCTAssertEqual(s[0].liveWindows, 1)
        XCTAssertEqual(hub.hostsRunning(bundleId: "org.example.editor").count, 2)
        hub.removeHost(id: "b")
        XCTAssertEqual(hub.sessions.count, 1)
        XCTAssertNil(hub.connection("b"))
    }

    func testBackoffDoublesToItsCapAndResets() {
        var b = Backoff(initial: 0.5, factor: 2, cap: 4)
        XCTAssertEqual([b.next(), b.next(), b.next(), b.next(), b.next()], [0.5, 1, 2, 4, 4])
        b.reset()
        XCTAssertEqual(b.next(), 0.5)
    }
}
