import Foundation

/// `clamshell devices | approve | deny | revoke | forget`: the device list
/// from a terminal, for a Mac that can be reached over SSH but not seen.
/// These touch only the state directory; a running Clamshell notices the
/// change by itself.
enum DeviceCommands {
    static let names: Set<String> = ["devices", "approve", "deny", "revoke", "forget"]

    static let usage = """
        Usage: clamshell devices
               clamshell approve <fingerprint or id>
               clamshell deny    <fingerprint or id>
               clamshell revoke  <fingerprint or id>
               clamshell forget  <fingerprint or id>
        """

    /// `args` starts with the command name. Returns the exit code: 0 done,
    /// 1 not done, 64 not understood.
    static func run(_ args: [String], auth: HostAuth? = nil,
                    out: (String) -> Void = { print($0) }) -> Int32 {
        guard let command = args.first, names.contains(command) else {
            out(usage)
            return 64
        }
        let auth = auth ?? HostAuth(directory: HostState.directory, watch: false)
        let store = auth.store
        guard store.canPersist else {
            out("The device list in \(store.directory.path) cannot be used. See ~/Library/Logs/Clamshell.log.")
            return 1
        }
        if store.listIsFromNewerVersion {
            out(newerVersionMessage(store))
            return 1
        }
        if command == "devices" {
            guard args.count == 1 else { out(usage); return 64 }
            list(auth, out: out)
            return 0
        }
        guard args.count == 2 else { out(usage); return 64 }

        let device: DeviceRecord
        switch store.resolve(args[1]) {
        case .badQuery:
            out("Give the device's fingerprint (like AB12-CD34-EF56-7890) or its full 64-character id.")
            return 64
        case .none:
            out("No device matches \(args[1]). Run `clamshell devices` to see them.")
            return 1
        case .ambiguous(let hits):
            out("More than one device matches. Use the full id:")
            for d in hits { out("  \(d.id)  \(quoted(d.label))") }
            return 1
        case .one(let d):
            device = d
        }
        let who = "\(quoted(device.label)) \(device.fingerprint)"

        switch command {
        case "approve":
            if device.state == .trusted { out("\(who) is already trusted."); return 0 }
            guard store.decide(id: device.id, .approve, by: DeviceTrustStore.decidedOnCommandLine,
                               onlyIfWaiting: false) != nil else { return notSaved(store, out) }
            out("Approved \(who).")
        case "deny":
            if device.state == .denied { out("\(who) is already denied."); return 0 }
            if device.state == .trusted {
                out("\(who) is trusted. To take that away use: clamshell revoke \(device.fingerprint)")
                return 1
            }
            guard store.decide(id: device.id, .deny, by: DeviceTrustStore.decidedOnCommandLine,
                               onlyIfWaiting: true) != nil else { return notSaved(store, out) }
            out("Denied \(who).")
        case "revoke":
            if device.state != .trusted { out("\(who) is not trusted, so there is nothing to revoke."); return 0 }
            guard store.revoke(id: device.id, by: DeviceTrustStore.decidedOnCommandLine) != nil else {
                return notSaved(store, out)
            }
            out("Revoked \(who).")
        default: // forget
            guard store.forget(id: device.id) != nil else { return notSaved(store, out) }
            out("Forgot \(who). It can ask again.")
        }
        return 0
    }

    private static func newerVersionMessage(_ store: DeviceTrustStore) -> String {
        "The device list in \(store.directory.path) was written by a newer Clamshell. This one leaves it alone "
            + "and cannot show or change it. Update Clamshell on this Mac."
    }

    private static func notSaved(_ store: DeviceTrustStore, _ out: (String) -> Void) -> Int32 {
        switch store.lastProblem {
        case .lockNotTaken?:
            out("Nothing was changed: another process is using the device list. Try again in a moment.")
        case .newerVersion?:
            out(newerVersionMessage(store))
        default:
            out("Nothing was changed: the device list changed meanwhile or could not be saved. Run `clamshell devices` and try again.")
        }
        return 1
    }

    private static func list(_ auth: HostAuth, out: (String) -> Void) {
        let key = auth.identity.isPersistent ? "" : " (for this run only: the key could not be stored)"
        out("This Mac: \(quoted(AuthWire.cleanName(auth.hostName))), fingerprint \(auth.identity.fingerprint)\(key)")
        out(auth.requireApproval
            ? "Device approval is on."
            : "Device approval is OFF: any device that reaches this Mac can control it.")
        let all = auth.store.all()
        if all.isEmpty {
            out("")
            out("No devices yet.")
            return
        }
        let now = Date().timeIntervalSince1970
        func section(_ title: String, _ state: DeviceState, _ detail: (DeviceRecord) -> String) {
            let rows = all.filter { $0.state == state }.sorted { $0.firstSeen < $1.firstSeen }
            guard !rows.isEmpty else { return }
            out("")
            out(title)
            for d in rows { out("  \(d.fingerprint)  \(quoted(d.label))  \(detail(d))") }
        }
        section("Waiting for approval:", .waiting) {
            "from \($0.address.isEmpty ? "an unknown address" : $0.address), asked \(ago($0.firstSeen, now: now))"
        }
        section("Trusted:", .trusted) {
            "last seen \(ago($0.lastSeen, now: now))\(decided($0, verb: "approved"))"
        }
        section("Denied:", .denied) { decided($0, verb: "denied").trimmingCharacters(in: CharacterSet(charactersIn: ", ")) }
        if all.contains(where: { $0.state == .waiting }) {
            out("")
            out("Compare the fingerprint with the one the device shows, then: clamshell approve <fingerprint>")
        }
    }

    /// ", approved on this Mac" and the like; empty when nothing is recorded.
    private static func decided(_ d: DeviceRecord, verb: String) -> String {
        guard let by = d.decidedBy else { return "" }
        switch by {
        case DeviceTrustStore.decidedOnHost: return ", \(verb) on this Mac"
        case DeviceTrustStore.decidedOnCommandLine: return ", \(verb) from the command line"
        default: return ", \(verb) from device \(DeviceIdentity.fingerprint(ofId: by))"
        }
    }

    private static func quoted(_ name: String) -> String { "\u{201C}\(name)\u{201D}" }

    static func ago(_ then: Double, now: Double) -> String {
        let s = max(0, now - then)
        switch s {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(s / 60)) min ago"
        case ..<86_400: return "\(Int(s / 3600)) h ago"
        default: return "\(Int(s / 86_400)) d ago"
        }
    }
}
