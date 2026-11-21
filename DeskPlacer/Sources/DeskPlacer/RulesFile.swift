public struct RulesParseError: Error, Equatable, CustomStringConvertible {
    public let line: Int
    public let message: String
    public var description: String { "placement.toml line \(line): \(message)" }
}

/// Reads the small TOML subset `~/.config/desk/placement.toml` uses:
///
///     [defaults]
///     mode = "local"                       # local | anywhere | host | auto
///     reserve_buffer_mb = 8192
///     swap_threshold_mb = 4096
///
///     [mac."studio-b"]
///     darkbloom_footprint_mb = 1964
///
///     [app."org.mozilla.firefox"]
///     home = "studio-b"                    # or pin = "studio-b"
///     [app."com.tinyspeck.slackmacgap"]
///     prefer = "auto"                      # host | local | auto; mode = "anywhere" is the same as auto
///     [app."us.zoom.xos"]
///     needs = ["camera"]
///
/// `prefer = "host"` means anywhere but off the Mac Penn is at when another Mac qualifies.
/// Strings, integers, arrays of strings, `#` comments and the two table forms above only.
public enum RulesFile {
    public static func parse(_ text: String) throws -> PlacementConfig {
        var cfg = PlacementConfig()
        enum Section { case none, defaults, app(String), mac(String) }
        var section = Section.none
        var lineNo = 0
        var seenKeys = Set<String>()
        var seenTables = Set<String>()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNo += 1
            let line = trim(stripComment(String(rawLine)))
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { throw RulesParseError(line: lineNo, message: "unterminated table header") }
                let inner = trim(String(line.dropFirst().dropLast()))
                // Same table under different spelling ([app."x"] and [app.x], or spaces around the dot) is a duplicate too.
                guard seenTables.insert(canonicalHeader(inner)).inserted else { throw RulesParseError(line: lineNo, message: "duplicate table [\(inner)]") }
                seenKeys = []
                if inner == "defaults" { section = .defaults; continue }
                if let key = tableKey(inner, prefix: "app") {
                    section = .app(key); cfg.apps[key] = AppRule(); continue
                }
                if let key = tableKey(inner, prefix: "mac") { section = .mac(key); continue }
                throw RulesParseError(line: lineNo, message: "unknown table [\(inner)]")
            }
            guard let eq = line.firstIndex(of: "=") else { throw RulesParseError(line: lineNo, message: "expected key = value") }
            let key = trim(String(line[line.startIndex..<eq]))
            // home/pin and mode/prefer set the same thing, so giving both is a duplicate too.
            let slot = ["home": "placement", "pin": "placement", "mode": "placement", "prefer": "placement"][key] ?? key
            guard seenKeys.insert(slot).inserted else { throw RulesParseError(line: lineNo, message: "duplicate key \(key)") }
            let value = try parseValue(trim(String(line[line.index(after: eq)...])), line: lineNo)
            switch section {
            case .none: throw RulesParseError(line: lineNo, message: "key outside a table")
            case .defaults:
                switch key {
                case "mode": cfg.defaultPlacement = try placement(from: value, line: lineNo)
                case "reserve_buffer_mb": cfg.reserveBufferMB = try int(value, key, lineNo)
                case "swap_threshold_mb": cfg.swapThresholdMB = try int(value, key, lineNo)
                default: throw RulesParseError(line: lineNo, message: "unknown key \(key) in [defaults]")
                }
            case .mac(let name):
                guard key == "darkbloom_footprint_mb" else { throw RulesParseError(line: lineNo, message: "unknown key \(key) in [mac]") }
                cfg.darkbloomFootprintMB[name] = try int(value, key, lineNo)
            case .app(let app):
                var rule = cfg.apps[app] ?? AppRule()
                switch key {
                case "home", "pin":
                    guard case .string(let mac) = value, !mac.isEmpty else { throw RulesParseError(line: lineNo, message: "\(key) wants a Mac name") }
                    rule.placement = .home(mac)
                case "mode", "prefer":
                    rule.placement = try placement(from: value, line: lineNo)
                case "needs":
                    guard case .array(let items) = value else { throw RulesParseError(line: lineNo, message: "needs wants a list") }
                    for i in items {
                        guard let n = Need(rawValue: i) else { throw RulesParseError(line: lineNo, message: "unknown need \"\(i)\" (camera, usbkey, drm)") }
                        rule.needs.insert(n)
                    }
                default: throw RulesParseError(line: lineNo, message: "unknown key \(key) in [app]")
                }
                cfg.apps[app] = rule
            }
        }
        return cfg
    }

    // MARK: pieces

    enum Value { case string(String), int(Int), array([String]) }

    static func placement(from v: Value, line: Int) throws -> Placement {
        guard case .string(let s) = v else { throw RulesParseError(line: line, message: "expected a string") }
        switch s {
        case "local": return .local
        case "anywhere", "auto": return .anywhere(avoidSeat: false)
        case "host": return .anywhere(avoidSeat: true)
        default: throw RulesParseError(line: line, message: "unknown mode \"\(s)\" (local, anywhere, auto, host)")
        }
    }

    static func int(_ v: Value, _ key: String, _ line: Int) throws -> Int {
        guard case .int(let n) = v, n >= 0 else { throw RulesParseError(line: line, message: "\(key) wants a non-negative integer") }
        guard n <= PlacementConfig.maxMB else { throw RulesParseError(line: line, message: "\(key) is over \(PlacementConfig.maxMB) MB; check for a typo") }
        return n
    }

    /// The header with spacing and optional quotes removed, so equal tables compare equal.
    static func canonicalHeader(_ inner: String) -> String {
        for prefix in ["app", "mac"] {
            if let key = tableKey(inner, prefix: prefix) { return prefix + "\u{0}" + key }
        }
        return trim(inner)
    }

    /// `app."a.b.c"` or `app.name`; blanks around the dot are allowed.
    static func tableKey(_ inner: String, prefix: String) -> String? {
        let head = trim(inner)
        guard head.hasPrefix(prefix) else { return nil }
        var afterWord = Substring(head.dropFirst(prefix.count))
        while let f = afterWord.first, f == " " || f == "\t" { afterWord = afterWord.dropFirst() }
        guard afterWord.hasPrefix(".") else { return nil }
        let rest = trim(String(afterWord.dropFirst()))
        if rest.count >= 2, rest.hasPrefix("\""), rest.hasSuffix("\"") { return String(rest.dropFirst().dropLast()) }
        return rest.isEmpty ? nil : rest
    }

    static func parseValue(_ s: String, line: Int) throws -> Value {
        if s.hasPrefix("\"") { return .string(try parseString(s, line: line)) }
        if s.hasPrefix("[") {
            guard s.hasSuffix("]") else { throw RulesParseError(line: line, message: "unterminated list") }
            let inner = trim(String(s.dropFirst().dropLast()))
            if inner.isEmpty { return .array([]) }
            var items: [String] = []
            for part in splitTopLevel(inner) { items.append(try parseString(trim(part), line: line)) }
            return .array(items)
        }
        if let n = Int(s) { return .int(n) }
        throw RulesParseError(line: line, message: "cannot read value \(s)")
    }

    static func parseString(_ s: String, line: Int) throws -> String {
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else { throw RulesParseError(line: line, message: "expected a quoted string") }
        return String(s.dropFirst().dropLast())
    }

    static func splitTopLevel(_ s: String) -> [String] {
        var out: [String] = [], cur = "", inStr = false
        for c in s {
            if c == "\"" { inStr.toggle(); cur.append(c) }
            else if c == "," && !inStr { out.append(cur); cur = "" }
            else { cur.append(c) }
        }
        if !trim(cur).isEmpty { out.append(cur) }
        return out
    }

    static func stripComment(_ s: String) -> String {
        var inStr = false
        var out = ""
        for c in s {
            if c == "\"" { inStr.toggle() }
            if c == "#" && !inStr { break }
            out.append(c)
        }
        return out
    }

    static func trim(_ s: String) -> String {
        var sub = Substring(s)
        while let f = sub.first, f == " " || f == "\t" || f == "\r" { sub = sub.dropFirst() }
        while let l = sub.last, l == " " || l == "\t" || l == "\r" { sub = sub.dropLast() }
        return String(sub)
    }
}
