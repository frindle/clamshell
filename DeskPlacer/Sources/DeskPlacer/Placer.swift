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
    /// The app's expected memory, if known; headroom must cover it.
    public var expectedMB: Int
    public init(seat: String, hosts: [HostSample], running: [String: String] = [:], expectedMB: Int = 0) {
        self.seat = seat; self.hosts = hosts; self.running = running; self.expectedMB = expectedMB
    }
}

public enum Placer {
    /// Eligible means pressure is green and headroom after Darkbloom's footprint plus the buffer covers the app.
    static func eligible(_ s: HostSample, _ cfg: PlacementConfig, need: Int) -> Bool {
        s.pressure == .green && cfg.headroomMB(s) >= need
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
            guard cfg.headroomMB(s) >= input.expectedMB else { return .refused(.noRoom(mac)) }
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
                let ha = cfg.headroomMB(a), hb = cfg.headroomMB(b)
                return ha != hb ? ha > hb : a.name < b.name
            }).first else { return .refused(.noHostQualifies) }
            return .run(on: best.name, reason: fellBackToSeat ? .onlyOtherChoiceWasSeat : .mostHeadroom)
        }
    }
}
