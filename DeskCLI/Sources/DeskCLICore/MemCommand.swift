import DeskPlacer
import DeskProtocol

/// `desk mem`: per-Mac memory pressure, swap, the biggest apps that can move, and which one to move.
/// Read-only. Darkbloom is never read: it counts toward the reserve through the rules file figure only.
enum MemCommand {
    static let topCount = 5

    struct Candidate {
        var profile: AppProfile
        var mb: Int
        var blockers: [Blocker]
    }

    static func run(ctx: DeskContext) -> Int32 {
        let p = ctx.ports
        let gathered = Hosts.gather(ctx)
        if let e = gathered.localError {
            p.out.errorLine("desk: could not read memory on this Mac. \(e)")
            return ExitCode.failure
        }
        let now = p.clock.now()
        let samples = gathered.reports.map { $0.sample }
        for (i, r) in gathered.reports.enumerated() {
            if i > 0 { p.out.line("") }
            show(r, isThisMac: r.sample.name == ctx.thisMac, samples: samples, ctx: ctx, now: now)
        }
        return ExitCode.ok
    }

    /// Apps on a Mac that Desk could move, biggest first. Darkbloom, Terminal and Clamshell never appear.
    static func candidates(_ apps: [AppInfo], isThisMac: Bool, ctx: DeskContext) -> [Candidate] {
        var out: [Candidate] = []
        for a in apps {
            if Protected.name(key: a.bundleId, name: a.name) != nil { continue }
            guard let profile = ctx.catalog.first(where: { $0.key == a.bundleId }) else { continue }
            let (_, needs) = ctx.config.resolve(profile.key)
            if !needs.isEmpty { continue }
            if ctx.config.apps[profile.key]?.placement == .local { continue }
            let blockers = isThisMac ? ctx.ports.probe.blockers(bundleId: profile.key) : []
            if !StateCostTable.cost(of: profile, blockers: blockers).isMovable { continue }
            out.append(Candidate(profile: profile, mb: Int(a.residentMB), blockers: blockers))
        }
        return out.sorted { $0.mb != $1.mb ? $0.mb > $1.mb : $0.profile.key < $1.profile.key }
    }

    static func show(_ r: PeerReport, isThisMac: Bool, samples: [HostSample], ctx: DeskContext, now: Double) {
        let out = ctx.ports.out
        let cfg = ctx.config
        let s = r.sample
        out.line(s.name + (isThisMac ? " (this Mac)" : ""))
        guard cfg.isFresh(s, now: now) else {
            out.line("  The last report is too old to trust. Nothing is shown for this Mac.")
            return
        }
        out.line("  memory pressure: " + Text.pressure(s.pressure))
        out.line("  swap used:       " + Text.mb(s.swapUsedMB))
        out.line("  memory:          \(Text.mb(s.totalMB)) total, \(Text.mb(s.freeMB)) free or reclaimable")
        if let reserve = cfg.reserveMB(on: s.name), let head = cfg.headroomMB(s) {
            let dark = reserve - PlacementConfig.clampMB(cfg.reserveBufferMB)
            out.line("  reserve:         \(Text.mb(reserve)) (Darkbloom \(Text.mb(dark)) from the rules file, plus \(Text.mb(cfg.reserveBufferMB)) buffer)")
            out.line("  headroom:        " + Text.mb(head))
        } else {
            out.line("  reserve:         Darkbloom's footprint is not measured on this Mac, so it receives nothing")
        }

        let cands = candidates(r.apps, isThisMac: isThisMac, ctx: ctx)
        if cands.isEmpty {
            out.line("  movable apps:    none")
        } else {
            out.line("  movable apps (biggest first):")
            for c in cands.prefix(topCount) {
                let how = c.profile.offer == .onRequest ? "only when you ask" : "can be offered"
                out.line("    \(Text.pad(c.profile.name, 18)) \(Text.pad(Text.mb(c.mb), 9)) \(how)")
            }
        }

        let short = MoveAdvisor.isShort(s, cfg, now: now)
        if !short {
            out.line("  move suggestion: none, this Mac is not short of memory")
            return
        }
        var why: [String] = []
        if s.pressure != .green { why.append("pressure is \(Text.pressure(s.pressure))") }
        if s.swapUsedMB >= cfg.swapThresholdMB { why.append("swap is \(Text.mb(s.swapUsedMB))") }
        let running = cands.map { RunningApp(profile: $0.profile, blockers: $0.blockers, liveResidentMB: $0.mb) }
        let others = samples.filter { $0.name != s.name }
        if let m = MoveAdvisor.propose(from: s, running: running, others: others, config: cfg, now: now) {
            let size = cands.first(where: { $0.profile.key == m.app.key })?.mb ?? m.app.residentMB
            out.line("  move suggestion: move \(m.app.name) (\(Text.mb(size))) to \(m.to), because " + why.joined(separator: " and "))
        } else {
            out.line("  move suggestion: short of memory (" + why.joined(separator: " and ") + "), but no app can move to a Mac with room")
        }
    }
}
