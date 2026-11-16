import Foundation

// Which device the host's approval window should ask about next, and which
// decisions made somewhere else it still has to show (PROTOCOL.md "Approving
// a device": the host shows on its own screen which device made a decision).
//
// No AppKit in here, so it can be tested.

struct ApprovalPrompts {
    /// A decision the user did not make in the approval window: from the
    /// command line, or relayed by a trusted device.
    struct Notice: Equatable {
        /// The device as it now stands.
        let device: DeviceRecord
        /// Trusted before the change, so this is trust being taken away.
        let wasTrusted: Bool
    }

    private var lastStates: [String: DeviceState] = [:]
    private var primed = false
    /// Waiting devices the user closed the window on without deciding. They
    /// stay in the Devices menu and are not shown again unasked.
    private(set) var setAside: Set<String> = []

    /// Call with the whole list after every change. Returns the decisions
    /// made elsewhere since the last call, oldest decision first. The first
    /// call returns none: what was already decided when the app started is
    /// not news.
    mutating func note(_ records: [DeviceRecord]) -> [Notice] {
        var notices: [Notice] = []
        var states: [String: DeviceState] = [:]
        for r in records {
            states[r.id] = r.state
            guard primed, r.state != .waiting, lastStates[r.id] != r.state,
                  let by = r.decidedBy, by != DeviceTrustStore.decidedOnHost else { continue }
            // A denied device that was never seen here was denied before it
            // could be shown; nothing to tell.
            if r.state == .denied && lastStates[r.id] == nil { continue }
            notices.append(Notice(device: r, wasTrusted: lastStates[r.id] == .trusted))
        }
        lastStates = states
        primed = true
        setAside = setAside.filter { states[$0] == .waiting }
        return notices.sorted { ($0.device.decidedAt ?? 0) < ($1.device.decidedAt ?? 0) }
    }

    /// The waiting device to ask about now: the oldest one that was not set
    /// aside.
    func next(in records: [DeviceRecord]) -> DeviceRecord? {
        Self.waiting(records).first { !setAside.contains($0.id) }
    }

    /// The user closed the window without deciding: stop asking about every
    /// device that is waiting now. One that starts waiting later is asked
    /// about again.
    mutating func setAsideAll(in records: [DeviceRecord]) {
        for r in records where r.state == .waiting { setAside.insert(r.id) }
    }

    /// The user picked this device in the menu.
    mutating func bringBack(_ id: String) {
        setAside.remove(id)
    }

    /// Oldest first.
    static func waiting(_ records: [DeviceRecord]) -> [DeviceRecord] {
        records.filter { $0.state == .waiting }.sorted { $0.firstSeen < $1.firstSeen }
    }

    // MARK: wording shared by the window, the menu and notifications

    /// "on this Mac", "from the command line" or "from “iPad” AB12-…".
    static func source(of by: String?, among records: [DeviceRecord]) -> String {
        switch by {
        case nil: return ""
        case DeviceTrustStore.decidedOnHost?: return "on this Mac"
        case DeviceTrustStore.decidedOnCommandLine?: return "from the command line"
        case let id?:
            let fingerprint = DeviceIdentity.fingerprint(ofId: id)
            if let relay = records.first(where: { $0.id == id }) {
                return "from \(quoted(relay.label)) \(fingerprint)"
            }
            return "from device \(fingerprint)"
        }
    }

    /// One sentence for a decision made elsewhere.
    static func sentence(for notice: Notice, among records: [DeviceRecord]) -> String {
        let who = quoted(notice.device.label)
        let source = source(of: notice.device.decidedBy, among: records)
        switch (notice.device.state, notice.wasTrusted) {
        case (.trusted, _): return "\(who) was approved \(source)."
        case (_, true): return "\(who) was revoked \(source)."
        default: return "\(who) was denied \(source)."
        }
    }

    static func quoted(_ name: String) -> String { "\u{201C}\(name)\u{201D}" }
}
