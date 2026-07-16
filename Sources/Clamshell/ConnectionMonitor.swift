import Foundation

/// Watches for an active remote-control session and reports transitions.
///
/// Detection is trigger-based so multiple remote services can arm the
/// collapse: Apple Screen Sharing (VNC, port 5900) and Jump Desktop Connect
/// are both supported. Polling netstat is deliberate — screensharingd runs
/// as root, so per-process APIs can't see its sockets from a user session,
/// but the kernel connection table is world-readable.
final class ConnectionMonitor {
    enum Trigger: String, CaseIterable {
        case screenSharing // Apple Screen Sharing / any VNC client, port 5900
        case jumpDesktop   // Jump Desktop Connect (Fluid protocol)
        case sunshine      // Sunshine (Moonlight client streaming)
    }

    /// Called on the main queue whenever the connected state flips.
    var onChange: ((Bool, Trigger?) -> Void)?

    /// Confined to `queue` — polling spawns netstat/lsof/curl (curl can
    /// block up to 1s), so it must never run on the main thread.
    private(set) var isConnected = false
    private var timer: DispatchSourceTimer?
    private let pollInterval: TimeInterval
    private let queue = DispatchQueue(label: "clamshell.monitor", qos: .utility)

    /// Sunshine reported busy on the previous poll (edge tracking).
    private var sunshineWasBusy = false

    init(pollInterval: TimeInterval = 2.0) {
        self.pollInterval = pollInterval
    }

    func start() {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: pollInterval)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Runs on `queue` (serial, so polls never overlap).
    private func poll() {
        var trigger = Self.detectActiveSession()
        if trigger == .sunshine {
            // SUNSHINE_SERVER_BUSY means the streaming app process is running,
            // not that a Moonlight client is attached — it stays BUSY after a
            // normal client disconnect. Arm-only: the rising edge triggers a
            // collapse, but sustained BUSY can't hold the session open, or
            // Clamshell would stay collapsed forever after a disconnect.
            // Sunshine prep-commands remain the reliable event-driven path
            // (and suppress the poll-driven restore while active).
            if sunshineWasBusy { trigger = nil }
            sunshineWasBusy = true
        } else {
            sunshineWasBusy = false
        }
        let connected = trigger != nil
        guard connected != isConnected else { return }
        isConnected = connected
        clog("remote session \(connected ? "CONNECTED" : "DISCONNECTED")\(trigger.map { " via \($0.rawValue)" } ?? "")")
        DispatchQueue.main.async { [weak self] in
            self?.onChange?(connected, trigger)
        }
    }

    // MARK: - Detection

    static func detectActiveSession() -> Trigger? {
        let established = establishedConnections()
        // Screen Sharing: any established connection with local port 5900.
        // Exclude loopback so a local VNC viewer doesn't trip the collapse.
        for conn in established {
            if conn.localPort == 5900 && !conn.remoteAddress.hasPrefix("127.")
                && conn.remoteAddress != "::1" {
                return .screenSharing
            }
        }
        // Jump Desktop Connect: its helper holds the session sockets in-process,
        // so presence of an established connection owned by JumpConnect's
        // streaming child indicates a live session.
        if jumpDesktopSessionActive() {
            return .jumpDesktop
        }
        if sunshineSessionActive() {
            return .sunshine
        }
        return nil
    }

    /// Sunshine's GameStream discovery endpoint is unauthenticated and
    /// reports state=SUNSHINE_SERVER_BUSY / currentgame != 0 while a
    /// Moonlight session is streaming. Connection-refused (Sunshine not
    /// installed/running) returns nil instantly and costs nothing.
    static func sunshineSessionActive() -> Bool {
        guard let xml = run("/usr/bin/curl", ["-s", "-m", "1", "http://127.0.0.1:47989/serverinfo"]),
              !xml.isEmpty else { return false }
        if xml.contains("SUNSHINE_SERVER_BUSY") { return true }
        if let m = xml.range(of: "<currentgame>"), let e = xml.range(of: "</currentgame>") {
            return xml[m.upperBound..<e.lowerBound].trimmingCharacters(in: .whitespaces) != "0"
        }
        return false
    }

    struct Connection {
        let localAddress: String
        let localPort: Int
        let remoteAddress: String
    }

    /// Parses `netstat -an` for ESTABLISHED TCP connections. netstat prints
    /// addresses as `10.0.12.5.5900` (port joined by the final dot).
    static func establishedConnections() -> [Connection] {
        guard let output = run("/usr/sbin/netstat", ["-an", "-p", "tcp"]) else { return [] }
        var result: [Connection] = []
        for line in output.split(separator: "\n") {
            guard line.contains("ESTABLISHED") else { continue }
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 5 else { continue }
            let local = String(cols[3])
            let remote = String(cols[4])
            guard let dot = local.lastIndex(of: "."),
                  let port = Int(local[local.index(after: dot)...]) else { continue }
            let remoteAddr: String
            if let rdot = remote.lastIndex(of: ".") {
                remoteAddr = String(remote[..<rdot])
            } else {
                remoteAddr = remote
            }
            result.append(Connection(
                localAddress: String(local[..<dot]),
                localPort: port,
                remoteAddress: remoteAddr
            ))
        }
        return result
    }

    /// Jump Desktop Connect exposes session state via its rendezvous child
    /// process holding non-loopback established sockets. Cheap heuristic:
    /// `lsof` on processes named JumpConnect with ESTABLISHED TCP. Refine
    /// against a real Jump install (open TODO).
    static func jumpDesktopSessionActive() -> Bool {
        guard let output = run("/bin/ps", ["-axo", "comm"]) else { return false }
        let hasJump = output.contains("JumpConnect") || output.contains("Jump Desktop Connect")
        guard hasJump else { return false }
        guard let lsof = run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:ESTABLISHED", "-a", "-c", "JumpConnect"]) else {
            return false
        }
        return lsof.split(separator: "\n").count > 1 // header + at least one socket
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        // Discard stderr rather than piping it — an undrained pipe can fill
        // its buffer and deadlock the child on large output.
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
