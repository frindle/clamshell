import DeskPlacer
import DeskProtocol

enum MoveCommand {
    /// How long to wait for a clean quit, and how often to look.
    static let quitTimeoutSeconds: Double = 30
    static let pollSeconds: Double = 0.5

    static func move(_ query: String, to target: String, yes: Bool, moveAnyway: Bool, ctx: DeskContext) -> Int32 {
        let p = ctx.ports
        let gathered = Hosts.gather(ctx)
        let now = p.clock.now()
        let resolved = AppNames.resolve(query, catalog: ctx.catalog)
        let key = resolved?.key ?? query
        var live: [String: Int] = [:]
        for r in gathered.reports where r.sample.name == ctx.thisMac {
            for a in r.apps where a.bundleId == key { live[key] = Int(a.residentMB) }
        }
        let outcome = MovePlanner.plan(query: query, target: target, moveAnyway: moveAnyway, ctx: ctx,
                                       hosts: gathered.reports.map { $0.sample },
                                       running: Hosts.running(ctx, reports: gathered.reports, keys: [key]),
                                       liveMB: live, now: now)
        switch outcome {
        case .refused(let rs):
            p.out.errorLine("desk: will not move \(resolved?.name ?? query) to \(target).")
            for r in rs { p.out.errorLine("  " + r.text) }
            return ExitCode.refused
        case .plan(let plan):
            return show(plan, yes: yes, ctx: ctx)
        }
    }

    private static func show(_ plan: MovePlan, yes: Bool, ctx: DeskContext) -> Int32 {
        let p = ctx.ports
        let out = p.out
        let name = plan.app.name
        out.line("Move \(name) from \(plan.from) to \(plan.to)")
        out.line("")
        for n in plan.notes { out.line("  " + n) }
        if !plan.lost.isEmpty {
            out.line("")
            out.line("Will be lost:")
            for l in plan.lost { out.line("  - " + l) }
        }
        if !plan.atRisk.isEmpty {
            out.line("")
            out.line("At risk:")
            for l in plan.atRisk { out.line("  - " + l) }
        }
        out.line("")
        out.line("Steps:")
        for (i, s) in plan.steps.enumerated() { out.line("  \(i + 1). " + s.label + (s.isLocal ? "" : " (on \(plan.to))")) }
        if !plan.unavailable.isEmpty {
            out.line("")
            out.line("Cannot be done yet:")
            for u in plan.unavailable { out.line("  - " + u) }
        }
        out.line("")
        guard yes else {
            out.line("Dry run. Nothing was changed. Add --yes to move.")
            return ExitCode.ok
        }
        if !plan.unavailable.isEmpty {
            out.errorLine("desk: not moved. \(name) was not quit, because the target cannot do every step.")
            return ExitCode.refused
        }
        return execute(plan, ctx: ctx)
    }

    private static func execute(_ plan: MovePlan, ctx: DeskContext) -> Int32 {
        let p = ctx.ports
        let key = plan.app.key
        var quitDone = false
        var started = false
        for (i, step) in plan.steps.enumerated() {
            p.out.line("[\(i + 1)/\(plan.steps.count)] " + step.label)
            do {
                switch step {
                case .enableKeepWindows:
                    try p.defaults.setKeepsWindows(bundleId: key, true)
                case .quit:
                    try p.apps.requestQuit(bundleId: key)
                    var waited = 0.0
                    while p.apps.isRunning(bundleId: key) {
                        if waited >= quitTimeoutSeconds {
                            p.out.errorLine("desk: \(plan.app.name) did not quit within \(Int(quitTimeoutSeconds)) seconds. It may be asking about unsaved work. Nothing was forced and nothing was started on \(plan.to).")
                            return ExitCode.failure
                        }
                        p.clock.sleep(pollSeconds)
                        waited += pollSeconds
                    }
                    quitDone = true
                default:
                    try p.remote.perform(step, bundleId: key, on: plan.to)
                    if case .start = step { started = true }
                }
            } catch {
                p.out.errorLine("desk: step failed: \(step.label). \(error)")
                if started {
                    p.out.errorLine("desk: \(plan.app.name) is already running on \(plan.to). Only this last step did not finish.")
                } else if quitDone {
                    // The app is closed here and did not open there. Bring it back here rather than leave it nowhere.
                    do {
                        try p.launcher.launch(.app(bundleId: key), with: nil)
                        p.out.errorLine("desk: \(plan.app.name) was opened again on \(plan.from).")
                    } catch {
                        p.out.errorLine("desk: could not open \(plan.app.name) again on \(plan.from). \(error)")
                    }
                }
                return ExitCode.failure
            }
        }
        p.out.line("Moved \(plan.app.name) to \(plan.to).")
        return ExitCode.ok
    }
}
