import Foundation

// Which device the host's approval window should ask about next, and which
// decisions made somewhere else it still has to show (PROTOCOL.md "Approving
// a device": the host shows on its own screen which device made a decision).
//
// No AppKit in here, so it can be tested.

struct ApprovalPrompts {
    /// A decision the user did not make in this app's window or menu: from
    /// the command line, relayed by a trusted device, or written into the
    /// device list by something else.
    struct Notice: Equatable {
        /// The device as it now stands.
        let device: DeviceRecord
        /// Trusted before the change. For a device that is now denied, this
        /// is trust being taken away.
        let wasTrusted: Bool
    }

    /// What the approval window should do next.
    enum Step: Equatable {
        /// Leave it as it is.
        case keep
        /// Ask about this waiting device, or refresh what is shown about it.
        case ask(DeviceRecord)
        /// Show this decision made elsewhere.
        case notice(Notice)
        /// Nothing to show: take the window away.
        case dismiss
    }

    /// How long the window stays away after the user closes it without
    /// deciding, the first time. Doubles each time it is closed again.
    static let firstQuiet: TimeInterval = 20
    static let longestQuiet: TimeInterval = 15 * 60
    /// Decisions made elsewhere that may wait their turn on screen.
    static let maxQueuedNotices = 16

    /// What a device looked like at the last `note`.
    private struct Seen: Equatable {
        let state: DeviceState
        let decidedAt: Double?
    }
    private var last: [String: Seen] = [:]
    private var primed = false
    /// Decisions made elsewhere that have not been on screen yet.
    private var queue: [Notice] = []
    /// The one on screen now.
    private var onScreen: Notice?
    /// Decisions this app is making itself, so they are not shown back to the
    /// user as news. Good for one `note`.
    private var own: [String: DeviceState] = [:]
    /// Waiting devices the user closed the window on without deciding. They
    /// stay in the Devices menu and are not shown again unasked.
    private(set) var setAside: Set<String> = []
    /// Seconds since 1970. The window does not open by itself before this.
    private(set) var quietUntil: TimeInterval = 0
    private var timesClosed = 0

    /// This app is about to put `id` into `state` itself.
    mutating func expect(_ id: String, _ state: DeviceState) {
        own[id] = state
    }

    /// Call with the whole list after every change. Returns the decisions
    /// this app did not make since the last call, oldest decision first. The
    /// first call returns none: what was already decided when the app started
    /// is not news.
    ///
    /// What counts is what happened to the list, not what a record says about
    /// where it was decided: a device that turns up trusted is reported
    /// unless this app trusted it just now. So is one that was decided twice
    /// between two calls and stands where it stood, revoked and approved
    /// again for example: the time of its decision changed.
    mutating func note(_ records: [DeviceRecord]) -> [Notice] {
        var notices: [Notice] = []
        var seen: [String: Seen] = [:]
        for r in records {
            let now = Seen(state: r.state, decidedAt: r.decidedAt)
            let before = last[r.id]
            seen[r.id] = now
            guard primed, r.state != .waiting, before != now, own[r.id] != r.state else { continue }
            // A denied device that was never seen here was denied before it
            // could be shown; nothing to tell.
            if r.state == .denied && before == nil { continue }
            notices.append(Notice(device: r, wasTrusted: before?.state == .trusted))
        }
        last = seen
        primed = true
        own = [:]
        setAside = setAside.filter { seen[$0]?.state == .waiting }
        notices.sort { ($0.device.decidedAt ?? 0) < ($1.device.decidedAt ?? 0) }
        queue.append(contentsOf: notices)
        trimQueue()
        return notices
    }

    /// When more decisions are queued than the window will show, the oldest
    /// denial goes first: trust that was given is what the user most needs to
    /// see.
    private mutating func trimQueue() {
        while queue.count > Self.maxQueuedNotices {
            if let i = queue.firstIndex(where: { $0.device.state != .trusted }) {
                queue.remove(at: i)
            } else {
                queue.removeFirst()
            }
        }
    }

    /// Puts a decision made elsewhere back at the front, because the user
    /// asked to see it again.
    mutating func showAgain(_ notice: Notice) {
        guard onScreen?.device.id != notice.device.id else { return }
        queue.removeAll { $0.device.id == notice.device.id }
        queue.insert(notice, at: 0)
        trimQueue()
    }

    /// What the window should do now. `asking` is the device it is asking
    /// about, `noticeVisible` whether it is showing a decision made
    /// elsewhere, `picked` the waiting device the user just chose.
    ///
    /// In order: what the user picked; the question already on screen; the
    /// notice already on screen; decisions made elsewhere; the next waiting
    /// device.
    mutating func step(records: [DeviceRecord], asking: String?, noticeVisible: Bool,
                       picked: String? = nil, now: TimeInterval) -> Step {
        let waiting = Self.waiting(records)
        if let picked, let device = waiting.first(where: { $0.id == picked }) {
            // The notice this interrupts comes back afterwards.
            if noticeVisible, let interrupted = onScreen { queue.insert(interrupted, at: 0) }
            onScreen = nil
            return .ask(device)
        }
        if let asking, let device = waiting.first(where: { $0.id == asking }) { return .ask(device) }
        if noticeVisible { return .keep }
        onScreen = nil
        while !queue.isEmpty {
            let notice = queue.removeFirst()
            // Not if it was overtaken: decided again since, or forgotten.
            guard let current = records.first(where: { $0.id == notice.device.id }),
                  current.state == notice.device.state, current.decidedAt == notice.device.decidedAt else { continue }
            let fresh = Notice(device: current, wasTrusted: notice.wasTrusted)
            onScreen = fresh
            return .notice(fresh)
        }
        if let device = next(in: records, now: now) { return .ask(device) }
        return .dismiss
    }

    /// The waiting device to ask about now: the oldest one that was not set
    /// aside. None while the window is staying away.
    func next(in records: [DeviceRecord], now: TimeInterval) -> DeviceRecord? {
        guard !isQuiet(now: now) else { return nil }
        return Self.waiting(records).first { !setAside.contains($0.id) }
    }

    /// True while the window should not open by itself. A clock that was set
    /// back cannot stretch this beyond the longest quiet time.
    func isQuiet(now: TimeInterval) -> Bool {
        now < quietUntil && quietUntil - now <= Self.longestQuiet
    }

    /// The user closed the window without deciding: stop asking about every
    /// device that is waiting now, and stay away for a while even if a new
    /// device asks. Otherwise anything that can reach the host could bring
    /// the window back as fast as it can invent devices, until it gets a yes.
    mutating func setAsideAll(in records: [DeviceRecord], now: TimeInterval) {
        for r in records where r.state == .waiting { setAside.insert(r.id) }
        let quiet = min(Self.longestQuiet, Self.firstQuiet * pow(2, Double(min(timesClosed, 12))))
        timesClosed += 1
        quietUntil = now + quiet
    }

    /// The user answered in the window or picked a device in the menu, so
    /// they are looking at it: no reason to stay away.
    mutating func userIsAnswering() {
        timesClosed = 0
        quietUntil = 0
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

    /// "on this Mac", "from the command line" or "from “iPad” AB12-…". Empty
    /// when nothing is recorded.
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
        let verb: String
        switch (notice.device.state, notice.wasTrusted) {
        case (.trusted, _): verb = "approved"
        case (_, true): verb = "revoked"
        default: verb = "denied"
        }
        return "\(who) was \(verb)\(source.isEmpty ? "" : " " + source)."
    }

    /// True when another device with the same name is already trusted: either
    /// the same device with a new key, or something borrowing its name.
    static func sharesNameWithTrusted(_ device: DeviceRecord, among records: [DeviceRecord]) -> Bool {
        !device.name.isEmpty && records.contains {
            $0.state == .trusted && $0.id != device.id
                && $0.name.compare(device.name,
                                   options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame
        }
    }

    static func quoted(_ name: String) -> String { "\u{201C}\(name)\u{201D}" }
}
