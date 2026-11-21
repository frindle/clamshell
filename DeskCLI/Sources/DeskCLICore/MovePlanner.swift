import DeskPlacer
import DeskProtocol

/// What the command line works with once the rules file is read.
public struct DeskContext {
    public var ports: Ports
    public var config: PlacementConfig
    public var thisMac: String
    /// Known apps with their E12a restore scores filled in. Tests may add apps.
    public var catalog: [AppProfile]
    public init(ports: Ports, config: PlacementConfig, thisMac: String, catalog: [AppProfile] = E12a.catalog()) {
        self.ports = ports; self.config = config; self.thisMac = thisMac; self.catalog = catalog
    }
}

public enum MoveRefusal: Equatable {
    case unknownApp(String)
    case noStateCost(String)
    case protectedApp(String)
    case sameMac
    case notRunning
    case runsElsewhere(String)
    case hardwareNeed(Set<Need>)
    case ruleKeepsLocal
    case homeIsElsewhere(String)
    case pinned(PinReason)
    case blocked([Blocker])
    case target(RefusalReason)
    case noRestoreMethod

    public var text: String {
        switch self {
        case .unknownApp(let q): return "Unknown app \"\(q)\". Use its name or bundle id."
        case .noStateCost(let n): return "\(n) has no state-cost entry, so nobody knows what a move would lose."
        case .protectedApp(let n): return "\(n) is never moved."
        case .sameMac: return "The target is this Mac."
        case .notRunning: return "The app is not running on this Mac."
        case .runsElsewhere(let m): return "The app runs on \(m). Run the move on that Mac."
        case .hardwareNeed(let n): return "The rules tie it to this Mac (needs \(n.map { $0.rawValue }.sorted().joined(separator: ", ")))."
        case .ruleKeepsLocal: return "The rules file says this app always runs on the Mac you are at."
        case .homeIsElsewhere(let h): return "The rules file says this app lives on \(h)."
        case .pinned(let p):
            switch p {
            case .neverMoves: return "This app is pinned and never moves."
            case .restoreFailed: return "Its restore test failed (E12), so it is pinned."
            case .restoreUntested: return "Its restore has not been tested yet (E12), so it is pinned."
            }
        case .blocked(let bs): return "Blocked now: " + bs.map { MovePlanner.describe($0) }.joined(separator: "; ") + "."
        case .target(let r): return "Target refused: " + DeskCLICore.describe(r) + "."
        case .noRestoreMethod: return "No one-time restore method is known for this browser."
        }
    }
}

public struct MovePlan: Equatable {
    public var app: AppProfile
    public var from: String
    public var to: String
    public var steps: [RestoreStep]
    /// What the move loses, in plain words.
    public var lost: [String]
    /// What may be lost; not tested or not visible from here. Treated as at risk.
    public var atRisk: [String]
    public var notes: [String]
    /// Steps the target Mac cannot do yet (reason each). A real move stops before quitting when this is not empty.
    public var unavailable: [String]
    public var duration: String
}

public enum MoveOutcome: Equatable {
    case refused([MoveRefusal])
    case plan(MovePlan)
}

public enum MovePlanner {
    static func describe(_ b: Blocker) -> String {
        switch b {
        case .inCall: return "a call or screen share is in progress"
        case .transferInProgress: return "a download, upload or export is running"
        case .noSerialisableState: return "it has live state that cannot be saved"
        case .toolCallInFlight: return "a tool call is in flight"
        case .localTerminalJob: return "a local terminal job is running"
        case .unsavedEdits(let t): return t.isEmpty ? "unsaved changes" : "unsaved changes in " + t.map { "\"\($0)\"" }.joined(separator: ", ")
        }
    }

    static func duration(_ kind: StateKind) -> String {
        switch kind {
        case .service, .f, .g: return "under 1 second"
        case .c: return "about 4 to 8 seconds"
        case .b: return "about 8 to 20 seconds"
        case .a, .d, .e, .h: return "about 3 to 10 seconds"
        }
    }

    /// Decides whether `query` may move to `target`, and builds the warning and the steps.
    /// `hosts` holds a fresh reading per Mac, this one included. `running` maps bundle id to the Mac it runs on.
    public static func plan(query: String, target: String, moveAnyway: Bool, ctx: DeskContext, hosts: [HostSample],
                            running: [String: String], liveMB: [String: Int], now: Double) -> MoveOutcome {
        let p = ctx.ports
        if let n = Protected.name(key: query, name: query) { return .refused([.protectedApp(n)]) }
        guard let app = AppNames.resolve(query, catalog: ctx.catalog) else { return .refused([.unknownApp(query)]) }
        if let n = Protected.name(key: app.key, name: app.name) { return .refused([.protectedApp(n)]) }
        guard let profile = app.profile else { return .refused([.noStateCost(app.name)]) }
        if target == ctx.thisMac { return .refused([.sameMac]) }

        var refusals: [MoveRefusal] = []
        switch running[app.key] {
        case .none: refusals.append(.notRunning)
        case .some(let m) where m != ctx.thisMac: refusals.append(.runsElsewhere(m))
        default: break
        }

        // Rules: hardware needs and a local or home rule hold against an explicit move.
        let (_, needs) = ctx.config.resolve(app.key)
        if !needs.isEmpty { refusals.append(.hardwareNeed(needs)) }
        switch ctx.config.apps[app.key]?.placement {
        case .some(.local): if needs.isEmpty { refusals.append(.ruleKeepsLocal) }
        case .some(.home(let h)): if h != target { refusals.append(.homeIsElsewhere(h)) }
        default: break
        }

        // State cost, with what is blocking the app right now.
        var blockers = p.probe.blockers(bundleId: app.key)
        let edited = p.apps.editedWindows(bundleId: app.key)
        let editedTitles = edited ?? []
        if !editedTitles.isEmpty && !moveAnyway { blockers.append(.unsavedEdits(editedTitles)) }
        let cost = StateCostTable.cost(of: profile, blockers: blockers)
        switch cost {
        case .pinned(let r): refusals.append(.pinned(r))
        case .blocked(let bs): refusals.append(.blocked(bs))
        case .free, .cheap: break
        }

        // The target: reuse the placer's own checks (fresh report, green, measured Darkbloom, room) by treating the target as the home.
        let size = liveMB[app.key] ?? profile.residentMB
        var cfg = ctx.config
        cfg.apps[app.key] = AppRule(placement: .home(target))
        let input = PlacerInput(seat: ctx.thisMac, hosts: hosts, running: [:], expectedMB: size, now: now)
        if case .refused(let r) = Placer.decide(app: app.key, config: cfg, input: input) { refusals.append(.target(r)) }

        // How the app is brought back.
        var steps: [RestoreStep] = []
        var startArgs: [String] = []
        switch profile.kind {
        case .a:
            if p.defaults.keepsWindows(bundleId: app.key) != true { steps.append(.enableKeepWindows) }
        case .b:
            if E12a.chromium.contains(app.key) { startArgs = [E12a.restoreFlag] }
            else if app.key != E12a.firefox { refusals.append(.noRestoreMethod) }
        default: break
        }
        steps.append(.quit)
        switch profile.kind {
        case .a: steps.append(.copySavedState)
        case .b:
            steps.append(.copyProfile)
            if app.key == E12a.firefox { steps.append(.firefoxResumeOnce) }
        default: break
        }
        steps.append(.start(arguments: startArgs))
        if profile.kind == .a || profile.kind == .c || profile.kind == .d {
            if let titles = p.apps.windowTitles(bundleId: app.key) { steps.append(.closeExtraWindows(keep: titles)) }
            else { steps.append(.hideApp) }
        }

        if !refusals.isEmpty { return .refused(refusals) }

        var unavailable: [String] = []
        for s in steps where !s.isLocal {
            if let why = p.remote.canPerform(s, bundleId: app.key, on: target) { unavailable.append("\(s.label): \(why)") }
        }

        var plan = MovePlan(app: profile, from: ctx.thisMac, to: target, steps: steps, lost: [], atRisk: [], notes: [],
                            unavailable: unavailable, duration: duration(profile.kind))
        warn(&plan, edited: edited, moveAnyway: moveAnyway, keepsWindows: p.defaults.keepsWindows(bundleId: app.key),
             titlesKnown: p.apps.windowTitles(bundleId: app.key) != nil, sees: p.probe.seesCallsAndTransfers)
        return .plan(plan)
    }

    /// Fills in the warning from the state cost table and the E12a findings.
    static func warn(_ plan: inout MovePlan, edited: [String]?, moveAnyway: Bool, keepsWindows: Bool?, titlesKnown: Bool, sees: Bool) {
        let name = plan.app.name
        plan.notes.append("\(name) quits cleanly on \(plan.from), then starts on \(plan.to). This takes \(plan.duration).")
        switch plan.app.kind {
        case .service:
            plan.notes.append("It holds no state, so nothing is lost.")
        case .a:
            plan.notes.append("macOS window restore brings back windows and documents when the app saves its state on quit.")
            if keepsWindows != true {
                plan.notes.append("\"Close windows when quitting\" makes macOS drop restore data. The mover turns window restore on for \(name) only, with its own NSQuitAlwaysKeepsWindows setting, and leaves your global setting alone.")
            }
            plan.notes.append("The saved state is copied from the daemon container (one folder per app) to \(plan.to).")
            plan.atRisk.append("Whether a copied saved state restores on a different Mac is not tested yet (E12b).")
        case .b:
            plan.notes.append("The browser restores its windows and tabs once, through a one-time restore flag. Your startup setting is not changed.")
            plan.notes.append("The profile folder is copied while the browser is closed.")
            plan.lost.append("A web app whose current view is not in its address reloads to its default view.")
            plan.atRisk.append("Chrome and Brave sign-in depends on a keychain item on the target (not tested yet, E12b).")
        case .c:
            plan.notes.append("State is on the service. Reopening restores the workspace and channel.")
            plan.atRisk.append("A half-typed draft is kept by most of these apps but not checked.")
        case .d:
            plan.atRisk.append("Unsaved changes are untested for this app. Save your work first.")
        case .e:
            plan.notes.append("The browser extension records playback position and seeks to it after the restore.")
        case .f:
            plan.lost.append("A terminal loses its working folder and running commands unless it runs in a persistent session such as tmux.")
        case .g:
            plan.lost.append("A tool call in flight is lost. The session resumes with --resume.")
        case .h:
            plan.lost.append("Live state with no saved form is lost.")
        }
        if plan.app.kind == .a || plan.app.kind == .c || plan.app.kind == .d {
            plan.lost.append("Windows you had closed may open again on start. The mover \(titlesKnown ? "closes" : "hides") them afterwards.")
        }
        if let e = edited, !e.isEmpty, moveAnyway {
            plan.atRisk.append("Unsaved changes in " + e.map { "\"\($0)\"" }.joined(separator: ", ") + " (you chose to move anyway).")
        } else if edited == nil && plan.app.kind != .service && plan.app.kind != .g {
            plan.atRisk.append("This Mac cannot read which windows have unsaved changes. Treat them as at risk and save first.")
        }
        if !sees {
            plan.notes.append("This command cannot see calls or transfers yet. Make sure none is running.")
        }
    }
}
