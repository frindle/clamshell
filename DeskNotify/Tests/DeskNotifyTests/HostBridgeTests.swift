import XCTest
import DeskProtocol
@testable import DeskNotify

final class HostBridgeTests: XCTestCase {
    let ids = StaticAppIds([Fix.slack: 7, Fix.mail: 8, Fix.other: 9])

    private func rec(_ n: Int64, app: String = Fix.slack, title: String = "Hi", body: String = "Text", date: Double? = 100) -> NotificationRecord {
        NotificationRecord(recId: n, bundleId: app, title: title, subtitle: "", body: body, date: date, thread: "")
    }

    func testOnlyAllowedAppsAreForwarded() {
        let logs = Logs()
        let b = HostNotifyBridge(allowed: [Fix.slack], appIds: ids, log: logs.sink)
        let out = b.messages(for: [rec(1), rec(2, app: Fix.mail), rec(3, app: Fix.other)])
        XCTAssertEqual(out.count, 1)
        guard case .notify(let app, _, let title, _, _, _) = out[0] else { return XCTFail("not a notify") }
        XCTAssertEqual(app, 7)
        XCTAssertEqual(title, "Hi")
        XCTAssertTrue(logs.lines.contains { $0.contains("2 not forwarded") })
    }

    func testAllowlistCanChange() {
        let b = HostNotifyBridge(allowed: [], appIds: ids)
        XCTAssertEqual(b.messages(for: [rec(1)]).count, 0)
        b.allowed.insert(Fix.slack)
        XCTAssertEqual(b.messages(for: [rec(1)]).count, 1)
    }

    func testAppWithoutConnectionIdIsNotForwarded() {
        let b = HostNotifyBridge(allowed: [Fix.slack, "com.example.new"], appIds: ids)
        XCTAssertEqual(b.messages(for: [rec(1, app: "com.example.new")]).count, 0)
    }

    func testNotificationIdIsStableAndDistinct() {
        XCTAssertEqual(HostNotifyBridge.notificationId(rec(5)), HostNotifyBridge.notificationId(rec(5)))
        XCTAssertNotEqual(HostNotifyBridge.notificationId(rec(5)), HostNotifyBridge.notificationId(rec(6)))
        XCTAssertNotEqual(HostNotifyBridge.notificationId(rec(5, date: 100)), HostNotifyBridge.notificationId(rec(5, date: 101)))
        XCTAssertEqual(HostNotifyBridge.notificationId(rec(5, date: nil)), "5-0")
    }

    func testLongTextIsClippedAndStillEncodes() throws {
        let b = HostNotifyBridge(allowed: [Fix.slack], appIds: ids)
        let long = String(repeating: "\u{e9}", count: 20_000)
        let msg = b.messages(for: [rec(1, title: long, body: long)])[0]
        guard case .notify(_, _, let title, _, let body, _) = msg else { return XCTFail("not a notify") }
        XCTAssertLessThanOrEqual(title.utf8.count, 1024)
        XCTAssertLessThanOrEqual(body.utf8.count, 4096)
        XCTAssertEqual(body.utf8.count % 2, 0)   // never cut inside a character
        _ = try msg.encodeFrame()
    }

    func testMessageSurvivesTheWire() throws {
        let b = HostNotifyBridge(allowed: [Fix.slack], appIds: ids)
        let msg = b.messages(for: [NotificationRecord(recId: 3, bundleId: Fix.slack, title: "Title", subtitle: "Sub", body: "Body",
                                                      date: 12.5, thread: "x")])[0]
        let back = try DeskMessage.decode(type: msg.typeByte, payload: try msg.encodePayload())
        XCTAssertEqual(back, msg)
    }
}

final class BadgeTests: XCTestCase {
    final class Source: DockBadgeSource {
        var items: [DockBadge] = []
        var error: Error?
        func read() throws -> [DockBadge] { if let e = error { throw e }; return items }
    }
    struct Resolver: BundleResolver {
        func bundleId(for item: DockBadge) -> String? { item.appPath }   // the test path is the bundle id
    }
    struct Boom: Error {}

    let ids = StaticAppIds([Fix.slack: 7, Fix.mail: 8, Fix.other: 9])

    private func badge(_ bundle: String, _ label: String) -> DockBadge { DockBadge(title: bundle, appPath: bundle, label: label) }

    private func watcher(_ s: Source, allowed: Set<String> = [Fix.slack, Fix.mail], logs: Logs = Logs(), ids: HostAppIds? = nil) -> BadgeWatcher {
        BadgeWatcher(source: s, resolver: Resolver(), allowed: allowed, appIds: ids ?? self.ids, log: logs.sink)
    }

    func testDiffNewChangedCleared() {
        let d = BadgeDiff.changes(old: ["a": "1", "b": "2", "c": "3"], new: ["a": "1", "b": "5", "d": "9"])
        XCTAssertEqual(d.map { "\($0.bundleId)=\($0.text)" }, ["b=5", "c=", "d=9"])
        XCTAssertTrue(BadgeDiff.changes(old: ["a": "1"], new: ["a": "1"]).isEmpty)
    }

    func testFirstPollSendsCurrentBadgesThenOnlyChanges() {
        let s = Source()
        s.items = [badge(Fix.slack, "3")]
        let w = watcher(s)
        XCTAssertEqual(w.poll(), [.badge(appId: 7, text: "3")])
        XCTAssertEqual(w.poll(), [])
        s.items = [badge(Fix.slack, "4"), badge(Fix.mail, "1")]
        XCTAssertEqual(w.poll(), [.badge(appId: 7, text: "4"), .badge(appId: 8, text: "1")])
        s.items = [badge(Fix.mail, "1")]
        XCTAssertEqual(w.poll(), [.badge(appId: 7, text: "")])
        XCTAssertEqual(w.poll(), [])
    }

    func testOnlyAllowedAppsAreWatched() {
        let s = Source()
        s.items = [badge(Fix.other, "9"), badge(Fix.slack, "2")]
        XCTAssertEqual(watcher(s).poll(), [.badge(appId: 7, text: "2")])
    }

    func testFailedReadKeepsStateAndDoesNotClear() {
        let s = Source()
        s.items = [badge(Fix.slack, "3")]
        let logs = Logs()
        let w = watcher(s, logs: logs)
        _ = w.poll()
        s.error = Boom()
        XCTAssertEqual(w.poll(), [])
        XCTAssertEqual(w.poll(), [])
        XCTAssertEqual(logs.lines.filter { $0.contains("read failed") }.count, 1)
        s.error = nil
        XCTAssertEqual(w.poll(), [])   // still 3, nothing to say
        XCTAssertTrue(logs.lines.contains { $0.contains("readable again") })
    }

    func testResetResendsEverything() {
        let s = Source()
        s.items = [badge(Fix.slack, "3")]
        let w = watcher(s)
        _ = w.poll()
        w.reset()
        XCTAssertEqual(w.poll(), [.badge(appId: 7, text: "3")])
    }

    func testBadgeWaitsForAppIdAndIsSentLater() {
        final class Late: HostAppIds {
            var known: [String: UInt32] = [:]
            func appId(forBundleId b: String) -> UInt32? { known[b] }
        }
        let late = Late()
        let s = Source()
        s.items = [badge(Fix.slack, "3")]
        let w = watcher(s, ids: late)
        XCTAssertEqual(w.poll(), [])
        late.known[Fix.slack] = 7
        XCTAssertEqual(w.poll(), [.badge(appId: 7, text: "3")])
    }

    func testBlankLabelCountsAsNoBadge() {
        let s = Source()
        s.items = [badge(Fix.slack, "  ")]
        XCTAssertEqual(watcher(s).poll(), [])
    }
}
