import XCTest
import CryptoKit
@testable import Clamshell

/// Approving a device from a phone (PROTOCOL.md "Approving a device"): the
/// one-time link, the page, and the push payload. No network: the push goes
/// to a fake transport. Every name and address here is synthetic.
final class PhoneApprovalTests: XCTestCase {
    private var dir: URL!
    private var clock = Date(timeIntervalSince1970: 1_794_000_000)
    private var store: DeviceTrustStore!
    private var service: PhoneApprovalService!

    private final class FakeTransport: PushoverTransport {
        var sent: [[String: String]] = []
        var accept = true
        func post(form: [String: String], completion: @escaping (Bool) -> Void) {
            sent.append(form)
            completion(accept)
        }
    }

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clamshell-tests-\(UUID().uuidString)", isDirectory: true)
        store = DeviceTrustStore(directory: dir, watch: false, now: { [unowned self] in self.clock })
        let now = { [unowned self] in self.clock }
        service = PhoneApprovalService(store: store, tokens: PhoneApprovalTokens(now: now),
                                       limiter: PhoneApprovalLimiter(now: now))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private let config = PhoneApprovalConfig(baseURL: "https://clamshell.example.invalid",
                                             appToken: "app-token-fixture", userKey: "user-key-fixture")

    private func waitingDevice(name: String = "Pad") -> DeviceRecord {
        let key = P256.Signing.PrivateKey().publicKey.x963Representation
        _ = store.ask(publicKey: key, name: name, address: "192.0.2.7", hasOpenConnection: { _ in false })
        return store.record(id: DeviceIdentity.id(ofPublicKey: key))!
    }

    private func link(for device: DeviceRecord) -> String {
        service.tokens.issue(deviceId: device.id)!
    }

    private func get(_ token: String, client: String = "198.51.100.1") -> PhoneApprovalReply {
        service.handle(method: "GET", path: "/approve/" + token, headers: [], body: Data(), client: client)
    }

    private let formHeaders = [(name: "Content-Type", value: "application/x-www-form-urlencoded"),
                               (name: "Host", value: "clamshell.example.invalid")]

    private func post(_ token: String, _ decision: String = "approve", headers: [(name: String, value: String)]? = nil,
                      client: String = "198.51.100.1") -> PhoneApprovalReply {
        service.handle(method: "POST", path: "/approve/" + token, headers: headers ?? formHeaders,
                       body: Data("decision=\(decision)".utf8), client: client)
    }

    private func text(_ r: PhoneApprovalReply) -> String { String(decoding: r.body, as: UTF8.self) }

    // MARK: tokens

    func testTokenIsLongRandomHexAndBoundToItsDevice() {
        let a = service.tokens.issue(deviceId: "a")!
        let b = service.tokens.issue(deviceId: "b")!
        XCTAssertEqual(a.count, 64)
        XCTAssertTrue(PhoneApprovalTokens.isWellFormed(a))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(service.tokens.peek(a), "a")
        XCTAssertEqual(service.tokens.peek(b), "b")
    }

    func testTokenWorksOnceAndNoMore() {
        let t = service.tokens.issue(deviceId: "a")!
        XCTAssertEqual(service.tokens.peek(t), "a")
        XCTAssertEqual(service.tokens.consume(t), "a")
        XCTAssertNil(service.tokens.consume(t))
        XCTAssertNil(service.tokens.peek(t))
    }

    func testTokenExpiresAfterTenMinutes() {
        let t = service.tokens.issue(deviceId: "a")!
        clock.addTimeInterval(599)
        XCTAssertEqual(service.tokens.peek(t), "a")
        clock.addTimeInterval(1)
        XCTAssertNil(service.tokens.peek(t))
        XCTAssertEqual(service.tokens.liveCount, 0)
    }

    func testNewTokenForADeviceVoidsTheOldOne() {
        let old = service.tokens.issue(deviceId: "a")!
        let new = service.tokens.issue(deviceId: "a")!
        XCTAssertNil(service.tokens.peek(old))
        XCTAssertEqual(service.tokens.peek(new), "a")
    }

    func testMalformedTokensNeverMatch() {
        _ = service.tokens.issue(deviceId: "a")
        for t in ["", "abc", String(repeating: "g", count: 64), String(repeating: "A", count: 64)] {
            XCTAssertNil(service.tokens.peek(t))
        }
    }

    func testFailedRandomnessIssuesNothing() {
        let tokens = PhoneApprovalTokens(randomBytes: { _ in nil })
        XCTAssertNil(tokens.issue(deviceId: "a"))
    }

    func testConstantTimeCompare() {
        XCTAssertTrue(PhoneApprovalTokens.sameBytes(Data([1, 2]), Data([1, 2])))
        XCTAssertFalse(PhoneApprovalTokens.sameBytes(Data([1, 2]), Data([1, 3])))
        XCTAssertFalse(PhoneApprovalTokens.sameBytes(Data([1]), Data([1, 2])))
    }

    // MARK: the page

    func testGetShowsTheDeviceAndDecidesNothing() {
        let device = waitingDevice(name: "Pad")
        let t = link(for: device)
        for _ in 0..<3 {
            let r = get(t)
            XCTAssertEqual(r.status, "200 OK")
            XCTAssertTrue(text(r).contains(device.fingerprint))
            XCTAssertTrue(text(r).contains("Compare with the fingerprint the device shows"))
            XCTAssertTrue(text(r).contains("Approve") && text(r).contains("Deny"))
        }
        XCTAssertEqual(store.state(of: device.id), .waiting)
        XCTAssertEqual(service.tokens.peek(t), device.id)
    }

    func testPageHeadersAndEscaping() {
        let device = waitingDevice(name: "<script>x</script>")
        let r = get(link(for: device))
        XCTAssertTrue(r.headers.contains("Cache-Control: no-store"))
        XCTAssertTrue(r.headers.contains("Referrer-Policy: no-referrer"))
        XCTAssertFalse(text(r).contains("<script>"))
    }

    func testPostApprovesOnceWithPhoneLabel() {
        let device = waitingDevice()
        let t = link(for: device)
        let r = post(t)
        XCTAssertEqual(r.status, "200 OK")
        XCTAssertEqual(store.state(of: device.id), .trusted)
        XCTAssertEqual(store.record(id: device.id)?.decidedBy, DeviceTrustStore.decidedFromPhone)
        XCTAssertEqual(post(t).status, "404 Not Found")
    }

    func testPostCanDeny() {
        let device = waitingDevice()
        _ = post(link(for: device), "deny")
        XCTAssertEqual(store.state(of: device.id), .denied)
        XCTAssertEqual(store.record(id: device.id)?.decidedBy, DeviceTrustStore.decidedFromPhone)
    }

    func testPostNeedsAFormFromThisOriginAndAKnownDecision() {
        let device = waitingDevice()
        let t = link(for: device)
        let json = [(name: "Content-Type", value: "application/json"), (name: "Host", value: "clamshell.example.invalid")]
        let cross = formHeaders + [(name: "Sec-Fetch-Site", value: "cross-site")]
        let foreign = formHeaders + [(name: "Origin", value: "https://other.example.invalid")]
        XCTAssertEqual(post(t, headers: json).status, "404 Not Found")
        XCTAssertEqual(post(t, headers: cross).status, "404 Not Found")
        XCTAssertEqual(post(t, headers: foreign).status, "404 Not Found")
        XCTAssertEqual(post(t, "maybe").status, "404 Not Found")
        XCTAssertEqual(store.state(of: device.id), .waiting)
        // None of those used the link up.
        let same = formHeaders + [(name: "Origin", value: "https://clamshell.example.invalid"),
                                  (name: "Sec-Fetch-Site", value: "same-origin")]
        XCTAssertEqual(post(t, headers: same).status, "200 OK")
    }

    func testLinkIsBoundToItsDevice() {
        let a = waitingDevice(name: "A"), b = waitingDevice(name: "B")
        _ = post(link(for: a))
        XCTAssertEqual(store.state(of: a.id), .trusted)
        XCTAssertEqual(store.state(of: b.id), .waiting)
    }

    func testLinkDiesWhenTheDeviceIsDecidedElsewhere() {
        let device = waitingDevice()
        let t = link(for: device)
        store.decide(id: device.id, .deny, by: DeviceTrustStore.decidedOnCommandLine, onlyIfWaiting: true)
        XCTAssertEqual(get(t).status, "404 Not Found")
        XCTAssertEqual(post(t).status, "404 Not Found")
        XCTAssertEqual(store.state(of: device.id), .denied)
        XCTAssertEqual(store.record(id: device.id)?.decidedBy, DeviceTrustStore.decidedOnCommandLine)
    }

    func testReconcileVoidsTokensOfDevicesNoLongerWaiting() {
        let device = waitingDevice()
        let t = link(for: device)
        store.decide(id: device.id, .approve, by: DeviceTrustStore.decidedOnHost, onlyIfWaiting: true)
        service.reconcile()
        XCTAssertNil(service.tokens.peek(t))
    }

    func testBadUsedAndExpiredLinksLookTheSame() {
        let device = waitingDevice()
        let used = link(for: device)
        _ = post(used)
        let other = waitingDevice(name: "B")
        let expired = link(for: other)
        clock.addTimeInterval(601)
        let bad = String(repeating: "0", count: 64)
        let pages = [get(bad), get(used), get(expired)].map { ($0.status, $0.headers, $0.body) }
        XCTAssertEqual(pages[0].0, pages[1].0)
        XCTAssertEqual(pages[0].2, pages[1].2)
        XCTAssertEqual(pages[0].2, pages[2].2)
    }

    func testClientIsBlockedAfterTooManyFailures() {
        let device = waitingDevice()
        let t = link(for: device)
        for i in 0..<PhoneApprovalLimiter.maxFailures {
            _ = get(String(format: "%064x", i), client: "198.51.100.9")
        }
        XCTAssertEqual(get(t, client: "198.51.100.9").status, "404 Not Found")
        XCTAssertEqual(get(t, client: "198.51.100.10").status, "200 OK")
        clock.addTimeInterval(PhoneApprovalLimiter.window)
        XCTAssertEqual(get(link(for: device), client: "198.51.100.9").status, "200 OK")
    }

    // MARK: host-side wording

    func testPhoneDecisionIsShownLikeAnyOtherDecisionElsewhere() {
        let device = DeviceRecord(id: String(repeating: "ab", count: 32), publicKey: "", name: "Pad", state: .trusted,
                                  firstSeen: 0, lastSeen: 0, address: "192.0.2.7", decidedAt: 5,
                                  decidedBy: DeviceTrustStore.decidedFromPhone)
        XCTAssertEqual(ApprovalPrompts.source(of: device.decidedBy, among: []), "from a phone")
        var prompts = ApprovalPrompts()
        var waiting = device
        waiting.state = .waiting; waiting.decidedAt = nil; waiting.decidedBy = nil
        _ = prompts.note([waiting])
        let news = prompts.note([device])
        XCTAssertEqual(news.count, 1)
        XCTAssertEqual(ApprovalPrompts.sentence(for: news[0], among: [device]), "\u{201C}Pad\u{201D} was approved from a phone.")
    }

    func testPhoneLabelSurvivesReloadingTheList() {
        let device = waitingDevice()
        _ = post(link(for: device))
        let again = DeviceTrustStore(directory: dir, watch: false, now: { [unowned self] in self.clock })
        XCTAssertEqual(again.record(id: device.id)?.decidedBy, DeviceTrustStore.decidedFromPhone)
    }

    // MARK: the push

    func testPushPayloadCarriesNameAddressFingerprintAndOneTimeLink() {
        let device = waitingDevice(name: "Pad")
        let transport = FakeTransport()
        service.notify(device, config: config, transport: transport)
        XCTAssertEqual(transport.sent.count, 1)
        let form = transport.sent[0]
        XCTAssertEqual(form["token"], "app-token-fixture")
        XCTAssertEqual(form["user"], "user-key-fixture")
        XCTAssertTrue(form["message"]!.contains("Pad"))
        XCTAssertTrue(form["message"]!.contains(device.fromText))
        XCTAssertTrue(form["message"]!.contains(device.fingerprint))
        XCTAssertEqual(form["ttl"], "600")
        let url = form["url"]!
        XCTAssertTrue(url.hasPrefix("https://clamshell.example.invalid/approve/"))
        let token = String(url.dropFirst("https://clamshell.example.invalid/approve/".count))
        XCTAssertEqual(service.tokens.peek(token), device.id)
    }

    func testUndeliveredPushVoidsItsLink() {
        let device = waitingDevice()
        let transport = FakeTransport()
        transport.accept = false
        service.notify(device, config: config, transport: transport)
        let token = String(transport.sent[0]["url"]!.split(separator: "/").last!)
        XCTAssertNil(service.tokens.peek(token))
    }

    func testFormEncoding() {
        let body = String(decoding: PushoverMessage.encode(["a": "x y&z", "b": "é"]), as: UTF8.self)
        XCTAssertEqual(body, "a=x%20y%26z&b=%C3%A9")
    }

    // MARK: settings

    private struct FakeSecrets: SecretReader {
        var items: [String: String]
        func secret(service: String, account: String) -> String? { items["\(service)/\(account)"] }
    }

    private func defaults(_ values: [String: Any]) -> UserDefaults {
        let d = UserDefaults(suiteName: "clamshell-tests-\(UUID().uuidString)")!
        for (k, v) in values { d.set(v, forKey: k) }
        return d
    }

    func testOffUnlessEnabledAndFullyConfigured() {
        let secrets = FakeSecrets(items: ["svc/pushover-app-token": "a", "svc/pushover-user-key": "u"])
        let base: [String: Any] = [PhoneApprovalConfig.enabledKey: true,
                                   PhoneApprovalConfig.baseURLKey: "https://clamshell.example.invalid/",
                                   PhoneApprovalConfig.serviceKey: "svc"]
        XCTAssertEqual(PhoneApprovalConfig.load(defaults: defaults(base), secrets: secrets)?.baseURL,
                       "https://clamshell.example.invalid")
        XCTAssertNil(PhoneApprovalConfig.load(defaults: defaults([:]), secrets: secrets))
        var off = base; off[PhoneApprovalConfig.enabledKey] = false
        XCTAssertNil(PhoneApprovalConfig.load(defaults: defaults(off), secrets: secrets))
        XCTAssertNil(PhoneApprovalConfig.load(defaults: defaults(base), secrets: FakeSecrets(items: [:])))
        var http = base; http[PhoneApprovalConfig.baseURLKey] = "http://clamshell.example.invalid"
        XCTAssertNil(PhoneApprovalConfig.load(defaults: defaults(http), secrets: secrets))
        var path = base; path[PhoneApprovalConfig.baseURLKey] = "https://clamshell.example.invalid/x"
        XCTAssertNil(PhoneApprovalConfig.load(defaults: defaults(path), secrets: secrets))
    }
}
