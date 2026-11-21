import Foundation

/// Makes a plain VNC client (Screen Sharing.app, vnc:// links) that dials the
/// usual port reach Clamshell instead of Apple's service.
///
/// A root daemon keeps one packet-filter redirect in place: connections to
/// the standard VNC port are sent to the port where Clamshell's own RFB
/// server listens. The rule lives in an anchor named under `com.apple/`,
/// because the stock `/etc/pf.conf` already evaluates `com.apple/*` anchors;
/// nothing in /etc is edited. A macOS update can reset the packet filter, so
/// the daemon checks every few seconds and puts the rule back, and logs it.
///
/// The Screen Sharing switch stays the control: Clamshell reads it and
/// refuses or drops sessions itself (see `RemoteAccessSwitch`).
enum RedirectPolicy {
    static let anchor = "com.apple/clamshell"
    static let vncPort = 5900
    /// Where Clamshell's RFB server listens (loopback only).
    static let backendPort = 5950
    static let daemonLabel = "com.frindle.clamshell.redirect"
    static let checkInterval: TimeInterval = 15

    /// The one rule the anchor holds.
    static func rules() -> String {
        "rdr pass inet proto tcp from any to any port \(vncPort) -> 127.0.0.1 port \(backendPort)\n"
    }

    /// The stock pf.conf must evaluate `com.apple/*` redirect anchors for the
    /// rule to take effect.
    static func pfConfEvaluatesAnchor(_ pfConf: String) -> Bool {
        pfConf.split(separator: "\n").contains { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { return false }
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            return words.count >= 2 && words[0] == "rdr-anchor" && words[1] == "\"com.apple/*\""
        }
    }

    enum Action: Equatable {
        case nothing
        case load(reason: String)
    }

    /// Whether `pfctl -s nat` output holds our rule. pfctl prints a rule back
    /// in its own words (`port = 5900`), so this looks at the parts that matter.
    static func hasRedirect(_ listing: String) -> Bool {
        listing.split(separator: "\n").contains { line in
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard words.first == "rdr", words.contains("tcp") else { return false }
            guard let to = words.firstIndex(of: "->"), to + 3 < words.count else { return false }
            let before = words[..<to]
            let matchesPort = before.contains("\(vncPort)")
            return matchesPort && words[to + 1] == "127.0.0.1" && words[to + 2] == "port" && words[to + 3] == "\(backendPort)"
        }
    }

    /// What the daemon should do given what it just read from pf.
    /// `loadedRules` is the anchor's current translation rules; nil when the
    /// anchor could not be read.
    static func decide(loadedRules: String?, pfEnabled: Bool) -> Action {
        guard let loaded = loadedRules else { return .load(reason: "the Clamshell redirect could not be read; loading it") }
        if !hasRedirect(loaded) {
            return .load(reason: loaded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? "the Clamshell redirect is missing (macOS may have reset the packet filter)"
                         : "the Clamshell redirect differs from what it should be")
        }
        if !pfEnabled { return .load(reason: "the packet filter is off; turning it on") }
        return .nothing
    }
}

/// Reads and writes the packet filter. Replaceable in tests.
protocol PacketFilter {
    func loadedRules() -> String?
    func isEnabled() -> Bool
    func load(_ rules: String) -> Bool
    func enable() -> Bool
    func remove() -> Bool
    func pfConf() -> String?
}

struct SystemPacketFilter: PacketFilter {
    private let pfctl = "/sbin/pfctl"

    func loadedRules() -> String? {
        run(["-a", RedirectPolicy.anchor, "-s", "nat"])?.output
    }

    func isEnabled() -> Bool {
        run(["-s", "info"])?.output.contains("Status: Enabled") ?? false
    }

    func load(_ rules: String) -> Bool {
        run(["-a", RedirectPolicy.anchor, "-f", "-"], input: rules)?.status == 0
    }

    func enable() -> Bool {
        // -E is reference counted; already-enabled is a success.
        guard let r = run(["-E"]) else { return false }
        return r.status == 0 || r.output.contains("already enabled")
    }

    func remove() -> Bool {
        run(["-a", RedirectPolicy.anchor, "-F", "all"])?.status == 0
    }

    func pfConf() -> String? { try? String(contentsOfFile: "/etc/pf.conf", encoding: .utf8) }

    private func run(_ args: [String], input: String? = nil) -> (status: Int32, output: String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pfctl)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let inPipe = Pipe()
        if input != nil { p.standardInput = inPipe }
        do { try p.run() } catch { return nil }
        if let input {
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

enum RedirectDaemon {
    /// One pass of the daemon. Returns what it did, for the log and tests.
    @discardableResult
    static func reconcile(_ pf: PacketFilter, log: (String) -> Void = { clog("REDIRECT: \($0)") }) -> RedirectPolicy.Action {
        if let conf = pf.pfConf(), !RedirectPolicy.pfConfEvaluatesAnchor(conf) {
            log("/etc/pf.conf no longer evaluates com.apple/* redirect anchors; the redirect cannot work until it does")
        }
        let action = RedirectPolicy.decide(loadedRules: pf.loadedRules(), pfEnabled: pf.isEnabled())
        guard case .load(let reason) = action else { return action }
        log(reason)
        if !pf.load(RedirectPolicy.rules()) { log("loading the redirect failed") }
        else if !pf.enable() { log("turning the packet filter on failed") }
        else { log("redirect from port \(RedirectPolicy.vncPort) to Clamshell is in place") }
        return action
    }

    static func run(_ pf: PacketFilter = SystemPacketFilter()) -> Never {
        reconcile(pf)
        while true {
            Thread.sleep(forTimeInterval: RedirectPolicy.checkInterval)
            reconcile(pf)
        }
    }
}
