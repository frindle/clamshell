import XCTest
import DeskProtocol
@testable import DeskNotify

private struct Directory: HostedAppDirectory {
    var map: [UInt32: String]
    func bundleId(forAppId appId: UInt32) -> String? { map[appId] }
}

private final class Context: OperatorContext {
    var focused: Set<String> = []
    var doNotDisturb = false
    func isFocused(hostedBundleId: String) -> Bool { focused.contains(hostedBundleId) }
}

private final class FakePoster: NotificationPoster, BadgeSetter {
    var posted: [PostRequest] = []
    var badges: [String: String] = [:]
    var fail = false
    struct Boom: Error {}
    func post(_ request: PostRequest) throws { if fail { throw Boom() }; posted.append(request) }
    func setBadge(stubBundleId: String, text: String) throws { if fail { throw Boom() }; badges[stubBundleId] = text }
}

final class OperatorGateTests: XCTestCase {
    private let dir = Directory(map: [7: Fix.slack, 8: Fix.mail, 9: Fix.other])
    private let ctx = Context()

    private func gate(hosted: Set<String> = [Fix.slack, Fix.mail], config: GateConfig = GateConfig()) -> NotificationGate {
        NotificationGate(hosted: hosted, directory: dir, context: ctx, config: config)
    }

    private func decide(_ g: NotificationGate, app: UInt32 = 7, id: String = "n1", title: String = "T", body: String = "B", at now: Double = 0) -> GateDecision {
        g.decide(appId: app, notificationId: id, title: title, subtitle: "", body: body, sound: false, now: now)
    }

    func testPostsUnderTheStubIdentity() {
        let d = decide(gate())
        guard case .post(let req) = d else { return XCTFail("expected post, got \(d)") }
        XCTAssertEqual(req.hostedBundleId, Fix.slack)
        XCTAssertEqual(req.stubBundleId, "local.desk.stub." + Fix.slack)
        XCTAssertEqual(req.title, "T")
    }

    func testAllowlist() {
        let g = gate()
        XCTAssertEqual(decide(g, app: 9), .drop(.notHosted))
        XCTAssertEqual(decide(g, app: 99), .drop(.unknownApp))
        g.hosted.insert(Fix.other)
        if case .post = decide(g, app: 9) {} else { XCTFail("expected post") }
    }

    func testDuplicateIdIsDropped() {
        let g = gate()
        if case .post = decide(g, id: "x", title: "A", at: 0) {} else { XCTFail() }
        XCTAssertEqual(decide(g, id: "x", title: "Different text", at: 100), .drop(.duplicate))
        // The same id from another app is a different notification.
        if case .post = decide(g, app: 8, id: "x", title: "Other app", at: 101) {} else { XCTFail() }
    }

    func testDuplicateIdExpires() {
        var c = GateConfig(); c.idTTL = 60
        let g = gate(config: c)
        _ = decide(g, id: "x", title: "A", at: 0)
        if case .post = decide(g, id: "x", title: "B", at: 61) {} else { XCTFail("id should have expired") }
    }

    func testSameContentWithinWindowIsDropped() {
        let g = gate()
        _ = decide(g, id: "a", title: "Same", body: "Same", at: 0)
        XCTAssertEqual(decide(g, id: "b", title: "Same", body: "Same", at: 2), .drop(.duplicate))
        if case .post = decide(g, id: "c", title: "Same", body: "Same", at: 9) {} else { XCTFail("window should have passed") }
    }

    func testRateLimitPerApp() {
        var c = GateConfig(); c.perAppLimit = 3; c.perAppWindow = 10
        let g = gate(config: c)
        for i in 0..<3 { if case .post = decide(g, id: "n\(i)", title: "m\(i)", at: Double(i)) {} else { XCTFail("n\(i)") } }
        XCTAssertEqual(decide(g, id: "n3", title: "m3", at: 3), .drop(.rateLimited))
        // Another app is not affected.
        if case .post = decide(g, app: 8, id: "z", title: "z", at: 3) {} else { XCTFail("other app") }
        // The window slides.
        if case .post = decide(g, id: "n4", title: "m4", at: 10.5) {} else { XCTFail("after window") }
    }

    func testGlobalRateLimit() {
        var c = GateConfig(); c.globalLimit = 2; c.perAppLimit = 100
        let g = gate(config: c)
        _ = decide(g, app: 7, id: "a", title: "a", at: 0)
        _ = decide(g, app: 8, id: "b", title: "b", at: 0)
        XCTAssertEqual(decide(g, app: 7, id: "c", title: "c", at: 1), .drop(.rateLimited))
    }

    func testFocusedAppIsNotReposted() {
        let g = gate()
        ctx.focused = [Fix.slack]
        XCTAssertEqual(decide(g, id: "a", title: "a"), .drop(.focused))
        ctx.focused = []
        // It was seen while focused, so it does not come back later.
        XCTAssertEqual(decide(g, id: "a", title: "a", at: 1), .drop(.duplicate))
        if case .post = decide(g, app: 8, id: "m", title: "m") {} else { XCTFail("an unfocused app still posts") }
    }

    func testDoNotDisturbSuppresses() {
        let g = gate()
        ctx.doNotDisturb = true
        XCTAssertEqual(decide(g, id: "a", title: "a"), .drop(.doNotDisturb))
        ctx.doNotDisturb = false
        if case .post = decide(g, id: "b", title: "b", at: 1) {} else { XCTFail() }
    }

    func testSuppressedNotificationsDoNotUseRateBudget() {
        var c = GateConfig(); c.perAppLimit = 1
        let g = gate(config: c)
        ctx.doNotDisturb = true
        for i in 0..<5 { _ = decide(g, id: "d\(i)", title: "d\(i)", at: Double(i)) }
        ctx.doNotDisturb = false
        if case .post = decide(g, id: "ok", title: "ok", at: 6) {} else { XCTFail("budget should be untouched") }
    }

    func testDedupeTablesStayBounded() {
        var c = GateConfig(); c.maxRemembered = 50; c.perAppLimit = 1_000_000; c.globalLimit = 1_000_000
        let g = gate(config: c)
        for i in 0..<500 { _ = decide(g, id: "n\(i)", title: "t\(i)", at: Double(i) * 0.01) }
        // Recent ids are still remembered after trimming.
        XCTAssertEqual(decide(g, id: "n499", title: "other", at: 5.0), .drop(.duplicate))
    }

    func testBridgePostsAndSetsBadges() {
        let g = gate()
        let fake = FakePoster()
        let logs = Logs()
        let b = OperatorBridge(gate: g, directory: dir, poster: fake, badges: fake, log: logs.sink)

        let r = b.handle(.notify(appId: 7, notificationId: "1", title: "T", subtitle: "", body: "B", sound: false), now: 0)
        guard case .posted(let req) = r else { return XCTFail("expected posted, got \(r)") }
        XCTAssertEqual(fake.posted, [req])

        XCTAssertEqual(b.handle(.badge(appId: 7, text: "3"), now: 0), .badgeSet(stubBundleId: "local.desk.stub." + Fix.slack, text: "3"))
        XCTAssertEqual(fake.badges["local.desk.stub." + Fix.slack], "3")
        XCTAssertEqual(b.handle(.badge(appId: 7, text: ""), now: 1), .badgeSet(stubBundleId: "local.desk.stub." + Fix.slack, text: ""))
        XCTAssertEqual(b.handle(.badge(appId: 9, text: "1"), now: 1), .dropped(.notHosted))
        XCTAssertEqual(b.handle(.badge(appId: 50, text: "1"), now: 1), .dropped(.unknownApp))
        XCTAssertEqual(b.handle(.windowListRequest, now: 1), .ignored)
    }

    func testBridgeReportsPosterFailureWithoutText() {
        let fake = FakePoster()
        fake.fail = true
        let logs = Logs()
        let b = OperatorBridge(gate: gate(), directory: dir, poster: fake, badges: fake, log: logs.sink)
        XCTAssertEqual(b.handle(.notify(appId: 7, notificationId: "1", title: "Secret", subtitle: "", body: "Secret", sound: false), now: 0), .failed)
        XCTAssertEqual(b.handle(.badge(appId: 7, text: "1"), now: 0), .failed)
        XCTAssertFalse(logs.lines.joined().contains("Secret"))
    }

    func testStubIdMatchesTheGenerator() {
        XCTAssertEqual(NotificationGate.stubBundleId(for: "a.b"), "local.desk.stub.a.b")
    }
}
