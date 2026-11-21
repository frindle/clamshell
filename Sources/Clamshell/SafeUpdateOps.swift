import Foundation
import Darwin
import ServiceManagement

/// Side effects of the safe-update path: the `status`, `update`, `rollback`
/// and internal `health-watch` commands, the rollback swap, restarting the
/// app, and the login launch agent. Decisions live in `SafeUpdate`.
enum SafeUpdateOps {
    // MARK: small helpers

    static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }

    static func version(ofApp path: String) -> String {
        let plist = NSDictionary(contentsOfFile: path + "/Contents/Info.plist")
        return (plist?["CFBundleShortVersionString"] as? String) ?? "unknown"
    }

    @discardableResult
    static func capture(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// True when something accepts a TCP connection on 127.0.0.1:port.
    static func portAnswers(_ port: UInt16, timeout: TimeInterval = 1) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&p, 1, Int32(timeout * 1000)) > 0 else { return false }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0
    }

    static func pids(ofApp appPath: String) -> [Int32] {
        let pattern = NSRegularExpression.escapedPattern(for: appPath + "/Contents/MacOS/Clamshell") + "$"
        return SafeUpdate.parsePIDs(capture("/usr/bin/pgrep", ["-f", pattern]).output, excluding: getpid())
    }

    static func processExists(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    static var guiDomain: String { "gui/\(getuid())" }

    static var agentLoaded: Bool {
        capture("/bin/launchctl", ["print", "\(guiDomain)/\(SafeUpdate.agentLabel)"]).status == 0
    }

    // MARK: records

    static func readRecord() -> SafeUpdate.Record? {
        guard let data = try? Data(contentsOf: SafeUpdate.statusFile(in: HostState.directory)) else { return nil }
        return SafeUpdate.decode(SafeUpdate.Record.self, from: data)
    }

    static func writeRecord(from: String, to: String, result: String, reason: String? = nil) {
        let dir = HostState.directory
        try? HostState.prepare(dir)
        let record = SafeUpdate.Record(at: Date(), from: from, to: to, result: result, reason: reason)
        if let data = SafeUpdate.encode(record) {
            try? data.write(to: SafeUpdate.statusFile(in: dir), options: .atomic)
        }
        clog("update record: \(record.line)")
    }

    static func writePending(_ p: SafeUpdate.Pending) {
        let dir = HostState.directory
        try? HostState.prepare(dir)
        if let data = SafeUpdate.encode(p) {
            try? data.write(to: SafeUpdate.pendingFile(in: dir), options: .atomic)
        }
    }

    static func readPending() -> SafeUpdate.Pending? {
        guard let data = try? Data(contentsOf: SafeUpdate.pendingFile(in: HostState.directory)) else { return nil }
        return SafeUpdate.decode(SafeUpdate.Pending.self, from: data)
    }

    static func clearPending() {
        try? FileManager.default.removeItem(at: SafeUpdate.pendingFile(in: HostState.directory))
    }

    // MARK: restart and rollback

    /// Starts the app at `appPath` fresh. Under the launch agent that is a
    /// kickstart (the old process is replaced, KeepAlive keeps it up).
    /// Otherwise: end the other instances if asked, then `open -n`.
    static func restart(appPath: String, killOthers: Bool) {
        if agentLoaded {
            _ = capture("/bin/launchctl", ["kickstart", "-k", "\(guiDomain)/\(SafeUpdate.agentLabel)"])
            return
        }
        if killOthers {
            let old = pids(ofApp: appPath)
            for pid in old { kill(pid, SIGTERM) }
            let deadline = Date().addingTimeInterval(5)
            while old.contains(where: processExists), Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        }
        _ = capture("/usr/bin/open", ["-n", appPath])
    }

    /// For a rollback: every Clamshell process from `appPath` goes away
    /// (SIGTERM, up to 5 s, then SIGKILL) whether or not the launch agent
    /// manages it. Returns the PIDs that were there.
    @discardableResult
    static func endAllInstances(appPath: String) -> [Int32] {
        let old = pids(ofApp: appPath)
        for pid in old { kill(pid, SIGTERM) }
        let start = Date()
        while true {
            let alive = old.filter(processExists)
            switch RollbackRestart.nextStep(alive: alive, elapsed: Date().timeIntervalSince(start)) {
            case .done:
                return old
            case .wait:
                Thread.sleep(forTimeInterval: 0.2)
            case .kill(let stuck):
                clog("update: \(stuck.count) process(es) ignored SIGTERM — sending SIGKILL")
                for pid in stuck { kill(pid, SIGKILL) }
                Thread.sleep(forTimeInterval: 0.5)
                return old
            }
        }
    }

    /// Rollback relaunch: end every old process, start the installed app and
    /// check that a different process is running. True when it is.
    @discardableResult
    static func restartAfterRollback(appPath: String) -> Bool {
        let old = endAllInstances(appPath: appPath)
        restart(appPath: appPath, killOthers: false)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if RollbackRestart.relaunched(before: old, now: pids(ofApp: appPath)) {
                clog("update: rollback relaunched the installed app")
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        clog("update: rollback could not confirm a new process (old: \(old.count))")
        return false
    }

    static func signatureValid(_ app: String) -> Bool {
        capture("/usr/bin/codesign", ["--verify", "--deep", "--strict", app]).status == 0
    }

    struct OpError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    /// Swaps the kept previous bundle into `installed` and moves the current
    /// one aside. Signature and identity are checked first.
    static func rollbackSwap(installed: String, previous: String) throws {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: previous)
        let plan = SafeUpdate.rollbackPlan(
            previousExists: exists,
            signatureValid: exists && signatureValid(previous),
            // With nothing installed there is no identity to compare to.
            sameIdentity: exists && (!fm.fileExists(atPath: installed)
                                     || CodeIdentity.sameIdentity(current: installed, candidate: previous)))
        if case .unavailable(let why) = plan { throw OpError(why) }

        let aside = NSTemporaryDirectory() + "clamshell-old-\(UUID().uuidString).app"
        if fm.fileExists(atPath: installed) {
            do { try fm.moveItem(atPath: installed, toPath: aside) } catch {
                throw OpError("could not move the installed app aside (\(error.localizedDescription)) — nothing changed")
            }
        }
        do { try fm.moveItem(atPath: previous, toPath: installed) } catch {
            try? fm.moveItem(atPath: aside, toPath: installed)
            throw OpError("could not move the previous version into place (\(error.localizedDescription)) — nothing changed")
        }
    }

    // MARK: commands

    static func run(_ args: [String], out: @escaping (String) -> Void = { print($0) }) -> Int32 {
        switch SafeUpdate.parse(args) {
        case .usage(let u):
            out(u)
            return 64
        case .status:
            return status(out: out)
        case .update(let version):
            return update(version: version, out: out)
        case .rollback:
            return rollback(out: out)
        case .healthWatch(let app, let timeout):
            return healthWatch(app: app, timeout: timeout)
        }
    }

    static func status(out: (String) -> Void) -> Int32 {
        let app = Bundle.main.bundlePath
        out("version: \(currentVersion)")
        let running = pids(ofApp: app)
        out("pid: " + (running.isEmpty ? "not running" : running.map(String.init).joined(separator: ", ")))
        let ports = SafeUpdate.statusPorts.map { "\($0) \(portAnswers($0) ? "yes" : "no")" }
        out("serving: " + ports.joined(separator: ", "))
        out("launch agent: " + (agentLoaded ? "loaded" : "not loaded"))
        let prev = SafeUpdate.previousBundle(in: HostState.directory).path
        out("previous version kept: " + (FileManager.default.fileExists(atPath: prev) ? version(ofApp: prev) : "none"))
        out("last update: " + (readRecord()?.line ?? "none recorded"))
        return 0
    }

    static func update(version: String?, out: @escaping (String) -> Void) -> Int32 {
        guard UpdateInstaller.canInstall else {
            out("Not running from an .app bundle; nothing to update.")
            return 1
        }
        let sema = DispatchSemaphore(value: 0)
        var code: Int32 = 1
        UpdateInstaller.install(version: version, mode: .cli, completion: { message in
            out("Update failed: \(message)")
            code = 1
            sema.signal()
        }, success: { newVersion in
            out("Updated to \(newVersion). The new build is restarting; `clamshell status` shows the health check result within 90 seconds.")
            code = 0
            sema.signal()
        })
        // The download and install run on URLSession and global queues; wait here.
        sema.wait()
        return code
    }

    static func rollback(out: (String) -> Void) -> Int32 {
        let installed = Bundle.main.bundlePath
        let previous = SafeUpdate.previousBundle(in: HostState.directory).path
        let from = currentVersion
        let to = FileManager.default.fileExists(atPath: previous) ? version(ofApp: previous) : "unknown"
        do {
            try rollbackSwap(installed: installed, previous: previous)
        } catch {
            out("Rollback not done: \(error)")
            return 1
        }
        writeRecord(from: from, to: to, result: "manual-rollback")
        clearPending()
        let up = restartAfterRollback(appPath: installed)
        out("Rolled back from \(from) to \(to)" + (up ? " and restarted." : "; the restart could not be confirmed."))
        return 0
    }

    /// Runs from the previous (known good) bundle after an update. Polls until
    /// the new build serves or the timeout passes, then rolls back.
    static func healthWatch(app: String, timeout: TimeInterval) -> Int32 {
        guard let pending = readPending() else { return 0 }
        let previous = SafeUpdate.previousBundle(in: HostState.directory).path
        while true {
            let state = SafeUpdate.decide(
                startedAt: pending.startedAt, now: Date(),
                oldGone: pending.oldPID <= 0 || !processExists(pending.oldPID),
                webUp: portAnswers(SafeUpdate.webPort),
                streamUp: SafeUpdate.streamPorts.contains { portAnswers($0) },
                timeout: timeout)
            switch state {
            case .waiting:
                Thread.sleep(forTimeInterval: 2)
            case .stale:
                clearPending()
                return 0
            case .healthy:
                writeRecord(from: pending.from, to: pending.to, result: "ok")
                clearPending()
                return 0
            case .rollback(let reason):
                do {
                    try rollbackSwap(installed: app, previous: previous)
                    writeRecord(from: pending.from, to: pending.to, result: "rolled-back", reason: reason)
                    clearPending()
                    restartAfterRollback(appPath: app)
                    return 0
                } catch {
                    writeRecord(from: pending.from, to: pending.to, result: "failed",
                                reason: "\(reason); rollback not possible: \(error)")
                    clearPending()
                    return 1
                }
            }
        }
    }

    /// Starts the watcher from the previous bundle's own binary, so it does
    /// not depend on the build it is watching.
    static func startHealthWatcher(installed: String, previous: String) {
        let binary = previous + "/Contents/MacOS/Clamshell"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        task.arguments = ["health-watch", "--app", installed]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        do { try task.run() } catch { clog("update: could not start the health watcher: \(error)") }
    }
}

/// The login launch agent: restarts the app after a crash, not after a clean
/// quit. Uses `SMAppService.agent` with the plist bundled in
/// `Contents/Library/LaunchAgents`; if that cannot be registered (free
/// signing, not in /Applications) it writes a plain agent plist to
/// `~/Library/LaunchAgents` and loads it with launchctl.
enum LaunchAgentSetup {
    enum Method: Equatable { case serviceManagement, fallbackPlist }

    private static var service: SMAppService { SMAppService.agent(plistName: SafeUpdate.agentPlistName) }

    static var isEnabled: Bool {
        switch service.status {
        case .enabled, .requiresApproval: return true
        default: break
        }
        return FileManager.default.fileExists(atPath: SafeUpdate.fallbackAgentURL().path)
    }

    /// True when this process was started by the agent.
    static var isLaunchedByAgent: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == SafeUpdate.agentLabel
    }

    @discardableResult
    static func enable() -> Method? {
        do {
            try service.register()
            clog("launch agent: registered with SMAppService (status \(service.status.rawValue))")
            return .serviceManagement
        } catch {
            clog("launch agent: SMAppService registration failed (\(error.localizedDescription)); using ~/Library/LaunchAgents")
        }
        return enableFallback() ? .fallbackPlist : nil
    }

    private static func enableFallback() -> Bool {
        let url = SafeUpdate.fallbackAgentURL()
        let exe = Bundle.main.bundlePath + "/Contents/MacOS/Clamshell"
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try SafeUpdate.fallbackAgentPlist(executable: exe).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            clog("launch agent: could not write \(url.path): \(error)")
            return false
        }
        let r = SafeUpdateOps.capture("/bin/launchctl", ["bootstrap", SafeUpdateOps.guiDomain, url.path])
        if r.status != 0 { clog("launch agent: launchctl bootstrap returned \(r.status) (already loaded, or loads at next login)") }
        return true
    }

    static func disable() {
        try? service.unregister()
        let url = SafeUpdate.fallbackAgentURL()
        if FileManager.default.fileExists(atPath: url.path) {
            _ = SafeUpdateOps.capture("/bin/launchctl", ["bootout", "\(SafeUpdateOps.guiDomain)/\(SafeUpdate.agentLabel)"])
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Moves this running instance under the agent: after a pause, the agent
    /// is kickstarted (replacing this process) and this one quits.
    static func handOff() {
        guard !isLaunchedByAgent else { return }
        // Quit only when launchd really has the job. An agent still waiting
        // for approval in Login Items, or a bootstrap that failed, would
        // leave nothing running, and this Mac is often reached remotely.
        guard SafeUpdateOps.agentLoaded else {
            clog("launch agent: not loaded yet (status \(service.status.rawValue)); this instance keeps running")
            return
        }
        let target = "\(SafeUpdateOps.guiDomain)/\(SafeUpdate.agentLabel)"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 3; /bin/launchctl kickstart -k '\(target)'"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { clog("launch agent: hand-off failed: \(error)"); return }
        clog("launch agent: handing this instance over to the agent")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
    }

    /// Users who had "Start at Login" on (the old login item) move to the
    /// agent once. Does nothing when the login item was never on.
    static func migrateFromLoginItem() {
        guard SMAppService.mainApp.status == .enabled else { return }
        try? SMAppService.mainApp.unregister()
        guard enable() != nil else {
            // Put the old setting back rather than lose start-at-login.
            try? SMAppService.mainApp.register()
            return
        }
        // Not running under launchd yet (for example, waiting for approval in
        // Login Items): keep the old login item until it is, so a reboot
        // still starts the app.
        guard SafeUpdateOps.agentLoaded else {
            try? SMAppService.mainApp.register()
            return
        }
        handOff()
    }
}
