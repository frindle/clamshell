import Foundation

/// The macOS Screen Sharing switch (System Settings > General > Sharing) is the
/// single control for remote access to this Mac, and it controls Clamshell:
/// on, Clamshell serves sessions; off, new sessions are turned away with busy
/// reason 2 (`HostBusyReason.remoteAccessOff`) and open ones are dropped.
///
/// Clamshell does not use Apple's screensharingd for anything. Only the
/// switch is read, from launchd's override database, with
/// `launchctl print-disabled system` (no root needed).
enum RemoteAccessSwitch {
    static let label = "com.apple.screensharing"

    /// Posted when the switch flips (by `RemoteAccessWatcher`).
    static let didChange = Notification.Name("com.frindle.clamshell.remoteAccessDidChange")

    /// Reads the `print-disabled` output. nil when the label is not listed
    /// (never toggled: macOS default) or the line is not understood.
    static func parse(printDisabled output: String) -> Bool? {
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.contains("\"\(label)\"") else { continue }
            if line.hasSuffix("=> enabled") || line.hasSuffix("=> false") { return true }
            if line.hasSuffix("=> disabled") || line.hasSuffix("=> true") { return false }
        }
        return nil
    }

    /// What to do when the state cannot be read: a probe that fails must not
    /// lock the owner out of their own Mac, so the answer is "on".
    static func resolve(_ parsed: Bool?) -> Bool { parsed ?? true }

    static func isEnabled() -> Bool {
        let out = ProcessRun.capture("/bin/launchctl", ["print-disabled", "system"], timeout: 3)
        return resolve(out.flatMap { parse(printDisabled: $0) })
    }

    /// What a gate does with a session that is asking in, or already open.
    enum Decision: Equatable {
        case admit
        case refuse(HostBusyReason)
    }

    static func decision(enabled: Bool) -> Decision {
        enabled ? .admit : .refuse(.remoteAccessOff)
    }

    /// One log line per change of the switch, nil when nothing changed.
    static func changeLine(from old: Bool, to new: Bool) -> String? {
        guard old != new else { return nil }
        return "REMOTE ACCESS: the Screen Sharing switch is now \(new ? "ON" : "OFF"); "
            + (new ? "new sessions are accepted again" : "new sessions are refused and open ones dropped")
    }
}

/// Watches launchd's override database and posts `RemoteAccessSwitch.didChange`
/// when the switch flips. The file is rewritten on each toggle, so a directory
/// watch fires; the state is then re-read, never assumed.
final class RemoteAccessWatcher {
    static let watchedDirectory = "/var/db/com.apple.xpc.launchd"

    private var source: DispatchSourceFileSystemObject?
    private var last: Bool
    private let read: () -> Bool
    private let queue = DispatchQueue(label: "clamshell.remote-access-watch", qos: .utility)

    init(read: @escaping () -> Bool = { RemoteAccessSwitch.isEnabled() }) {
        self.read = read
        self.last = read()
    }

    var current: Bool { queue.sync { last } }

    func start() {
        guard source == nil else { return }
        let fd = open(Self.watchedDirectory, O_EVTONLY)
        guard fd >= 0 else {
            clog("REMOTE ACCESS: cannot watch the Screen Sharing switch; checking it per connection instead")
            return
        }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend],
                                                          queue: queue)
        s.setEventHandler { [weak self] in self?.recheck() }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
        queue.async { [weak self] in self?.recheck() }
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    /// The write may land a moment after the event; read twice to settle.
    private func recheck() {
        apply(read())
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.apply(self.read())
        }
    }

    private func apply(_ now: Bool) {
        guard let line = RemoteAccessSwitch.changeLine(from: last, to: now) else { return }
        last = now
        clog(line)
        NotificationCenter.default.post(name: RemoteAccessSwitch.didChange, object: nil)
    }
}
