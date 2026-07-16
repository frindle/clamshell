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
        let end = (try? handle.seekToEnd()) ?? 0
        // Size-based rotation: keep one 5 MB generation as Clamshell.old.log.
        if end > 5_000_000 {
            try? handle.close()
            let old = url.deletingLastPathComponent().appendingPathComponent("Clamshell.old.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
            try? data.write(to: url)
            return
        }
        defer { try? handle.close() }
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: url)
    }
}

let clamshellLogPath = NSString(string: "~/Library/Logs/Clamshell.log").expandingTildeInPath
