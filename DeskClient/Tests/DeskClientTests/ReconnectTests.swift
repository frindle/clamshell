import XCTest
import DeskProtocol
@testable import DeskClient

/// Acceptance item 8: the host display sleeping, the operator sleeping and waking, and a 10-second network drop,
/// with windows returning by themselves.
final class ReconnectTests: XCTestCase {
    func testReconnectAfterADropRestoresTheWindowSet() {
        let h = Harness()
        h.startWithWindow()
        h.host.addWindow(HostWindow(id: 101, appId: 7, title: "Second", geometry: geo(10, 10, 300, 200)))
        let before = h.conn.model.liveWindows
        XCTAssertEqual(before.count, 2)

        h.advance(1)
        h.host.dropLink()
        if case .waiting = h.conn.state {} else { XCTFail("expected waiting, got \(h.conn.state)") }
        XCTAssertEqual(h.conn.model.liveWindows.count, 0)
        XCTAssertEqual(h.conn.model.ghosts.count, 2)
        XCTAssertEqual(h.log.changes(.frozen).count, 2)
        XCTAssertEqual(h.log.closed(), [])

        h.advance(1)
        XCTAssertEqual(h.conn.state, .ready)
        let after = h.conn.model.liveWindows
        XCTAssertEqual(after.map { $0.localId }, before.map { $0.localId })
        XCTAssertEqual(after.map { $0.title }, ["Doc", "Second"])
        XCTAssertTrue(after.allSatisfy { $0.isLive })
        XCTAssertEqual(h.log.changes(.restored).count, 2)
        // No second "opened": the native windows are the same ones.
        XCTAssertEqual(h.log.opened().count, 2)
        // The stream is asked for again, once per window and connection.
        XCTAssertEqual(h.host.streamStarts, [100, 101, 100, 101])
        XCTAssertEqual(h.log.closed(), [])
    }

    func testAWindowKeepsItsPlaceWhenTheHostNumbersItDifferently() {
        let h = Harness()
        h.startWithWindow()
        let local = h.window?.localId
        h.host.dropLink()
        h.host.windows[0].id = 555
        h.advance(1)
        XCTAssertEqual(h.conn.state, .ready)
        XCTAssertEqual(h.window?.localId, local)
        XCTAssertEqual(h.window?.windowId, 555)
    }

    func testATenSecondSilentNetworkDropHealsByItself() {
        let h = Harness()
        h.startWithWindow()
        let local = h.window?.localId
        h.advance(10)
        XCTAssertEqual(h.conn.state, .ready)

        // The network goes: the old link says nothing and new ones cannot open.
        h.host.partitioned = true
        h.host.reachable = false
        h.advance(10)
        XCTAssertEqual(h.log.changes(.frozen).count, 1, "the drop is noticed within the 10 seconds")
        XCTAssertTrue(h.log.closed().isEmpty)

        // The network returns. The wait is at most the backoff cap plus the connect time.
        h.host.partitioned = false
        h.host.reachable = true
        h.advance(4.2)
        XCTAssertEqual(h.conn.state, .ready)
        XCTAssertEqual(h.window?.localId, local)
        XCTAssertEqual(h.log.changes(.restored).count, 1)
        XCTAssertEqual(h.log.opened().count, 1)
    }

    func testNetworkReturningRetriesAtOnce() {
        let h = Harness()
        h.startWithWindow()
        h.host.reachable = false
        h.host.dropLink()
        h.advance(30)
        XCTAssertNotEqual(h.conn.state, .ready)
        let tries = h.host.connectCount
        h.host.reachable = true
        h.conn.networkChanged(available: true)
        h.advance(0.1)
        XCTAssertEqual(h.conn.state, .ready)
        XCTAssertEqual(h.host.connectCount, tries + 1)
    }

    func testSleepFreezesAndMakesNoAttemptsThenWakeRestoresAtOnce() {
        let h = Harness()
        h.startWithWindow()
        let local = h.window?.localId
        let connects = h.host.connectCount

        h.conn.systemWillSleep()
        XCTAssertEqual(h.conn.state, .asleep)
        XCTAssertEqual(h.conn.model.liveWindows.count, 0)
        // Far longer than the offline limit: sleeping time does not count, and nothing tries to connect.
        h.advance(5_000)
        XCTAssertEqual(h.host.connectCount, connects)
        XCTAssertEqual(h.conn.model.ghosts.count, 1)
        XCTAssertEqual(h.log.closed(), [])

        h.conn.systemDidWake()
        h.advance(0.2)
        XCTAssertEqual(h.conn.state, .ready)
        XCTAssertEqual(h.window?.localId, local)
        XCTAssertEqual(h.host.connectCount, connects + 1)
    }

    func testWakeRebuildsALinkThatLooksAlive() {
        let h = Harness()
        h.startWithWindow()
        let local = h.window?.localId
        let connects = h.host.connectCount
        // No willSleep was seen, and the old link would still answer.
        h.conn.systemDidWake()
        h.advance(0.2)
        XCTAssertEqual(h.conn.state, .ready)
        XCTAssertEqual(h.host.connectCount, connects + 1)
        XCTAssertEqual(h.window?.localId, local)
    }

    func testHostRestartedTheAppSoTheOperatorStartsItAgain() {
        let h = Harness()
        h.startWithWindow()
        let local = h.window?.localId
        h.host.dropLink()
        // The host lost the app meanwhile.
        h.host.windows = []
        h.host.apps[0].running = false
        h.host.apps[0].pid = -1
        h.host.apps[0].windowCount = 0
        h.advance(1.5)
        XCTAssertEqual(h.host.launches.map { $0.bundle }, ["org.example.editor"])
        XCTAssertEqual(h.host.launches.map { $0.activate }, [false])
        XCTAssertEqual(h.conn.state, .ready, h.conn.lastLossReason ?? "")
        XCTAssertEqual(h.window?.localId, local, "the new window takes over the frozen one")
        XCTAssertEqual(h.log.opened().count, 1)
    }

    func testFrozenWindowsTheHostNeverAnnouncesAreClosedAfterTheGrace() {
        var config = DeskConnectionConfig()
        config.restoreGrace = 5
        let h = Harness(config: config)
        h.startWithWindow()
        let local = h.window?.localId ?? 0
        h.host.dropLink()
        // The app is running, but this window is gone.
        h.host.windows = []
        h.advance(1)
        XCTAssertEqual(h.conn.state, .ready)
        XCTAssertEqual(h.conn.model.ghosts.count, 1)
        XCTAssertEqual(h.log.closed(), [])
        h.advance(5)
        XCTAssertEqual(h.log.closed(), [local])
        XCTAssertTrue(h.conn.model.ghosts.isEmpty)
        XCTAssertTrue(h.host.launches.isEmpty)
    }

    func testFrozenWindowsAreClosedWhenTheHostStaysAwayTooLong() {
        var config = DeskConnectionConfig()
        config.offlineLimit = 60
        let h = Harness(config: config)
        h.startWithWindow()
        let local = h.window?.localId ?? 0
        h.host.reachable = false
        h.host.dropLink()
        h.advance(59)
        XCTAssertEqual(h.log.closed(), [])
        h.advance(2)
        XCTAssertEqual(h.log.closed(), [local])
    }

    func testMenusAndTooltipsAreDroppedAtOnceButSheetsFreeze() {
        let h = Harness()
        h.startWithWindow()
        h.host.addWindow(HostWindow(id: 110, appId: 7, kind: .sheet, parentId: 100, title: "Save", geometry: geo(100, 60, 400, 200), offset: (50, 0)))
        h.host.addWindow(HostWindow(id: 111, appId: 7, kind: .menu, parentId: 100, title: "", geometry: geo(60, 80, 200, 300), offset: (10, 20)))
        h.host.addWindow(HostWindow(id: 112, appId: 7, kind: .tooltip, parentId: 100, title: "", geometry: geo(70, 90, 80, 20), offset: (20, 30)))
        XCTAssertEqual(h.conn.model.liveWindows.count, 4)
        let menuLocal = h.conn.model.localId(forWindowId: 111) ?? 0
        let tipLocal = h.conn.model.localId(forWindowId: 112) ?? 0
        h.log.clear()
        h.host.dropLink()
        XCTAssertEqual(Set(h.log.closed()), Set([menuLocal, tipLocal]))
        XCTAssertEqual(h.conn.model.ghosts.map { $0.kind }, [.main, .sheet])
    }

    func testAResizeMadeWhileOfflineIsSentWhenTheWindowReturns() {
        let h = Harness()
        h.startWithWindow()
        let local = h.window?.localId ?? 0
        h.host.reachable = false
        h.host.dropLink()
        h.conn.userResized(localId: local, to: DeskSize(width: 500, height: 400))
        XCTAssertTrue(h.host.resizeRequests.isEmpty)
        h.host.reachable = true
        h.advance(2)
        XCTAssertEqual(h.conn.state, .ready)
        XCTAssertEqual(h.host.resizeRequests.count, 1)
        XCTAssertEqual(h.host.resizeRequests.first?.1, 500)
        XCTAssertEqual(h.host.resizeRequests.first?.2, 400)
    }

    func testBackoffStartsOverOnceALinkHasStayedUp() {
        let h = Harness()
        h.startWithWindow()
        h.advance(6)
        h.host.reachable = false
        h.host.dropLink()
        h.advance(0.6)
        h.advance(1.1)
        h.advance(2.1)
        // Attempts fail at 0.5, 1.5 and 3.5 seconds after the drop; the next wait is 4.
        if case .waiting(_, let retryIn) = h.conn.state { XCTAssertEqual(retryIn, 4) } else { XCTFail("expected waiting") }
        h.host.reachable = true
        h.advance(4.2)
        XCTAssertEqual(h.conn.state, .ready)
        // A link that stays up for a while makes the next drop start from the short wait again.
        h.advance(6)
        h.host.dropLink()
        if case .waiting(_, let retryIn) = h.conn.state { XCTAssertEqual(retryIn, 0.5) } else { XCTFail("expected waiting") }
    }
}
