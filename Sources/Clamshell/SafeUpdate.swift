import Foundation

/// Pure parts of the safe-update path: where the previous bundle and the
/// update records live, the health-check and rollback decisions, the CLI
/// parser and the launch-agent plist. No AppKit, no processes, so they are
/// unit tested; the side effects live in `SafeUpdateOps`.
enum SafeUpdate {
    static let agentLabel = "com.frindle.clamshell.agent"
    static var agentPlistName: String { agentLabel + ".plist" }

    /// Web client port; it must answer for the new build to count as up.
    static let webPort: UInt16 = 5901
    /// Native stream port and the three web stream bridges; one bound is enough.
    static let streamPorts: [UInt16] = [5903, 5906, 5907, 5908]
    /// The ports `clamshell status` reports.
    static let statusPorts: [UInt16] = [5901, 5906, 5907, 5908]

    /// A new build must be serving this soon after the swap.
    static let healthTimeout: TimeInterval = 90
    /// A pending-update marker older than this is stale (the watcher never
    /// ran); it must never trigger a rollback of a build that has been up for hours.
    static let pendingMaxAge: TimeInterval = 600

    // MARK: paths

    static func previousBundle(in state: URL) -> URL {
        state.appendingPathComponent("previous/Clamshell.app", isDirectory: true)
    }
    static func statusFile(in state: URL) -> URL { state.appendingPathComponent("update-status.json") }
    static func pendingFile(in state: URL) -> URL { state.appendingPathComponent("update-pending.json") }

    /// GitHub release API URL: the latest release, or the tag for a version
    /// given with or without a leading `v`. nil for anything that is not a
    /// plain version.
    static func releaseAPIURL(version: String?) -> URL? {
        let base = "https://api.github.com/repos/frindle/clamshell/releases"
        guard let version else { return URL(string: base + "/latest") }
        let bare = version.hasPrefix("v") ? String(version.dropFirst()) : version
        guard !bare.isEmpty, bare.allSatisfy({ $0.isNumber || $0 == "." || $0.isLetter || $0 == "-" }),
              bare.first?.isNumber == true else { return nil }
        return URL(string: base + "/tags/v" + bare)
    }

    // MARK: records

    /// What the last update did, shown by `clamshell status`.
    struct Record: Codable, Equatable {
        var at: Date
        var from: String
        var to: String
        /// "installed" (swapped, health check pending), "ok", "rolled-back",
        /// "failed" (nothing changed) or "manual-rollback".
        var result: String
        var reason: String?

        var line: String {
            let stamp = ISO8601DateFormatter().string(from: at)
            return "\(stamp) \(from) -> \(to): \(result)" + (reason.map { " (\($0))" } ?? "")
        }
    }

    /// Written before the swap's restart; the watcher resolves it.
    struct Pending: Codable, Equatable {
        var startedAt: Date
        var from: String
        var to: String
        var oldPID: Int32
        var installedApp: String
    }

    static func encode<T: Encodable>(_ value: T) -> Data? {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try? e.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(type, from: data)
    }

    // MARK: health check

    enum Health: Equatable {
        case healthy
        case waiting
        case rollback(reason: String)
        /// The marker is too old to act on.
        case stale
    }

    /// One poll of the post-update health check.
    /// - oldGone: the pre-update process has exited, so whatever answers is the new build.
    /// - webUp / streamUp: port 5901 answers; a stream port is bound.
    static func decide(startedAt: Date, now: Date, oldGone: Bool, webUp: Bool, streamUp: Bool,
                       timeout: TimeInterval = healthTimeout, maxAge: TimeInterval = pendingMaxAge) -> Health {
        let elapsed = now.timeIntervalSince(startedAt)
        if elapsed > maxAge { return .stale }
        if oldGone && webUp && streamUp { return .healthy }
        if elapsed < timeout { return .waiting }
        var missing: [String] = []
        if !oldGone { missing.append("the old process never exited") }
        if !webUp { missing.append("web port \(webPort) not answering") }
        if !streamUp { missing.append("no stream port bound") }
        return .rollback(reason: "not serving \(Int(timeout)) s after the update: " + missing.joined(separator: ", "))
    }

    // MARK: rollback

    enum RollbackPlan: Equatable {
        case go
        case unavailable(String)
    }

    /// Whether the kept previous bundle may be swapped back. The signature
    /// check applies here exactly as it does to an update.
    static func rollbackPlan(previousExists: Bool, signatureValid: Bool, sameIdentity: Bool) -> RollbackPlan {
        guard previousExists else { return .unavailable("no previous version is kept") }
        guard signatureValid else { return .unavailable("the kept previous version failed its signature check") }
        guard sameIdentity else { return .unavailable("the kept previous version is not signed by this app's certificate") }
        return .go
    }

    /// Names in the temp folder or next to the app that a launch may delete.
    /// The kept previous bundle lives in the state folder and never matches.
    static func isStaleCopy(name: String) -> Bool {
        (name.hasPrefix("clamshell-old-") || name.hasPrefix(".Clamshell-update-")) && name.hasSuffix(".app")
    }

    // MARK: CLI

    enum Command: Equatable {
        case status
        case update(version: String?)
        case rollback
        case healthWatch(app: String, timeout: TimeInterval)
        case usage(String)
    }

    static let commandNames: Set<String> = ["status", "update", "rollback", "health-watch"]

    static let usage = """
        Usage: clamshell status
               clamshell update [--version X]
               clamshell rollback
        """

    /// `args` starts with the command name.
    static func parse(_ args: [String]) -> Command {
        guard let name = args.first else { return .usage(usage) }
        let rest = Array(args.dropFirst())
        switch name {
        case "status":
            return rest.isEmpty ? .status : .usage(usage)
        case "rollback":
            return rest.isEmpty ? .rollback : .usage(usage)
        case "update":
            if rest.isEmpty { return .update(version: nil) }
            if rest.count == 2, rest[0] == "--version", releaseAPIURL(version: rest[1]) != nil {
                return .update(version: rest[1])
            }
            return .usage(usage)
        case "health-watch":
            // Internal: started by the updater from the previous bundle.
            guard let i = rest.firstIndex(of: "--app"), i + 1 < rest.count else { return .usage(usage) }
            var timeout = healthTimeout
            if let t = rest.firstIndex(of: "--timeout"), t + 1 < rest.count, let s = Double(rest[t + 1]), s > 0 {
                timeout = s
            }
            return .healthWatch(app: rest[i + 1], timeout: timeout)
        default:
            return .usage(usage)
        }
    }

    /// pids from `pgrep` output, without our own.
    static func parsePIDs(_ output: String, excluding own: Int32) -> [Int32] {
        output.split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 != own && $0 > 1 }
    }

    // MARK: launch agent

    /// Plist for the fallback agent the app writes to `~/Library/LaunchAgents`
    /// when `SMAppService.agent` cannot be used. Mirrors the bundled plist,
    /// but names the executable by absolute path.
    static func fallbackAgentPlist(executable: String) -> String {
        let escaped = executable
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(agentLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(escaped)</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key><false/>
            </dict>
            <key>ThrottleInterval</key><integer>10</integer>
            <key>ProcessType</key><string>Interactive</string>
            <key>LimitLoadToSessionType</key><string>Aqua</string>
            <key>AbandonProcessGroup</key><true/>
        </dict>
        </plist>

        """
    }

    static func fallbackAgentURL(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/LaunchAgents/\(agentPlistName)")
    }
}
