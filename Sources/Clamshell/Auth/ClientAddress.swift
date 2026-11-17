import Foundation

// Where a connection really came from when it arrives through a proxy: the
// web relay on this Mac, or a tunnel (cloudflared) that may run on this Mac
// too. Both reach the stream server from 127.0.0.1, so without this every
// browser and tunnel client would share one room-sharing group.
//
// The result is used for the address groups and the log lines, nothing else.
// An address is never a reason to trust a device.

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

/// The headers of WebSocket upgrade requests, handed from the handshake
/// handler (which does not know the connection) to the connection that
/// becomes ready. Handshakes finish in the order they start, so the oldest
/// entry belongs to the next connection; entries too old to belong to anyone
/// are dropped. A wrong match changes only the group a connection is counted
/// in, and only among connections that came through a trusted proxy.
final class UpgradeHeaders {
    private let lock = NSLock()
    private var entries: [(at: Date, headers: [(name: String, value: String)])] = []
    private let maxAge: TimeInterval = 10
    private let maxCount = 64

    func record(_ headers: [(name: String, value: String)]) {
        lock.lock()
        defer { lock.unlock() }
        entries.append((Date(), headers))
        if entries.count > maxCount { entries.removeFirst(entries.count - maxCount) }
    }

    func take() -> [(name: String, value: String)] {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        entries.removeAll { now.timeIntervalSince($0.at) > maxAge }
        return entries.isEmpty ? [] : entries.removeFirst().headers
    }
}
