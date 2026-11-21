import Foundation

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
