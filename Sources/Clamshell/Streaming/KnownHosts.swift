import Foundation

// What a client remembers about the Macs it has met (PROTOCOL.md "Client
// rules"): each host's identity key, the name it last gave, and the addresses
// it has been reached at or has reported. Foundation only, no clock and no
// storage: the caller passes the time in and saves the encoded bytes. Compiled
// into the Mac package (where `swift test` runs it) and the iOS app.

/// An address the client dials for one host.
struct KnownAddress: Codable, Equatable {
    /// Lower-cased `host:port`, no scheme and no path (`KnownHosts.normalizeAddress`).
    var address: String
    /// True once a handshake at this address ended with this host's key
    /// verified. False for a hint learned from HOST_INFO.
    var verified: Bool
    /// Seconds on the caller's clock: when this address was last dialled,
    /// reported or confirmed. The one with the oldest value goes first when a
    /// host has too many.
    var lastUsed: Double
    /// Seconds on the caller's clock: the last verified handshake here.
    var lastSuccess: Double?
}

/// One Mac the app has met.
struct KnownHost: Codable, Equatable {
    /// The 65-byte identity key.
    var key: Data
    /// The name it last gave, cleaned for display.
    var name: String
    var addresses: [KnownAddress]

    var id: String { DeviceIdentity.id(ofPublicKey: key) }
    var fingerprint: String { DeviceIdentity.fingerprint(ofPublicKey: key) }
}

/// What the store knows about an address.
enum AddressStanding: Equatable {
    /// The address belongs to the host with this id (the key it must show).
    case host(id: String)
    /// Nothing is known about it.
    case unknown
    /// Nothing is known about it, and the user allowed an unverified
    /// connection here before.
    case unknownAllowed
}

struct KnownHosts: Equatable {
    static let maxAddressesPerHost = 16
    static let maxHintBytes = 256
    static let maxAllowedAddresses = 64
    private static let storeVersion = 1

    private(set) var hosts: [KnownHost] = []
    /// Addresses the user let an unverified connection go to, oldest first.
    private(set) var unverifiedAllowed: [String] = []

    init() {}

    // MARK: Addresses

    /// The lower-cased `host:port` a client dials, from a bare host
    /// (`192.168.1.5`, default port 5903) or a `ws`/`wss` URL (default port 80
    /// or 443). Scheme, path, user info, query and fragment are dropped, so
    /// `/ws/a` and `/ws/b` on one hostname are one address. nil when the text
    /// is not an address.
    static func normalizeAddress(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let bare = !trimmed.contains("://")
        guard let c = URLComponents(string: bare ? "ws://\(trimmed)" : trimmed),
              var host = c.host?.lowercased(), !host.isEmpty else { return nil }
        let scheme = (c.scheme ?? "ws").lowercased()
        guard scheme == "ws" || scheme == "wss" else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        guard !host.isEmpty else { return nil }
        let port = c.port ?? (bare ? Int(streamDefaultPort) : (scheme == "wss" ? 443 : 80))
        guard (1 ... 65535).contains(port) else { return nil }
        return "\(host.contains(":") ? "[\(host)]" : host):\(port)"
    }

    /// The address of a URL a host reported in HOST_INFO, under the spec's
    /// limits: `ws`/`wss` only, at most 256 bytes, no user info, no query, no
    /// fragment. nil for anything else.
    static func hintAddress(_ url: String) -> String? {
        guard url.utf8.count <= maxHintBytes, url.contains("://"),
              let c = URLComponents(string: url),
              let scheme = c.scheme?.lowercased(), scheme == "ws" || scheme == "wss",
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              let host = c.host, !host.isEmpty else { return nil }
        return normalizeAddress(url)
    }

    // MARK: Questions

    func host(id: String) -> KnownHost? { hosts.first { $0.id == id } }

    func standing(of address: String) -> AddressStanding {
        guard let a = Self.normalizeAddress(address) else { return .unknown }
        if let h = hosts.first(where: { $0.addresses.contains { $0.address == a } }) { return .host(id: h.id) }
        return unverifiedAllowed.contains(a) ? .unknownAllowed : .unknown
    }

    /// True when a verified handshake at this address ended with this host's key.
    func isVerified(address: String, forHost id: String) -> Bool {
        guard let a = Self.normalizeAddress(address), let h = host(id: id) else { return false }
        return h.addresses.contains { $0.address == a && $0.verified }
    }

    /// The addresses to try for a host: the last successful first, then the
    /// verified ones by recency, then the hints by recency.
    func dialOrder(hostId id: String) -> [String] {
        guard let h = host(id: id) else { return [] }
        return h.addresses.enumerated().sorted { l, r in
            let a = l.element, b = r.element
            if (a.lastSuccess ?? -.infinity) != (b.lastSuccess ?? -.infinity) {
                return (a.lastSuccess ?? -.infinity) > (b.lastSuccess ?? -.infinity)
            }
            if a.verified != b.verified { return a.verified }
            if a.lastUsed != b.lastUsed { return a.lastUsed > b.lastUsed }
            return l.offset < r.offset
        }.map { $0.element.address }
    }

    // MARK: Changes

    /// Remembers a host whose key was verified at an address: adds it if new,
    /// binds the address to it (taking the address from any other host), and
    /// clears the "unverified allowed" mark for that address.
    mutating func recordVerified(key: Data, name: String, address: String, now: Double) {
        guard DeviceIdentity.isValidPublicKey(key), let a = Self.normalizeAddress(address) else { return }
        let id = DeviceIdentity.id(ofPublicKey: key)
        let shown = AuthWire.cleanName(name)
        if let i = hosts.firstIndex(where: { $0.id == id }) {
            if !shown.isEmpty { hosts[i].name = shown }
        } else {
            hosts.append(KnownHost(key: key, name: shown, addresses: []))
        }
        bind(address: a, toHostId: id, now: now)
    }

    /// Binds an address to a host that is already known (a verified result
    /// from a key we have). Does nothing for an unknown host.
    mutating func bind(address: String, toHostId id: String, now: Double) {
        guard let a = Self.normalizeAddress(address), let i = hosts.firstIndex(where: { $0.id == id }) else { return }
        for j in hosts.indices where j != i { hosts[j].addresses.removeAll { $0.address == a } }
        if let k = hosts[i].addresses.firstIndex(where: { $0.address == a }) {
            hosts[i].addresses[k].verified = true
            hosts[i].addresses[k].lastUsed = now
            hosts[i].addresses[k].lastSuccess = now
        } else {
            hosts[i].addresses.append(KnownAddress(address: a, verified: true, lastUsed: now, lastSuccess: now))
        }
        unverifiedAllowed.removeAll { $0 == a }
        trim(hostIndex: i)
    }

    /// Adds the addresses a host reported as hints for that host. A URL that
    /// breaks the spec's limits is skipped, and so is an address that already
    /// belongs to another host: a host cannot take over an address.
    mutating func addHints(_ urls: [String], toHostId id: String, now: Double) {
        guard let i = hosts.firstIndex(where: { $0.id == id }) else { return }
        for url in urls {
            guard let a = Self.hintAddress(url) else { continue }
            if hosts.enumerated().contains(where: { $0.offset != i && $0.element.addresses.contains { $0.address == a } }) {
                continue
            }
            if hosts[i].addresses.contains(where: { $0.address == a }) { continue }
            hosts[i].addresses.append(KnownAddress(address: a, verified: false, lastUsed: now, lastSuccess: nil))
            unverifiedAllowed.removeAll { $0 == a }
            trim(hostIndex: i)
        }
    }

    /// Notes that an address of a host was dialled (not that it worked).
    mutating func markDialled(address: String, now: Double) {
        guard let a = Self.normalizeAddress(address) else { return }
        for i in hosts.indices {
            if let k = hosts[i].addresses.firstIndex(where: { $0.address == a }) {
                hosts[i].addresses[k].lastUsed = now
            }
        }
    }

    /// The user let an unverified connection go to this address. Ignored for
    /// an address that belongs to a host.
    mutating func allowUnverified(address: String) {
        guard let a = Self.normalizeAddress(address) else { return }
        if case .host = standing(of: a) { return }
        guard !unverifiedAllowed.contains(a) else { return }
        unverifiedAllowed.append(a)
        if unverifiedAllowed.count > Self.maxAllowedAddresses {
            unverifiedAllowed.removeFirst(unverifiedAllowed.count - Self.maxAllowedAddresses)
        }
    }

    /// Removes a host's key and every address bound to it.
    mutating func forget(hostId id: String) {
        hosts.removeAll { $0.id == id }
    }

    /// Keeps at most 16 addresses per host: the one unused longest goes
    /// first, and a hint goes before any verified address.
    private mutating func trim(hostIndex i: Int) {
        while hosts[i].addresses.count > Self.maxAddressesPerHost {
            let list = hosts[i].addresses
            let pool = list.indices.filter { !list[$0].verified }
            let candidates = pool.isEmpty ? Array(list.indices) : pool
            let drop = candidates.min { list[$0].lastUsed < list[$1].lastUsed } ?? 0
            hosts[i].addresses.remove(at: drop)
        }
    }

    // MARK: Storing

    private struct Stored: Codable {
        var version: Int
        var hosts: [KnownHost]
        var unverifiedAllowed: [String]
    }

    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    private struct LossyStored: Decodable {
        var hosts: [Lossy<KnownHost>]?
        var unverifiedAllowed: [Lossy<String>]?
    }

    func encoded() -> Data {
        let stored = Stored(version: Self.storeVersion, hosts: hosts, unverifiedAllowed: unverifiedAllowed)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(stored)) ?? Data()
    }

    /// Reads a stored copy. `nil` means nothing was stored yet. A copy that
    /// cannot be read gives an empty store and `damaged` set, so the caller can
    /// log it; one with some unreadable entries keeps every entry that could be
    /// read and sets `damaged` too.
    static func decode(_ data: Data?) -> (hosts: KnownHosts, damaged: Bool) {
        guard let data else { return (KnownHosts(), false) }
        guard let stored = try? JSONDecoder().decode(LossyStored.self, from: data) else {
            return (KnownHosts(), true)
        }
        var out = KnownHosts()
        var damaged = false
        guard let rawHosts = stored.hosts else { return (out, true) }
        var claimed = Set<String>()
        for entry in rawHosts {
            guard let host = entry.value, DeviceIdentity.isValidPublicKey(host.key) else { damaged = true; continue }
            var addresses: [KnownAddress] = []
            for var a in host.addresses {
                guard let n = normalizeAddress(a.address), n == a.address, !claimed.contains(n),
                      !addresses.contains(where: { $0.address == n }) else { damaged = true; continue }
                a.address = n
                addresses.append(a)
            }
            if let i = out.hosts.firstIndex(where: { $0.id == host.id }) {
                // The same key twice: one entry, with the addresses of both.
                damaged = true
                out.hosts[i].addresses.append(contentsOf: addresses)
            } else {
                out.hosts.append(KnownHost(key: host.key, name: AuthWire.cleanName(host.name), addresses: addresses))
            }
            for a in addresses { claimed.insert(a.address) }
        }
        for i in out.hosts.indices { out.trim(hostIndex: i) }
        for entry in stored.unverifiedAllowed ?? [] {
            guard let text = entry.value, let n = normalizeAddress(text), n == text else { damaged = true; continue }
            if !claimed.contains(n), !out.unverifiedAllowed.contains(n) { out.unverifiedAllowed.append(n) }
        }
        if (stored.unverifiedAllowed ?? []).count > maxAllowedAddresses {
            out.unverifiedAllowed = Array(out.unverifiedAllowed.suffix(maxAllowedAddresses))
        }
        return (out, damaged)
    }
}

/// Somewhere the encoded list is kept by name: a UserDefaults entry in the iOS
/// app, a dictionary in tests.
protocol KnownHostsBlobStore: AnyObject {
    func read(_ name: String) -> Data?
    func write(_ data: Data, as name: String)
    func remove(_ name: String)
}

/// Keeps the list in a `KnownHostsBlobStore`, with the same rule as the Windows
/// file (WindowsShared/KnownHostsFile.cs): nothing saved is an empty list, but a
/// saved copy that cannot be read in full is never treated as empty and never
/// written over. While `damage` is set no change is saved and a connection must
/// be refused. The only way out is `reset`, which keeps the damaged copy under
/// another name and starts empty. Main thread only.
final class KnownHostsKeeper {
    static let blobName = "clamshell.knownHosts.v1"
    /// What a person is told when the saved copy is damaged.
    static let damagedMessage = "The saved Macs on this device could not be read, so nothing was connected "
        + "and nothing was changed. Choose \"Reset saved Macs\u{2026}\" to put the damaged copy aside and start "
        + "again; every Mac will then have to be confirmed again."

    private let blobs: KnownHostsBlobStore
    /// The list in use. Empty (and not to be used) while `damage` is set.
    private(set) var hosts = KnownHosts()
    /// Non-nil when a saved copy exists and cannot be read in full.
    private(set) var damage: String?

    init(blobs: KnownHostsBlobStore) {
        self.blobs = blobs
        let (loaded, damaged) = KnownHosts.decode(blobs.read(Self.blobName))
        if damaged {
            damage = Self.damagedMessage
        } else {
            hosts = loaded
        }
    }

    /// Applies one change and saves. False (and nothing saved) while damaged
    /// or when the change alters nothing.
    @discardableResult
    func apply(_ change: KnownHostsChange, now: Double) -> Bool {
        guard damage == nil else { return false }
        var next = hosts
        change.apply(to: &next, now: now)
        guard next != hosts else { return false }
        hosts = next
        save()
        return true
    }

    /// Records that an address was dialled. Nothing is saved while damaged.
    func markDialled(address: String, now: Double) {
        guard damage == nil else { return }
        var next = hosts
        next.markDialled(address: address, now: now)
        hosts = next
        save()
    }

    /// The deliberate way out of a damaged copy: keeps it, unchanged, under
    /// `known-hosts.damaged-<UTC timestamp>.json`, then starts with an empty
    /// list. Returns the name it was kept under; nil when nothing was damaged.
    @discardableResult
    func reset(at date: Date) -> String? {
        guard damage != nil else { return nil }
        var kept: String?
        if let data = blobs.read(Self.blobName) {
            let name = Self.damagedName(at: date) { blobs.read($0) != nil }
            blobs.write(data, as: name)
            blobs.remove(Self.blobName)
            kept = name
        }
        hosts = KnownHosts()
        damage = nil
        return kept
    }

    /// `known-hosts.damaged-20261117T101500Z.json`, with `-2`, `-3`... before
    /// the extension when that name is taken.
    static func damagedName(at date: Date, isTaken: (String) -> Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: date)
        var name = "known-hosts.damaged-\(stamp).json"
        var n = 2
        while isTaken(name) {
            name = "known-hosts.damaged-\(stamp)-\(n).json"
            n += 1
        }
        return name
    }

    private func save() {
        blobs.write(hosts.encoded(), as: Self.blobName)
    }
}

/// One change to the store. The connection flow reports these instead of a
/// whole store, so two connections that run side by side cannot overwrite each
/// other's changes: the caller applies each one to the one shared store.
enum KnownHostsChange: Equatable {
    case recordVerified(key: Data, name: String, address: String)
    case bind(hostId: String, address: String)
    case hints(hostId: String, urls: [String])
    case allowUnverified(address: String)
    case forget(hostId: String)

    func apply(to hosts: inout KnownHosts, now: Double) {
        switch self {
        case let .recordVerified(key, name, address): hosts.recordVerified(key: key, name: name, address: address, now: now)
        case let .bind(id, address): hosts.bind(address: address, toHostId: id, now: now)
        case let .hints(id, urls): hosts.addHints(urls, toHostId: id, now: now)
        case let .allowUnverified(address): hosts.allowUnverified(address: address)
        case let .forget(id): hosts.forget(hostId: id)
        }
    }
}
