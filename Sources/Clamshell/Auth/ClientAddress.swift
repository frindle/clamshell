import Foundation

// Where a connection really came from when it arrives through a proxy: the
// web relay on this Mac, or a tunnel (cloudflared) that may run on this Mac
// too. Both reach the stream server from 127.0.0.1, so without this every
// browser and tunnel client would share one room-sharing group.
//
// The result is used for the address groups and, labelled as the proxy's
// claim and not verified, in the log lines and where a device is shown to the
// person deciding about it. The TCP peer stays the fact. An address is never
// a reason to trust a device.

/// The proxies whose headers are believed: loopback always, plus the
/// addresses and CIDR ranges the user lists in the `trustedProxies` setting.
struct TrustedProxies {
    private struct Range {
        var bytes: [UInt8]
        var bits: Int
    }

    private var ranges: [Range] = []

    /// Entries are "192.0.2.7", "198.51.100.0/24", "2001:db8::/32". An entry
    /// that cannot be read is ignored (a proxy not listed is not trusted).
    init(_ entries: [String] = []) {
        for entry in entries {
            let parts = entry.trimmingCharacters(in: .whitespaces).split(separator: "/", maxSplits: 1).map(String.init)
            guard let first = parts.first, let bytes = ClientAddress.packed(first) else { continue }
            var bits = bytes.count * 8
            if parts.count == 2 {
                guard let given = Int(parts[1]), given >= 0, given <= bits else { continue }
                bits = given
            }
            ranges.append(Range(bytes: bytes, bits: bits))
        }
    }

    func contains(_ address: String) -> Bool {
        guard let bytes = ClientAddress.packed(address) else { return false }
        if bytes.count == 4, bytes[0] == 127 { return true }
        if bytes.count == 16, bytes[0 ..< 15].allSatisfy({ $0 == 0 }), bytes[15] == 1 { return true }
        for range in ranges where range.bytes.count == bytes.count {
            if Self.prefixMatches(bytes, range.bytes, bits: range.bits) { return true }
        }
        return false
    }

    private static func prefixMatches(_ a: [UInt8], _ b: [UInt8], bits: Int) -> Bool {
        let whole = bits / 8
        if a[0 ..< whole] != b[0 ..< whole] { return false }
        let rest = bits % 8
        if rest == 0 { return true }
        let mask = UInt8(truncatingIfNeeded: 0xff << (8 - rest))
        return a[whole] & mask == b[whole] & mask
    }

    /// The setting as stored: an array of strings. Anything else is empty.
    static func fromStored(_ value: Any?) -> TrustedProxies {
        TrustedProxies((value as? [Any])?.compactMap { $0 as? String } ?? [])
    }
}

enum ClientAddress {
    /// The address to group a connection by.
    /// - The TCP peer is not a trusted proxy: the peer, and headers are
    ///   ignored.
    /// - `CF-Connecting-IP` when it holds an address.
    /// - Otherwise the right-most `X-Forwarded-For` entry that is not itself a
    ///   trusted proxy, when it holds an address.
    /// - Otherwise the peer.
    /// Header names are matched without regard to case.
    static func resolve(peer: String, headers: [(name: String, value: String)],
                        trusted: TrustedProxies) -> String {
        guard trusted.contains(peer) else { return peer }
        func values(_ name: String) -> [String] {
            headers.filter { $0.name.lowercased() == name }.map { $0.value }
        }
        if let cf = values("cf-connecting-ip").first, let address = clean(cf) { return address }
        let forwarded = values("x-forwarded-for").flatMap { $0.split(separator: ",").map(String.init) }
        for entry in forwarded.reversed() {
            let text = entry.trimmingCharacters(in: .whitespaces)
            if let address = clean(text), trusted.contains(address) { continue }
            // The first entry from the right that is not a trusted proxy is
            // the client; if it cannot be read, nothing is believed.
            return clean(text) ?? peer
        }
        return peer
    }

    /// An address as plain text, or nil when the text is not one. Accepts a
    /// bracketed IPv6 address, an IPv4 address with a port, and a scope.
    static func clean(_ text: String) -> String? {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            text = String(text[text.index(after: text.startIndex) ..< close])
        } else if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") {
            text = String(text[..<colon])
        }
        if let scope = text.firstIndex(of: "%") { text = String(text[..<scope]) }
        return packed(text) == nil ? nil : text
    }

    /// 4 bytes for an IPv4 address, 16 for an IPv6 one (an IPv4-mapped one as
    /// its 4 IPv4 bytes), nil for anything else.
    static func packed(_ text: String) -> [UInt8]? {
        if text.contains(":") {
            var raw = in6_addr()
            guard inet_pton(AF_INET6, text, &raw) == 1 else { return nil }
            let bytes = withUnsafeBytes(of: &raw) { Array($0) }
            if bytes[0 ..< 10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
                return Array(bytes[12 ..< 16])
            }
            return bytes
        }
        var raw = in_addr()
        guard inet_pton(AF_INET, text, &raw) == 1 else { return nil }
        return withUnsafeBytes(of: &raw) { Array($0) }
    }
}

extension ClientAddress {
    /// True for an address on this Mac itself: 127.0.0.0/8, ::1, or either
    /// of those written as an IPv4-mapped IPv6 address.
    static func isLoopback(_ address: String) -> Bool {
        guard let bytes = packed(address) else { return false }
        if bytes.count == 4 { return bytes[0] == 127 }
        return bytes[0 ..< 15].allSatisfy { $0 == 0 } && bytes[15] == 1
    }

    /// How an address is shown to the person deciding about a device, or in a
    /// list of devices. The TCP peer is the fact. Behind a local proxy (the
    /// web relay or a tunnel on this Mac) the peer is this Mac itself, and
    /// what the proxy says about the real client is shown only as the
    /// proxy's claim: it is a header the connecting client may have written.
    static func describe(peer: String, reported: String?) -> String {
        let peer = peer.trimmingCharacters(in: .whitespaces)
        let reported = reported?.trimmingCharacters(in: .whitespaces) ?? ""
        let base: String
        if peer.isEmpty {
            base = "an unknown address"
        } else if isLoopback(peer) {
            base = "\(peer), through a local proxy"
        } else {
            base = peer
        }
        guard !reported.isEmpty, reported != peer else { return base }
        return "\(base) (the proxy reported \(reported); not verified)"
    }
}

/// The headers of WebSocket upgrade requests, handed from the handshake
/// handler (which does not know the connection) to the connection that
/// becomes ready. The handler cannot tell which connection an upgrade belongs
/// to, so a header set is handed on only when there is no doubt: when the
/// connection reaches ready, exactly one set is outstanding and exactly one
/// connection (this one) has not yet reached ready. Anything else, or a
/// connection that closes before it is ready, drops every outstanding set,
/// so one client's headers are never given to another. Sets too old to belong
/// to anyone are dropped.
///
/// What is handed on is still only what the client wrote, believed only when
/// a trusted proxy sent it. It is shown as the proxy's claim and never as the
/// connection's address.
final class UpgradeHeaders {
    private let lock = NSLock()
    private var entries: [(at: Date, headers: [(name: String, value: String)])] = []
    private var notReady = 0
    private let maxAge: TimeInterval
    private let maxCount = 64
    private let now: () -> Date

    init(maxAge: TimeInterval = 10, now: @escaping () -> Date = Date.init) {
        self.maxAge = maxAge
        self.now = now
    }

    /// A connection was accepted and has not reached ready.
    func connectionAccepted() {
        lock.lock()
        defer { lock.unlock() }
        notReady += 1
    }

    func record(_ headers: [(name: String, value: String)]) {
        lock.lock()
        defer { lock.unlock() }
        entries.append((now(), headers))
        if entries.count > maxCount { entries.removeFirst(entries.count - maxCount) }
    }

    /// A connection reached ready. Its headers, or nil when they cannot be
    /// told apart from someone else's. Either way it is no longer waiting.
    func bindAtReady() -> [(name: String, value: String)]? {
        lock.lock()
        defer { lock.unlock() }
        let outstandingLinks = notReady
        notReady = max(0, notReady - 1)
        let t = now()
        entries.removeAll { t.timeIntervalSince($0.at) > maxAge }
        if outstandingLinks == 1, entries.count == 1 { return entries.removeFirst().headers }
        entries.removeAll()
        return nil
    }

    /// A connection closed before it reached ready. It may have left a set
    /// behind, and which one is unknown, so all are dropped.
    func connectionClosedBeforeReady() {
        lock.lock()
        defer { lock.unlock() }
        notReady = max(0, notReady - 1)
        entries.removeAll()
    }
}
