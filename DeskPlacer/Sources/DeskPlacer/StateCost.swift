/// Kinds of state from plan section 9.3, plus `service` for things that hold none.
public enum StateKind: String, Equatable, CaseIterable {
    case service            // tool servers, hosted sessions: restart anywhere
    case a                  // window layout and documents via macOS restore
    case b                  // browsers
    case c                  // Electron chat and mail: state is on the service
    case d                  // documents that may have unsaved changes
    case e                  // playback position (the browser extension records it)
    case f                  // terminals in persistent sessions
    case g                  // Claude Code sessions (resumable)
    case h                  // live calls, transfers, games, renders: no serialisable form
}

/// Result of the restore experiment for one app (E12).
public enum RestoreScore: Equatable {
    case passed, failed, untested
}

/// How the placer may offer a move for the app.
public enum OfferPolicy: Equatable {
    /// Proposed automatically when a Mac is short of memory.
    case auto
    /// Moves only when Penn asks (a browser profile).
    case onRequest
    /// Never moves (Darkbloom, apps tied to local state).
    case never
}

public struct AppProfile: Equatable {
    public var key: String
    public var name: String
    /// Resident memory on the operator, MB (snapshot of 2026-11-20).
    public var residentMB: Int
    public var kind: StateKind
    public var offer: OfferPolicy
    public var restore: RestoreScore
    public init(key: String, name: String, residentMB: Int, kind: StateKind, offer: OfferPolicy = .auto, restore: RestoreScore = .untested) {
        self.key = key; self.name = name; self.residentMB = residentMB; self.kind = kind; self.offer = offer; self.restore = restore
    }
}

/// Why a move is blocked right now. The offer returns when these clear.
public enum Blocker: Equatable {
    case inCall
    case transferInProgress
    /// Kind H: no serialisable form, so it cannot be moved even when nothing else is reported.
    case noSerialisableState
    case toolCallInFlight
    case localTerminalJob
    case unsavedEdits([String])
}

public enum PinReason: Equatable {
    case neverMoves
    case restoreFailed
    case restoreUntested
}

public enum MoveCost: Equatable {
    /// Nothing is lost and nothing needs restoring.
    case free
    /// Restores from saved state (kinds A to E with a passed restore score).
    case cheap
    case blocked([Blocker])
    /// Not offered, and not movable by a plain "Move to" either.
    case pinned(PinReason)

    public var isMovable: Bool { self == .free || self == .cheap }
}

public enum StateCostTable {
    /// Cost of moving `app` now, given what is currently blocking it.
    public static func cost(of app: AppProfile, blockers: [Blocker] = []) -> MoveCost {
        if app.offer == .never { return .pinned(.neverMoves) }
        // Blockers win over everything else: a call in progress cannot be restored by any kind.
        if !blockers.isEmpty { return .blocked(blockers) }
        switch app.kind {
        case .service, .f, .g:
            return .free
        case .h:
            // Kind H has no serialisable form. With no live blocker reported it is treated as blocked anyway.
            return .blocked([.noSerialisableState])
        case .a, .b, .c, .d, .e:
            switch app.restore {
            case .passed: return .cheap
            case .failed: return .pinned(.restoreFailed)
            case .untested: return .pinned(.restoreUntested)
            }
        }
    }
}

public struct RunningApp: Equatable {
    public var profile: AppProfile
    public var blockers: [Blocker]
    /// Memory the running copy uses now, from the node agent. When absent, the catalog figure stands in.
    public var liveResidentMB: Int?
    public init(profile: AppProfile, blockers: [Blocker] = [], liveResidentMB: Int? = nil) {
        self.profile = profile; self.blockers = blockers; self.liveResidentMB = liveResidentMB
    }
    /// What a target must be able to hold: live figure first, catalog second.
    public var sizeMB: Int { PlacementConfig.clampMB(liveResidentMB ?? profile.residentMB) }
}

public struct MoveProposal: Equatable {
    public var app: AppProfile
    public var from: String
    public var to: String
    public var cost: MoveCost
}

public enum MoveAdvisor {
    /// Short of memory: pressure above green, or swap at or over the threshold.
    /// A stale reading says nothing, so it is never short (no offer is made from old data).
    public static func isShort(_ s: HostSample, _ cfg: PlacementConfig, now: Double) -> Bool {
        cfg.isFresh(s, now: now) && (s.pressure != .green || s.swapUsedMB >= cfg.swapThresholdMB)
    }

    /// What the rules file says about moving `app`: nil when it must stay (a hardware need, a local rule, or no rule at
    /// all with the default local); `.some(nil)` when it may go to any Mac; `.some(name)` when only that Mac is allowed
    /// (its home). A move offer never overrides `needs`, `home` or the default-local rule.
    static func movableByRules(_ app: String, _ cfg: PlacementConfig) -> String?? {
        let (placement, needs) = cfg.resolve(app)
        guard needs.isEmpty else { return nil }
        switch placement {
        case .local: return nil
        case .home(let h): return .some(h)
        case .anywhere: return .some(nil)
        }
    }

    /// Proposes moving the largest app that is free or cheap and may be offered automatically, to the Mac with the
    /// most headroom that can hold it. Never proposes anything that would lose state. nil when the Mac is not short,
    /// or nothing qualifies.
    public static func propose(from source: HostSample, running: [RunningApp], others: [HostSample], config cfg: PlacementConfig,
                               neverFor: Set<String> = [], now: Double, ledger: LaunchLedger = LaunchLedger()) -> MoveProposal? {
        guard isShort(source, cfg, now: now) else { return nil }
        let candidates = running
            .filter { $0.profile.offer == .auto && !neverFor.contains($0.profile.key) }
            .filter { StateCostTable.cost(of: $0.profile, blockers: $0.blockers).isMovable }
            .filter { movableByRules($0.profile.key, cfg) != nil }
            .sorted { a, b in
                a.sizeMB != b.sizeMB ? a.sizeMB > b.sizeMB : a.profile.key < b.profile.key
            }
        for c in candidates {
            let rulePlacement = movableByRules(c.profile.key, cfg)
            let targets = others.filter { $0.name != source.name && (rulePlacement.flatMap { $0 } == nil || rulePlacement.flatMap { $0 } == $0.name) && Placer.eligible($0, cfg, need: c.sizeMB, now: now, ledger: ledger) }
                .sorted { a, b in
                    let ha = Placer.effectiveHeadroom(a, cfg, now: now, ledger: ledger) ?? Int.min, hb = Placer.effectiveHeadroom(b, cfg, now: now, ledger: ledger) ?? Int.min
                    return ha != hb ? ha > hb : a.name < b.name
                }
            if let t = targets.first {
                return MoveProposal(app: c.profile, from: source.name, to: t.name, cost: StateCostTable.cost(of: c.profile, blockers: c.blockers))
            }
        }
        return nil
    }
}

/// "Once per episode, not repeated for an hour", plus "Never for this app".
public struct OfferThrottle {
    public static let quietSeconds: Double = 3600
    private var lastOffered: [String: Double] = [:]
    public private(set) var never: Set<String> = []
    public init() {}

    public mutating func neverOffer(_ appKey: String) { never.insert(appKey) }

    /// "Never for this app" outlives the process: the caller saves this text (one app key per line) and restores it at
    /// start. Keys with a newline or control character cannot be written and are skipped.
    public func serialisedNever() -> String {
        never.sorted().filter { Self.isWritable($0) }.map { $0 + "\n" }.joined()
    }

    public init(restoring text: String) {
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: { $0.isNewline }) where Self.isWritable(String(line)) { never.insert(String(line)) }
    }

    static func isWritable(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 255 && !key.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }

    /// True if an offer for this app may be shown now; records it when so.
    public mutating func shouldOffer(_ appKey: String, now: Double) -> Bool {
        if never.contains(appKey) { return false }
        if let last = lastOffered[appKey], now - last < Self.quietSeconds { return false }
        lastOffered[appKey] = now
        return true
    }
}

/// The operator's apps from the plan's section 2 snapshot (resident MB, 2026-11-20). Restore scores start untested
/// and are filled in from the E12 results.
public enum AppCatalog {
    public static let snapshot: [AppProfile] = [
        AppProfile(key: "org.mozilla.firefox", name: "Firefox", residentMB: 6714, kind: .b, offer: .onRequest),
        AppProfile(key: "com.brave.Browser", name: "Brave", residentMB: 2900, kind: .b, offer: .onRequest),
        AppProfile(key: "com.google.Chrome", name: "Google Chrome", residentMB: 1573, kind: .b, offer: .onRequest),
        AppProfile(key: "com.anthropic.claudefordesktop", name: "Claude", residentMB: 1805, kind: .c),
        // Plan 2.1 lists it at about 11 GB; offered only when asked, since it holds unsaved work.
        AppProfile(key: "com.apple.dt.Xcode", name: "Xcode", residentMB: 11264, kind: .d, offer: .onRequest),
        AppProfile(key: "claude-code", name: "Claude Code", residentMB: 939, kind: .g),
        AppProfile(key: "node-tool-servers", name: "Tool servers", residentMB: 353, kind: .service),
        AppProfile(key: "com.tinyspeck.slackmacgap", name: "Slack", residentMB: 1155, kind: .c),
        AppProfile(key: "ch.protonmail.desktop", name: "Proton Mail", residentMB: 1004, kind: .c),
        AppProfile(key: "com.hnc.Discord", name: "Discord", residentMB: 642, kind: .c),
        AppProfile(key: "de.tutao.tutanota", name: "Tuta Mail", residentMB: 440, kind: .c),
        AppProfile(key: "net.whatsapp.WhatsApp", name: "WhatsApp", residentMB: 333, kind: .c),
        // Reads local state; fixed in its own code (plan 2.6), not moved.
        AppProfile(key: "bloomgauge", name: "BloomGauge Beta", residentMB: 787, kind: .a, offer: .never),
        // Untouched on every Mac, always (plan 2.7).
        AppProfile(key: "darkbloom", name: "Darkbloom", residentMB: 1524, kind: .service, offer: .never),
        AppProfile(key: "darkbloom-sandbox", name: "DarkbloomSandbox", residentMB: 440, kind: .service, offer: .never),
    ]

    public static func profile(_ key: String) -> AppProfile? { snapshot.first { $0.key == key } }

    public static let browsers: [String] = ["org.mozilla.firefox", "com.brave.Browser", "com.google.Chrome"]
    public static let chatAndMail: [String] = ["com.tinyspeck.slackmacgap", "ch.protonmail.desktop", "com.hnc.Discord", "de.tutao.tutanota", "net.whatsapp.WhatsApp"]
    public static let claudeGroup: [String] = ["com.anthropic.claudefordesktop", "claude-code", "node-tool-servers"]

    public static func totalMB(_ keys: [String]) -> Int { keys.compactMap { profile($0)?.residentMB }.reduce(0, +) }
}
