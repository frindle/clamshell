import Foundation

/// Pure parts of the login-window probe: brightness statistics, frame diff,
/// TCC row parsing and the one-line summary. Kept free of AppKit and capture
/// so they are unit tested.
enum ProbeMath {
    /// Mean and population standard deviation of luma over an RGBA8 buffer.
    /// A flat wallpaper has a high mean but a stddev near zero, so the
    /// stddev is what says "there is something drawn here".
    static func lumaStats(rgba: [UInt8], pixelCount: Int) -> (mean: Double, stddev: Double)? {
        guard pixelCount > 0, rgba.count >= pixelCount * 4 else { return nil }
        var sum = 0.0, sumSq = 0.0
        var i = 0
        for _ in 0..<pixelCount {
            let y = luma(rgba[i], rgba[i + 1], rgba[i + 2])
            sum += y
            sumSq += y * y
            i += 4
        }
        let n = Double(pixelCount)
        let mean = sum / n
        return (mean, max(0, sumSq / n - mean * mean).squareRoot())
    }

    static func luma(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Double {
        0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
    }

    /// Number of grid cells (cols x rows over the image) in which any pixel's
    /// luma differs by more than `threshold` between two same-size RGBA8
    /// frames. A number only: no pixels leave this function.
    static func gridDiff(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int,
                         cols: Int = 32, rows: Int = 18, threshold: Double = 12) -> Int? {
        guard width > 0, height > 0, cols > 0, rows > 0,
              a.count >= width * height * 4, b.count >= width * height * 4 else { return nil }
        var changed = Set<Int>()
        for y in 0..<height {
            let cy = min(rows - 1, y * rows / height)
            for x in 0..<width {
                let cell = cy * cols + min(cols - 1, x * cols / width)
                if changed.contains(cell) { continue }
                let i = (y * width + x) * 4
                let da = luma(a[i], a[i + 1], a[i + 2])
                let db = luma(b[i], b[i + 1], b[i + 2])
                if abs(da - db) > threshold { changed.insert(cell) }
            }
        }
        return changed.count
    }

    /// Parses `service|auth_value` lines from `sqlite3` output into
    /// `Service=value` pairs (the `kTCCService` prefix dropped), sorted.
    /// Returns nil when nothing parses, so the caller reports "unreadable".
    static func parseTCCRows(_ output: String) -> [String]? {
        var rows: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 2, Int(parts[1].trimmingCharacters(in: .whitespaces)) != nil else { continue }
            var service = parts[0].trimmingCharacters(in: .whitespaces)
            if service.hasPrefix("kTCCService") { service.removeFirst("kTCCService".count) }
            guard !service.isEmpty else { continue }
            rows.append("\(service)=\(parts[1].trimmingCharacters(in: .whitespaces))")
        }
        return rows.isEmpty ? nil : rows.sorted()
    }

    struct Summary {
        var ts = "-"
        var label = "-"
        var uid = "-"
        var consoleUser = "-"
        var locked = "-"
        var captureOK: Bool?
        var lumaStddev: Double?
        var frameChanged: Int?
        var pointerMoved: Bool?
        var keyPosted: Bool?
        var keySeen: Bool?
        var screenRecording: Bool?
        var accessibility: Bool?
        var postEvent: Bool?
        var listenEvent: Bool?
        /// "unreadable", or the parsed rows joined with commas; nil means none found.
        var tcc: String = "unreadable"
    }

    /// One line per run:
    /// `ts label uid user locked= capture_ok= luma_stddev= frame_changed= pointer_moved= key_seen= sr= ax= post=`
    /// then `key_posted= listen= tcc=`.
    static func summaryLine(_ s: Summary) -> String {
        func b(_ v: Bool?) -> String { v.map { $0 ? "true" : "false" } ?? "-" }
        func n(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "-" }
        let frame = s.frameChanged.map(String.init) ?? "-"
        return "\(s.ts) \(s.label) \(s.uid) \(s.consoleUser) locked=\(s.locked) " +
            "capture_ok=\(b(s.captureOK)) luma_stddev=\(n(s.lumaStddev)) frame_changed=\(frame) " +
            "pointer_moved=\(b(s.pointerMoved)) key_seen=\(b(s.keySeen)) " +
            "sr=\(b(s.screenRecording)) ax=\(b(s.accessibility)) post=\(b(s.postEvent)) " +
            "key_posted=\(b(s.keyPosted)) listen=\(b(s.listenEvent)) tcc=\(s.tcc)"
    }
}
