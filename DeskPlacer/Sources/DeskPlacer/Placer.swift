public enum PlacementReason: Equatable {
    case localRule
    case hardwareNeed(Set<Need>)
    case home
    case mostHeadroom
    case onlyOtherChoiceWasSeat
}

public enum RefusalReason: Equatable {
    case homeUnreachable(String)
    case notGreen(String)
    case noRoom(String)
    /// The Mac's last report is too old (or dated in the future), so it is not trusted to be green.
    case staleReport([String])
    /// No measured Darkbloom footprint for these Macs, so nothing is placed on them (plan 2.7).
    case footprintUnmeasured([String])
    case noHostQualifies
}

public enum PlacementDecision: Equatable {
    case run(on: String, reason: PlacementReason)
    /// It already runs somewhere; open that copy. A second copy with the same data is never started.
    case alreadyRunning(on: String)
    case refused(RefusalReason)
}

public struct PlacerInput {
    /// The Mac Penn is at (keyboard and pointer last used).
    public var seat: String
    public var hosts: [HostSample]
    /// app key -> Mac it runs on now.
    public var running: [String: String]
    /// The app's expected memory in MB; headroom must cover it. Required: a caller that does not know the size says so
    /// by passing the catalog figure (`AppCatalog.profile(_)?.residentMB`) or a deliberate estimate.
    public var expectedMB: Int
    /// The caller's clock, on the same scale as `HostSample.sampledAt`.
    public var now: Double
    /// Launches already decided but possibly not yet visible in the readings (see `LaunchLedger`).
    public var ledger: LaunchLedger
    public init(seat: String, hosts: [HostSample], running: [String: String], expectedMB: Int, now: Double, ledger: LaunchLedger = LaunchLedger()) {
        self.seat = seat; self.hosts = hosts; self.running = running; self.expectedMB = expectedMB; self.now = now; self.ledger = ledger
    }
}

/// Memory promised to apps that were placed on a Mac but may not show in its readings yet. Without it, two decisions
/// made from the same reading both see the same free memory and can fill a Mac twice over.
/// An entry stops counting once the Mac reports a reading taken `settleSeconds` or more after the launch.
public struct LaunchLedger: Equatable {
    public static let settleSeconds: Double = 45
    public static let maxAgeSeconds: Double = 300
    struct Entry: Equatable { var app: String; var host: String; var mb: Int; var at: Double }
    private(set) var entries: [Entry] = []
    public init() {}

    public mutating func record(app: String, host: String, mb: Int, at: Double) {
        entries.append(Entry(app: app, host: host, mb: PlacementConfig.clampMB(mb), at: at))
    }

    /// Memory still to be subtracted for `sample`'s Mac. The reading `sample` already includes launches older than
    /// `settleSeconds` before it; newer ones, and any launch when the reading is older than the launch, still count.
    public func reservedMB(for sample: HostSample, now: Double) -> Int {
        var total = 0
        for e in entries where e.host == sample.name && now - e.at <= Self.maxAgeSeconds && sample.sampledAt < e.at + Self.settleSeconds {
            total = min(total + e.mb, PlacementConfig.maxMB)
        }
        return total
    }

    public mutating func forget(before cutoff: Double) { entries.removeAll { $0.at < cutoff } }
}

public enum Placer {
    /// Eligible means pressure is green and headroom after Darkbloom's footprint plus the buffer covers the app.
    static func eligible(_ s: HostSample, _ cfg: PlacementConfig, need: Int, now: Double, ledger: LaunchLedger = LaunchLedger()) -> Bool {
        guard cfg.isFresh(s, now: now), let h = effectiveHeadroom(s, cfg, now: now, ledger: ledger) else { return false }
        return s.pressure == .green && h >= PlacementConfig.clampMB(need)
    }

    /// Headroom minus what earlier decisions already promised on that Mac.
    static func effectiveHeadroom(_ s: HostSample, _ cfg: PlacementConfig, now: Double, ledger: LaunchLedger) -> Int? {
        cfg.headroomMB(s).map { $0 - ledger.reservedMB(for: s, now: now) }
    }

    /// Decides and, when the answer is a run on another Mac's memory, records it so the next decision sees it.
    public static func decideAndRecord(app: String, config cfg: PlacementConfig, input: PlacerInput, ledger: inout LaunchLedger) -> PlacementDecision {
        var inp = input
        inp.ledger = ledger
        let d = decide(app: app, config: cfg, input: inp)
        if case .run(let host, _) = d { ledger.record(app: app, host: host, mb: input.expectedMB, at: input.now) }
        return d
    }

    public static func decide(app: String, config cfg: PlacementConfig, input: PlacerInput) -> PlacementDecision {
        if let where_ = input.running[app] { return .alreadyRunning(on: where_) }
        let (placement, needs) = cfg.resolve(app)
        if !needs.isEmpty { return .run(on: input.seat, reason: .hardwareNeed(needs)) }
        switch placement {
        case .local:
            return .run(on: input.seat, reason: .localRule)
        case .home(let mac):
            guard let s = input.hosts.first(where: { $0.name == mac }) else { return .refused(.homeUnreachable(mac)) }
            guard cfg.isFresh(s, now: input.now) else { return .refused(.staleReport([mac])) }
            guard s.pressure == .green else { return .refused(.notGreen(mac)) }
            guard let h = effectiveHeadroom(s, cfg, now: input.now, ledger: input.ledger) else { return .refused(.footprintUnmeasured([mac])) }
            guard h >= input.expectedMB else { return .refused(.noRoom(mac)) }
            return .run(on: mac, reason: .home)
        case .anywhere(let avoidSeat):
            let ok = input.hosts.filter { eligible($0, cfg, need: input.expectedMB, now: input.now, ledger: input.ledger) }
            let pool: [HostSample]
            var fellBackToSeat = false
            if avoidSeat {
                let others = ok.filter { $0.name != input.seat }
                pool = others.isEmpty ? ok : others
                fellBackToSeat = others.isEmpty && !ok.isEmpty
            } else {
                pool = ok
            }
            // Most headroom; ties go to the lower name so the answer never depends on input order.
            guard let best = pool.sorted(by: { a, b in
                let ha = effectiveHeadroom(a, cfg, now: input.now, ledger: input.ledger) ?? Int.min, hb = effectiveHeadroom(b, cfg, now: input.now, ledger: input.ledger) ?? Int.min
                return ha != hb ? ha > hb : a.name < b.name
            }).first else {
                let stale = input.hosts.filter { !cfg.isFresh($0, now: input.now) && cfg.isMeasured($0.name) }.map { $0.name }.sorted()
                if !stale.isEmpty && input.hosts.filter({ cfg.isFresh($0, now: input.now) }).isEmpty { return .refused(.staleReport(stale)) }
                let unmeasured = input.hosts.filter { $0.pressure == .green && !cfg.isMeasured($0.name) }.map { $0.name }.sorted()
                return .refused(unmeasured.isEmpty ? .noHostQualifies : .footprintUnmeasured(unmeasured))
            }
            return .run(on: best.name, reason: fellBackToSeat ? .onlyOtherChoiceWasSeat : .mostHeadroom)
        }
    }
}
