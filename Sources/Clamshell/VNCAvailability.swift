import Foundation

/// Whether the legacy VNC link can work at all. It needs the optional bridge
/// turned on AND something listening on port 5900. Clients never show or
/// auto-load a VNC link when this is false.
///
/// The listener check reads the kernel's socket table (`netstat`). It never
/// connects to 5900: that would wake Apple's on-demand daemon.
enum VNCAvailability {
    /// True when `netstat -an` output shows a LISTEN socket on port 5900.
    static func isListening(netstat output: String) -> Bool {
        output.split(separator: "\n").contains { line in
            line.contains("LISTEN") && (line.contains(".5900 ") || line.hasSuffix(".5900"))
        }
    }

    static func available(bridgeEnabled: Bool, listening: Bool?) -> Bool {
        bridgeEnabled && (listening ?? false)
    }

    /// Live answer for HOST_LOCK_STATE. Cheap enough for a per-connection call.
    static func current(defaults: UserDefaults = .standard) -> Bool {
        guard StreamMessage.legacyVNCBridgeEnabled(defaults) else { return false }
        return available(bridgeEnabled: true, listening: Self.readListening())
    }

    private static func readListening() -> Bool? {
        guard let out = ProcessRun.capture("/usr/sbin/netstat", ["-an", "-p", "tcp"], timeout: 3) else { return nil }
        return isListening(netstat: out)
    }
}

/// A small bounded subprocess runner for read-only system queries.
enum ProcessRun {
    /// Standard output, or nil when the tool is missing, fails to start or
    /// does not finish inside `timeout` seconds.
    static func capture(_ path: String, _ arguments: [String], timeout: TimeInterval) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        let timer = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        timer.cancel()
        guard task.terminationReason == .exit else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
