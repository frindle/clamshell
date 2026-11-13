import Foundation
import Darwin

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
        guard let xml = httpGetLocal(port: 47989, path: "/serverinfo", timeout: 1),
              !xml.isEmpty else { return false }
        if xml.contains("SUNSHINE_SERVER_BUSY") { return true }
        if let m = xml.range(of: "<currentgame>"), let e = xml.range(of: "</currentgame>") {
            return xml[m.upperBound..<e.lowerBound].trimmingCharacters(in: .whitespaces) != "0"
        }
        return false
    }

    /// A plain HTTP GET to 127.0.0.1 over a POSIX socket, so polling does not
    /// spawn curl every few seconds. nil when nothing listens (the usual case)
    /// or the answer takes longer than `timeout` seconds.
    static func httpGetLocal(port: UInt16, path: String, timeout: TimeInterval) -> String? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { return nil } // refused: not installed / not running
        let req = "GET \(path) HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
        guard send(fd, req, req.utf8.count, 0) > 0 else { return nil }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while out.count < 65536 {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return String(data: out, encoding: .utf8)
    }

    struct Connection {
        let localAddress: String
        let localPort: Int
        let remoteAddress: String
    }

    /// Parses `netstat -an` for ESTABLISHED TCP connections. netstat prints
    /// addresses as `192.168.1.5.5900` (port joined by the final dot).
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
        guard runningProcessNames().contains(where: { $0.contains("JumpConnect") || $0.contains("Jump Desktop Connect") }) else {
            return false
        }
        guard let lsof = run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:ESTABLISHED", "-a", "-c", "JumpConnect"]) else {
            return false
        }
        return lsof.split(separator: "\n").count > 1 // header + at least one socket
    }

    /// Names of all running processes via libproc, no `ps` spawn.
    static func runningProcessNames() -> [String] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return [] }
        var names: [String] = []
        var name = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(Int(got)) where pid > 0 {
            if proc_name(pid, &name, UInt32(name.count)) > 0 { names.append(String(cString: name)) }
        }
        return names
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
