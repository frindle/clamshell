import DeskPlacer
import DeskProtocol

public enum ExitCode {
    public static let ok: Int32 = 0
    public static let failure: Int32 = 1
    public static let usage: Int32 = 2
    /// The command understood the request and refused it.
    public static let refused: Int32 = 3
}

struct ParsedArgs {
    var positional: [String] = []
    var flags: Set<String> = []
    var values: [String: String] = [:]
}

struct UsageError: Error { var message: String }

public enum Cli {
    static let usageText = """
    usage: desk <command> [options]

      desk open <app|file|url> [--with <bundle-id>]
      desk stub-run --bundle-id <id>
      desk move <app> <mac> [--yes] [--move-anyway]
      desk mem

    options for every command:
      --mac <name>     this Mac's name in the rules file (default: DESK_MAC, else the host name)
      --rules <path>   rules file (default: DESK_RULES, else ~/.config/desk/placement.toml)

    move is a dry run unless you pass --yes.
    """

    static func parse(_ args: [String], values: Set<String>, flags: Set<String>, ignoreRest: Bool = false) throws -> ParsedArgs {
        var r = ParsedArgs()
        var i = 0
        while i < args.count {
            let a = args[i]
            if values.contains(a) {
                guard i + 1 < args.count else { throw UsageError(message: "\(a) needs a value") }
                r.values[a] = args[i + 1]
                i += 2
                continue
            }
            if flags.contains(a) { r.flags.insert(a); i += 1; continue }
            if ignoreRest { i += 1; continue }
            if a.hasPrefix("-") && a.count > 1 { throw UsageError(message: "unknown option \(a)") }
            r.positional.append(a)
            i += 1
        }
        return r
    }

    public static func run(_ argv: [String], ports: Ports) -> Int32 {
        let out = ports.out
        guard let command = argv.first else { out.errorLine(usageText); return ExitCode.usage }
        let rest = Array(argv.dropFirst())
        let common: Set<String> = ["--mac", "--rules"]
        do {
            switch command {
            case "help", "--help", "-h":
                out.line(usageText)
                return ExitCode.ok
            case "open":
                let a = try parse(rest, values: common.union(["--with"]), flags: [])
                guard a.positional.count == 1 else { throw UsageError(message: "open takes one app, file or link") }
                guard let ctx = try makeContext(a, ports) else { return ExitCode.failure }
                return OpenCommand.open(a.positional[0], with: a.values["--with"], ctx: ctx)
            case "stub-run":
                // Stubs pass the arguments macOS gave them after --bundle-id. They are not used yet.
                let a = try parse(rest, values: common.union(["--bundle-id"]), flags: [], ignoreRest: true)
                guard let id = a.values["--bundle-id"], Text.isSafeBundleId(id) else { throw UsageError(message: "stub-run needs --bundle-id <id>") }
                guard let ctx = try makeContext(a, ports) else { return ExitCode.failure }
                return OpenCommand.open(id, with: nil, ctx: ctx)
            case "move":
                let a = try parse(rest, values: common, flags: ["--yes", "--move-anyway"])
                guard a.positional.count == 2 else { throw UsageError(message: "move takes an app and a Mac") }
                guard let ctx = try makeContext(a, ports) else { return ExitCode.failure }
                return MoveCommand.move(a.positional[0], to: a.positional[1], yes: a.flags.contains("--yes"),
                                        moveAnyway: a.flags.contains("--move-anyway"), ctx: ctx)
            case "mem":
                let a = try parse(rest, values: common, flags: [])
                guard a.positional.isEmpty else { throw UsageError(message: "mem takes no arguments") }
                guard let ctx = try makeContext(a, ports) else { return ExitCode.failure }
                return MemCommand.run(ctx: ctx)
            default:
                throw UsageError(message: "unknown command \(command)")
            }
        } catch let e as UsageError {
            out.errorLine("desk: \(e.message)")
            out.errorLine(usageText)
            return ExitCode.usage
        } catch {
            out.errorLine("desk: \(error)")
            return ExitCode.failure
        }
    }

    /// Reads the rules file. A missing file means the built-in defaults. nil (after printing why) when the file is bad.
    static func makeContext(_ a: ParsedArgs, _ ports: Ports) throws -> DeskContext? {
        let mac = a.values["--mac"] ?? ports.host.environment("DESK_MAC") ?? ports.host.thisMacName()
        let path = a.values["--rules"] ?? ports.host.environment("DESK_RULES") ?? (ports.host.homeDirectory() + "/.config/desk/placement.toml")
        var config = PlacementConfig()
        if let text = ports.files.read(path) {
            do { config = try RulesFile.parse(text) }
            catch {
                ports.out.errorLine("desk: \(error)")
                return nil
            }
        }
        return DeskContext(ports: ports, config: config, thisMac: mac)
    }
}

enum Hosts {
    /// Fresh readings for this Mac and the others. The local one is nil when it cannot be read.
    static func gather(_ ctx: DeskContext) -> (reports: [PeerReport], localError: String?) {
        let p = ctx.ports
        var reports: [PeerReport] = []
        var localError: String?
        do {
            let r = try p.memory.read()
            let sample = HostSample(name: ctx.thisMac, totalMB: r.totalMB, freeMB: r.freeMB, swapUsedMB: r.swapUsedMB,
                                    pressure: r.pressure, sampledAt: p.clock.now())
            reports.append(PeerReport(sample: sample, apps: r.apps))
        } catch { localError = "\(error)" }
        if let others = try? p.peers.reports() {
            reports += others.filter { $0.sample.name != ctx.thisMac }
        }
        return (reports, localError)
    }

    /// Bundle id -> Mac it runs on. This Mac's own answer wins.
    static func running(_ ctx: DeskContext, reports: [PeerReport], keys: [String]) -> [String: String] {
        var map: [String: String] = [:]
        for r in reports where r.sample.name != ctx.thisMac {
            for a in r.apps where a.running { map[a.bundleId] = r.sample.name }
        }
        for k in keys {
            if ctx.ports.apps.isRunning(bundleId: k) { map[k] = ctx.thisMac } else if map[k] == ctx.thisMac { map[k] = nil }
        }
        return map
    }
}
