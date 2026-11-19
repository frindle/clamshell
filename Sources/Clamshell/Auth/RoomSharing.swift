import Foundation

// How the host shares out the room in its three small tables (connections
// that have not answered the challenge, connections waiting for approval,
// devices on the waiting list) so that one source cannot fill them all
// (PROTOCOL.md "Host rules"). The group is used for nothing else: an address
// is never a reason to trust a device.

/// An address reduced to the group that shares one slice of each table.
enum AddressGroup {
    static let unknown = "unknown"

    /// An IPv4 address as it is; an IPv4-mapped IPv6 address as its IPv4
    /// address; any other IPv6 address as its first 64 bits ("2001:db8:0:0/64").
    /// Port and scope are dropped. Anything else, empty or unusable, is
    /// "unknown".
    static func of(_ address: String) -> String {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("[") {
            // "[2001:db8::1]:443"
            guard let close = text.firstIndex(of: "]") else { return unknown }
            text = String(text[text.index(after: text.startIndex) ..< close])
        } else if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") {
            // "192.0.2.1:443"
            text = String(text[..<colon])
        }
        if let scope = text.firstIndex(of: "%") { text = String(text[..<scope]) }
        guard !text.isEmpty else { return unknown }

        if text.contains(":") {
            var raw = in6_addr()
            guard inet_pton(AF_INET6, text, &raw) == 1 else { return unknown }
            let bytes = withUnsafeBytes(of: &raw) { Array($0) }
            if bytes[0 ..< 10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
                return dotted(Array(bytes[12 ..< 16]))
            }
            let groups = (0 ..< 4).map { String(UInt16(bytes[2 * $0]) << 8 | UInt16(bytes[2 * $0 + 1]), radix: 16) }
            return groups.joined(separator: ":") + "/64"
        }
        var raw = in_addr()
        guard inet_pton(AF_INET, text, &raw) == 1 else { return unknown }
        return dotted(withUnsafeBytes(of: &raw) { Array($0) })
    }

    private static func dotted(_ bytes: [UInt8]) -> String {
        bytes.map(String.init).joined(separator: ".")
    }
}

/// One pure decision, used by all three tables: no clock, no sockets.
enum RoomSharing {
    struct Entry: Equatable {
        var group: String
        /// How long ago it arrived or was last seen; the larger, the sooner
        /// it goes. Ties go to the entry that comes first.
        var age: TimeInterval
        var removable: Bool

        init(group: String, age: TimeInterval, removable: Bool = true) {
            self.group = group
            self.age = age
            self.removable = removable
        }
    }

    enum Verdict: Equatable {
        /// There is room: let the arrival in.
        case admit
        /// The arrival takes the place of the entry at this index.
        case replace(Int)
        /// The arrival is turned away.
        case turnAway
    }

    /// - There is room and the arrival's group is under its share: admit.
    /// - The arrival's group is at its share: it takes the place of that
    ///   group's first removable entry, or is turned away if it has none.
    /// - The table is full: the group holding the most entries is picked (the
    ///   one whose first entry comes first, on a tie). If the arrival's group
    ///   holds fewer, the arrival takes the place of the picked group's first
    ///   removable entry, or is turned away if it has none. Otherwise it is
    ///   turned away.
    static func decide(entries: [Entry], size: Int, share: Int, group: String) -> Verdict {
        func firstRemovable(of group: String) -> Int? {
            var best: Int?
            for (i, entry) in entries.enumerated() where entry.group == group && entry.removable {
                if best == nil || entry.age > entries[best!].age { best = i }
            }
            return best
        }
        let own = entries.filter { $0.group == group }.count
        if own >= share {
            return firstRemovable(of: group).map(Verdict.replace) ?? .turnAway
        }
        if entries.count < size { return .admit }

        var counts: [String: Int] = [:]
        var order: [String] = []
        for entry in entries {
            if counts[entry.group] == nil { order.append(entry.group) }
            counts[entry.group, default: 0] += 1
        }
        guard let heaviest = order.max(by: { counts[$0]! < counts[$1]! || (counts[$0]! == counts[$1]! && order.firstIndex(of: $0)! > order.firstIndex(of: $1)!) }),
              own < counts[heaviest]! else { return .turnAway }
        return firstRemovable(of: heaviest).map(Verdict.replace) ?? .turnAway
    }
}
