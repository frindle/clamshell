import Foundation

/// Logs to both the unified log (Console.app) and ~/Library/Logs/Clamshell.log.
/// The file is the post-test diagnostic artifact: every collapse, restore,
/// detection flip, and failure lands here with a timestamp.
func clog(_ message: String) {
    NSLog("[clamshell] %@", message)
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Clamshell.log")
    let stamp = ISO8601DateFormatter().string(from: Date())
    guard let data = "\(stamp) \(message)\n".data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: url)
    }
}

let clamshellLogPath = NSString(string: "~/Library/Logs/Clamshell.log").expandingTildeInPath
