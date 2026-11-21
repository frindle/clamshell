import DeskPlacer

// Small helpers, the E12a results, and the rules about which apps may never move.

enum Text {
    /// "512 MB", "6.7 GB". Negative figures keep their sign.
    static func mb(_ value: Int) -> String {
        if value < 0 { return "-" + mb(-value) }
        if value < 1024 { return "\(value) MB" }
        let tenths = (value * 10 + 512) / 1024
        return "\(tenths / 10).\(tenths % 10) GB"
    }

    static func contains(_ haystack: String, _ needle: String) -> Bool {
        if needle.isEmpty { return true }
        let h = Array(haystack.utf8), n = Array(needle.utf8)
        if n.count > h.count { return false }
        for start in 0...(h.count - n.count) where Array(h[start..<(start + n.count)]) == n { return true }
        return false
    }

    static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }

    static func pressure(_ p: MemoryPressure) -> String {
        switch p {
        case .green: return "green"
        case .yellow: return "yellow"
        case .red: return "red"
        }
    }

    static func isSafeBundleId(_ s: String) -> Bool {
        guard !s.isEmpty, s.utf8.count <= 155, let first = s.unicodeScalars.first, first != "-", first != "." else { return false }
        return s.unicodeScalars.allSatisfy { c in
            (c.value >= 48 && c.value <= 57) || (c.value >= 65 && c.value <= 90) || (c.value >= 97 && c.value <= 122) || c == "." || c == "-" || c == "_"
        }
    }
}

/// Restore results from the E12a survey on the operator's Mac (plan 9.3). The placer's catalog starts every score as
/// untested; this overlay fills in what E12a showed, so the catalog in DeskPlacer stays as it is.
public enum E12a {
    /// Browsers restored all windows, frames and tabs, but only with a one-time restore flag.
    /// Claude desktop restored, but may open windows that were closed before the quit; the mover closes them again.
    public static let scores: [String: RestoreScore] = [
        "org.mozilla.firefox": .passed,
        "com.brave.Browser": .passed,
        "com.google.Chrome": .passed,
        "com.anthropic.claudefordesktop": .passed,
    ]

    /// Flag that restores the last session once, without changing the startup setting. Chrome and Brave only;
    /// Firefox uses a one-time preference instead (`RestoreStep.firefoxResumeOnce`).
    public static let restoreFlag = "--restore-last-session"
    public static let chromium: Set<String> = ["com.brave.Browser", "com.google.Chrome"]
    public static let firefox = "org.mozilla.firefox"

    public static func catalog() -> [AppProfile] {
        AppCatalog.snapshot.map { p in
            var q = p
            if q.restore == .untested, let s = scores[q.key] { q.restore = s }
            return q
        }
    }
}

/// Apps the mover never touches, whatever the rules say.
enum Protected {
    /// A display name when the app must never be moved (or even read), nil otherwise.
    static func name(key: String, name: String) -> String? {
        let k = key.lowercased(), n = name.lowercased()
        if Text.contains(k, "darkbloom") || Text.contains(n, "darkbloom") { return "Darkbloom" }
        if k == "com.apple.terminal" || n == "terminal" { return "Terminal" }
        if k == "com.googlecode.iterm2" || n == "iterm2" || n == "iterm" { return "iTerm" }
        if Text.contains(k, "clamshell") || Text.contains(n, "clamshell") { return "Clamshell" }
        return nil
    }
}

enum AppNames {
    struct Resolved: Equatable {
        var key: String
        var name: String
        var profile: AppProfile?
    }

    /// A bundle id or a display name (any case). A bundle id that is not in the catalog still resolves, with no profile.
    static func resolve(_ query: String, catalog: [AppProfile]) -> Resolved? {
        if let p = catalog.first(where: { $0.key == query }) { return Resolved(key: p.key, name: p.name, profile: p) }
        let q = query.lowercased()
        if let p = catalog.first(where: { $0.name.lowercased() == q }) { return Resolved(key: p.key, name: p.name, profile: p) }
        if Text.isSafeBundleId(query) && Text.contains(query, ".") { return Resolved(key: query, name: query, profile: nil) }
        return nil
    }
}

/// Plain-words reasons a placement was refused.
func describe(_ r: RefusalReason) -> String {
    switch r {
    case .homeUnreachable(let m): return "\(m) has not reported, so nothing can be placed there"
    case .notGreen(let m): return "\(m) is under memory pressure"
    case .noRoom(let m): return "\(m) does not have enough free memory after the reserve"
    case .staleReport(let ms): return "the last report from \(ms.joined(separator: ", ")) is too old to trust"
    case .footprintUnmeasured(let ms): return "Darkbloom's footprint is not measured on \(ms.joined(separator: ", ")), so it receives nothing"
    case .noHostQualifies: return "no Mac has room and is free of memory pressure"
    }
}
