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
    public init(seat: String, hosts: [HostSample], running: [String: String], expectedMB: Int) {
        self.seat = seat; self.hosts = hosts; self.running = running; self.expectedMB = expectedMB
    }
}

public enum Placer {
    /// Eligible means pressure is green and headroom after Darkbloom's footprint plus the buffer covers the app.
    static func eligible(_ s: HostSample, _ cfg: PlacementConfig, need: Int) -> Bool {
        guard let h = cfg.headroomMB(s) else { return false }
        return s.pressure == .green && h >= need
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
            guard s.pressure == .green else { return .refused(.notGreen(mac)) }
            guard let h = cfg.headroomMB(s) else { return .refused(.footprintUnmeasured([mac])) }
            guard h >= input.expectedMB else { return .refused(.noRoom(mac)) }
            return .run(on: mac, reason: .home)
        case .anywhere(let avoidSeat):
            let ok = input.hosts.filter { eligible($0, cfg, need: input.expectedMB) }
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
                let ha = cfg.headroomMB(a) ?? Int.min, hb = cfg.headroomMB(b) ?? Int.min
                return ha != hb ? ha > hb : a.name < b.name
            }).first else {
                let unmeasured = input.hosts.filter { $0.pressure == .green && !cfg.isMeasured($0.name) }.map { $0.name }.sorted()
                return .refused(unmeasured.isEmpty ? .noHostQualifies : .footprintUnmeasured(unmeasured))
            }
            return .run(on: best.name, reason: fellBackToSeat ? .onlyOtherChoiceWasSeat : .mostHeadroom)
        }
    }
}
