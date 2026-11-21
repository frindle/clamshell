import DeskPlacer
import DeskProtocol

enum OpenCommand {
    enum Kind: Equatable {
        case app(String)
        case file(String)
        case url(String)
    }

    static func classify(_ s: String, files: any TextFiles) -> Kind {
        if Text.contains(s, "://") { return .url(s) }
        if s.hasPrefix("/") || s.hasPrefix("./") || s.hasPrefix("../") || s.hasPrefix("~/") || files.exists(s) { return .file(s) }
        return .app(s)
    }

    /// `desk open` and `desk stub-run`: place the app with the rules, then launch it here or hand it to the Desk client.
    static func open(_ what: String, with: String?, ctx: DeskContext) -> Int32 {
        let p = ctx.ports
        let kind = classify(what, files: p.files)

        // Which app handles it.
        let appQuery: String?
        let target: LaunchTarget
        switch kind {
        case .app(let q): appQuery = q; target = .app(bundleId: "")
        case .url(let u):
            appQuery = with ?? p.handlers.appFor(url: u); target = .url(u)
        case .file(let f):
            appQuery = with ?? p.handlers.appFor(file: f); target = .file(f)
        }
        guard let query = appQuery else {
            p.out.errorLine("desk: no app is chosen for \(what). Pass --with <bundle-id>.")
            return ExitCode.failure
        }
        guard let app = AppNames.resolve(query, catalog: ctx.catalog) else {
            p.out.errorLine("desk: unknown app \"\(query)\". Use its name or bundle id.")
            return ExitCode.failure
        }
        let launch: LaunchTarget
        if case .app = target { launch = .app(bundleId: app.key) } else { launch = target }
        let handler: String? = { if case .app = launch { return nil } else { return app.key } }()

        let gathered = Hosts.gather(ctx)
        let now = p.clock.now()
        let input = PlacerInput(seat: ctx.thisMac, hosts: gathered.reports.map { $0.sample },
                                running: Hosts.running(ctx, reports: gathered.reports, keys: [app.key]),
                                expectedMB: app.profile?.residentMB ?? 1024, now: now)

        switch Placer.decide(app: app.key, config: ctx.config, input: input) {
        case .refused(let r):
            p.out.errorLine("desk: not opened. " + describe(r) + ".")
            return ExitCode.failure
        case .run(let mac, _), .alreadyRunning(let mac):
            return go(launch, with: handler, on: mac, app: app.name, ctx: ctx)
        }
    }

    private static func go(_ launch: LaunchTarget, with handler: String?, on mac: String, app: String, ctx: DeskContext) -> Int32 {
        let p = ctx.ports
        do {
            if mac == ctx.thisMac {
                try p.launcher.launch(launch, with: handler)
                p.out.line("Opened \(app) on this Mac.")
            } else {
                try p.remote.open(launch, with: handler, on: mac)
                p.out.line("Opened \(app) on \(mac).")
            }
            return ExitCode.ok
        } catch {
            p.out.errorLine("desk: could not open \(app) on \(mac == ctx.thisMac ? "this Mac" : mac). \(error)")
            return ExitCode.failure
        }
    }
}
