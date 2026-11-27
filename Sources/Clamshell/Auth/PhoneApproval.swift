import CryptoKit
import Foundation
import Security

// Approving a waiting device from the owner's phone (PROTOCOL.md "Approving a
// device"). A push notification carries a one-time link; the page behind it
// shows the device and decides only on a POST. The decision goes through
// `DeviceTrustStore.decide`, like the command line's, labelled "phone".
//
// No AppKit in here, so it can be tested. Tokens live in memory only.

/// One-time tokens, each bound to one device id.
final class PhoneApprovalTokens {
    static let lifetime: TimeInterval = 10 * 60
    static let maxLive = 64
    /// 32 random bytes as 64 lowercase hex digits.
    static let tokenLength = 64

    private struct Entry {
        let hash: Data
        let deviceId: String
        let expires: Date
    }

    private var entries: [Entry] = []
    private let lock = NSLock()
    private let now: () -> Date
    private let randomBytes: (Int) -> Data?

    init(now: @escaping () -> Date = Date.init,
         randomBytes: @escaping (Int) -> Data? = PhoneApprovalTokens.secureRandom) {
        self.now = now
        self.randomBytes = randomBytes
    }

    static func secureRandom(_ count: Int) -> Data? {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes)
    }

    static func isWellFormed(_ token: String) -> Bool {
        token.utf8.count == tokenLength && token.utf8.allSatisfy { (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0) }
    }

    private static func hash(_ token: String) -> Data { Data(SHA256.hash(data: Data(token.utf8))) }

    /// Whether two byte strings are equal, taking the same time wherever they differ.
    static func sameBytes(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }

    /// A new token for `deviceId`; any earlier one for it stops working.
    func issue(deviceId: String) -> String? {
        guard let bytes = randomBytes(32), bytes.count == 32 else { return nil }
        let token = Hex.encode(bytes)
        lock.lock()
        defer { lock.unlock() }
        purge()
        entries.removeAll { $0.deviceId == deviceId }
        entries.append(Entry(hash: Self.hash(token), deviceId: deviceId,
                             expires: now().addingTimeInterval(Self.lifetime)))
        if entries.count > Self.maxLive { entries.removeFirst(entries.count - Self.maxLive) }
        return token
    }

    /// The device a live token is bound to. Does not use the token up.
    func peek(_ token: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return find(token).map { entries[$0].deviceId }
    }

    /// Uses a live token up and returns its device.
    func consume(_ token: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let i = find(token) else { return nil }
        return entries.remove(at: i).deviceId
    }

    /// Every token for this device stops working.
    func void(deviceId: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll { $0.deviceId == deviceId }
    }

    /// Only tokens for the devices still waiting keep working.
    func keepOnly(waiting: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll { !waiting.contains($0.deviceId) }
    }

    var liveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        purge()
        return entries.count
    }

    /// Caller holds the lock. Compares against every entry, so the time does
    /// not say which one matched or how much of it.
    private func find(_ token: String) -> Int? {
        purge()
        guard Self.isWellFormed(token) else { return nil }
        let wanted = Self.hash(token)
        var found: Int?
        for (i, entry) in entries.enumerated() where Self.sameBytes(entry.hash, wanted) { found = i }
        return found
    }

    private func purge() {
        let t = now()
        entries.removeAll { $0.expires <= t }
    }
}

/// Failed tokens per client: too many in a while and that client gets nothing.
final class PhoneApprovalLimiter {
    static let maxFailures = 10
    static let window: TimeInterval = 10 * 60
    static let maxClients = 1024

    private var failures: [String: [Date]] = [:]
    private let lock = NSLock()
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    func isBlocked(_ client: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return recent(client).count >= Self.maxFailures
    }

    func recordFailure(_ client: String) {
        lock.lock()
        defer { lock.unlock() }
        var list = recent(client)
        list.append(now())
        failures[client] = list
        if failures.count > Self.maxClients {
            let cutoff = now().addingTimeInterval(-Self.window)
            failures = failures.filter { $0.value.contains { $0 > cutoff } }
            if failures.count > Self.maxClients { failures.removeAll() }
        }
    }

    private func recent(_ client: String) -> [Date] {
        let cutoff = now().addingTimeInterval(-Self.window)
        return (failures[client] ?? []).filter { $0 > cutoff }
    }
}

struct PhoneApprovalReply {
    let status: String
    let headers: [String]
    let body: Data
}

/// The `/approve/<token>` page and the notification that links to it.
final class PhoneApprovalService {
    static let pathPrefix = "/approve/"

    let store: DeviceTrustStore
    let tokens: PhoneApprovalTokens
    let limiter: PhoneApprovalLimiter

    init(store: DeviceTrustStore, tokens: PhoneApprovalTokens = PhoneApprovalTokens(),
         limiter: PhoneApprovalLimiter = PhoneApprovalLimiter()) {
        self.store = store
        self.tokens = tokens
        self.limiter = limiter
    }

    /// Call after the device list changes: a device decided any other way
    /// loses its link.
    func reconcile() {
        tokens.keepOnly(waiting: Set(store.waiting().map(\.id)))
    }

    // MARK: the notification

    /// Makes a link for `device` and hands the push to `transport`. The link
    /// is voided again if the push could not be sent.
    func notify(_ device: DeviceRecord, config: PhoneApprovalConfig, transport: PushoverTransport) {
        guard let token = tokens.issue(deviceId: device.id) else {
            clog("DEVICES: phone approval: no random bytes for a link; nothing was sent")
            return
        }
        let form = PushoverMessage.form(config: config, device: device,
                                        url: PhoneApprovalConfig.approvalURL(base: config.baseURL, token: token))
        transport.post(form: form) { [weak self] ok in
            if !ok {
                self?.tokens.void(deviceId: device.id)
                clog("DEVICES: phone approval: the push for \(device.fingerprint) was not delivered")
            }
        }
    }

    // MARK: the page

    /// `path` is the request path without its query. GET shows the device and
    /// decides nothing; POST with `decision=approve` or `deny` decides.
    /// Anything wrong with the token gets the same page.
    func handle(method: String, path: String, headers: [(name: String, value: String)],
                body: Data, client: String) -> PhoneApprovalReply {
        guard path.hasPrefix(Self.pathPrefix), !limiter.isBlocked(client) else { return Self.generic }
        let token = String(path.dropFirst(Self.pathPrefix.count))
        guard let deviceId = tokens.peek(token),
              let device = store.record(id: deviceId), device.state == .waiting else {
            if let deviceId = tokens.peek(token) { tokens.void(deviceId: deviceId) }
            limiter.recordFailure(client)
            return Self.generic
        }
        switch method {
        case "GET":
            return Self.reply(Self.askPage(device, token: token))
        case "POST":
            guard Self.isSameOriginForm(headers), body.count <= 1024,
                  let decision = Self.decision(in: body) else { return Self.generic }
            guard tokens.consume(token) == deviceId,
                  store.decide(id: deviceId, decision, by: DeviceTrustStore.decidedFromPhone,
                               onlyIfWaiting: true) != nil else {
                limiter.recordFailure(client)
                return Self.generic
            }
            clog("DEVICES: \(device.fingerprint) \(decision == .approve ? "approved" : "denied") from a phone")
            return Self.reply(Self.donePage(device, decision))
        default:
            return Self.generic
        }
    }

    private static func header(_ name: String, in headers: [(name: String, value: String)]) -> String? {
        headers.first { $0.name.lowercased() == name }?.value
    }

    /// A form post from this page and no other site: a form content type, and
    /// an Origin and Sec-Fetch-Site that, when the browser sends them, say so.
    static func isSameOriginForm(_ headers: [(name: String, value: String)]) -> Bool {
        guard let type = header("content-type", in: headers)?.lowercased(),
              type.hasPrefix("application/x-www-form-urlencoded") else { return false }
        if let site = header("sec-fetch-site", in: headers)?.lowercased(), site != "same-origin", site != "none" {
            return false
        }
        if let origin = header("origin", in: headers) {
            guard let host = header("host", in: headers), let c = URLComponents(string: origin),
                  let originHost = c.host else { return false }
            let named = c.port.map { "\(originHost):\($0)" } ?? originHost
            guard named.lowercased() == host.lowercased() else { return false }
        }
        return true
    }

    static func decision(in body: Data) -> DeviceTrustStore.Decision? {
        let text = String(decoding: body, as: UTF8.self)
        for pair in text.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if kv.count == 2, kv[0] == "decision" { return DeviceTrustStore.Decision(rawValue: String(kv[1])) }
        }
        return nil
    }

    // MARK: HTML

    private static let securityHeaders = [
        "Cache-Control: no-store",
        "Referrer-Policy: no-referrer",
        "X-Content-Type-Options: nosniff",
        "X-Frame-Options: DENY",
        "X-Robots-Tag: noindex",
        "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'",
    ]

    private static func reply(_ html: String, status: String = "200 OK") -> PhoneApprovalReply {
        PhoneApprovalReply(status: status, headers: securityHeaders, body: Data(html.utf8))
    }

    /// The one page for a token that is wrong, used, expired or voided, and
    /// for a client that asked too often.
    static var generic: PhoneApprovalReply {
        reply(page("<h1>This link does not work</h1><p>It may have been used or may have expired.</p>"),
              status: "404 Not Found")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func page(_ inner: String) -> String {
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8">\
        <meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex">\
        <title>Clamshell</title><style>\
        body{font:18px -apple-system,system-ui,sans-serif;margin:0;padding:24px;text-align:center;color:#111;background:#fff}\
        @media(prefers-color-scheme:dark){body{color:#eee;background:#111}}\
        .fp{font:700 28px ui-monospace,Menlo,monospace;margin:20px 0;word-break:break-all}\
        button{font:600 20px -apple-system,system-ui,sans-serif;width:100%;padding:16px;margin:8px 0;border:0;border-radius:12px;color:#fff}\
        .a{background:#1a7f37}.d{background:#b42318}</style></head><body>\(inner)</body></html>
        """
    }

    private static func askPage(_ device: DeviceRecord, token: String) -> String {
        page("""
            <h1>\(escape(ApprovalPrompts.quoted(device.label))) is asking to connect</h1>\
            <p>from \(escape(device.fromText))</p>\
            <div class="fp">\(escape(device.fingerprint))</div>\
            <p>Compare with the fingerprint the device shows</p>\
            <form method="post" action="\(pathPrefix)\(token)">\
            <button class="a" name="decision" value="approve">Approve</button>\
            <button class="d" name="decision" value="deny">Deny</button></form>
            """)
    }

    private static func donePage(_ device: DeviceRecord, _ decision: DeviceTrustStore.Decision) -> String {
        page("<h1>\(decision == .approve ? "Approved" : "Denied")</h1><p>\(escape(ApprovalPrompts.quoted(device.label))) \(escape(device.fingerprint))</p>")
    }
}

/// The one service the host runs: the web server answers its page and the
/// Devices controller sends its notifications.
enum PhoneApproval {
    static let shared = PhoneApprovalService(store: HostAuth.shared.store)
}

// MARK: Pushover

protocol PushoverTransport {
    /// Posts a form; `completion` says whether the service accepted it.
    func post(form: [String: String], completion: @escaping (Bool) -> Void)
}

struct URLSessionPushoverTransport: PushoverTransport {
    static let endpoint = URL(string: "https://api.pushover.net/1/messages.json")!

    func post(form: [String: String], completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = PushoverMessage.encode(form)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            completion((response as? HTTPURLResponse)?.statusCode == 200)
        }.resume()
    }
}

enum PushoverMessage {
    static func clip(_ text: String, _ limit: Int) -> String { String(text.prefix(limit)) }

    /// The form fields for one waiting device. The name is whatever the
    /// device calls itself, so it is only ever message text.
    static func form(config: PhoneApprovalConfig, device: DeviceRecord, url: String) -> [String: String] {
        [
            "token": config.appToken,
            "user": config.userKey,
            "title": "A device is asking to connect",
            "message": clip("\(ApprovalPrompts.quoted(device.label)) from \(device.fromText)\nFingerprint \(device.fingerprint)", 1000),
            "url": url,
            "url_title": "Compare and decide",
            "ttl": String(Int(PhoneApprovalTokens.lifetime)),
        ]
    }

    static func encode(_ form: [String: String]) -> Data {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = form.sorted { $0.key < $1.key }.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
        return Data(body.utf8)
    }
}

// MARK: settings

protocol SecretReader {
    func secret(service: String, account: String) -> String?
}

struct KeychainSecretReader: SecretReader {
    func secret(service: String, account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Phone approval is off unless it is switched on and fully set up. The two
/// secrets are read from the Keychain when a push is sent and are never
/// stored in the preferences, the log or the diagnostics.
struct PhoneApprovalConfig {
    static let enabledKey = "phoneApprovalEnabled"
    static let baseURLKey = "phoneApprovalBaseURL"
    static let serviceKey = "phoneApprovalKeychainService"
    static let defaultService = "clamshell-phone-approval"
    static let appTokenAccount = "pushover-app-token"
    static let userKeyAccount = "pushover-user-key"

    let baseURL: String
    let appToken: String
    let userKey: String

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: enabledKey) }

    /// nil unless the base URL is a plain https origin and both secrets exist.
    static func load(defaults: UserDefaults = .standard, secrets: SecretReader = KeychainSecretReader()) -> PhoneApprovalConfig? {
        guard isEnabled(defaults), let base = origin(defaults.string(forKey: baseURLKey) ?? "") else { return nil }
        let service = defaults.string(forKey: serviceKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultService
        guard let app = secrets.secret(service: service, account: appTokenAccount),
              let user = secrets.secret(service: service, account: userKeyAccount) else { return nil }
        return PhoneApprovalConfig(baseURL: base, appToken: app, userKey: user)
    }

    /// "https://host[:port]" from the setting, or nil for anything else.
    static func origin(_ text: String) -> String? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("/") { text.removeLast() }
        guard let c = URLComponents(string: text), c.scheme == "https", let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.path.isEmpty, c.query == nil, c.fragment == nil else { return nil }
        return text
    }

    static func approvalURL(base: String, token: String) -> String {
        base + PhoneApprovalService.pathPrefix + token
    }
}
