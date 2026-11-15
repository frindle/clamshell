import Foundation

// Derives Display B's address from Display A's so nobody types a second
// address. Foundation only: compiled into the host and the iOS app.

enum DisplayEndpoint {
    /// Display B's address for a Display A address (a bare host such as
    /// `192.168.1.5` or `mac.local:5903`, or a `ws://` / `wss://` URL).
    /// First rule that applies wins:
    ///  1. path `/ws/a` (or ending in `/ws/a`) becomes `/ws/b`;
    ///  2. an explicit port, or a bare host (default port), becomes port + 1,
    ///     because the host serves display n on base port + n; a host that
    ///     merely happens to be named `studio-a` keeps its name;
    ///  3. only a ws/wss URL with NO explicit port: a first host label ending
    ///     in `-a` becomes `-b`.
    /// nil when none applies (a URL with no port and no a/b marker).
    static func displayB(fromA address: String, defaultPort: UInt16 = streamDefaultPort) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let isURL = trimmed.contains("://")
        guard var c = URLComponents(string: isURL ? trimmed : "ws://\(trimmed)"),
              let host = c.host, !host.isEmpty,
              c.scheme == "ws" || c.scheme == "wss" else { return nil }

        if c.path.hasSuffix("/ws/a") {
            c.path = String(c.path.dropLast()) + "b"
            return c.string
        }

        // The host serves display n on base port + n, so whenever a port is
        // known (explicit, or the default for a bare host) port + 1 is right.
        if let port = c.port {
            guard port < 65535 else { return nil }
            c.port = port + 1
            return c.string
        }
        if !isURL {
            c.port = Int(defaultPort) + 1
            return c.string
        }

        // A ws/wss URL with no port (typically behind a proxy): fall back to
        // an a/b naming convention on the first host label.
        if !host.contains(":") { // not an IPv6 literal
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            if let first = labels.first, first.count > 2, first.hasSuffix("-a") {
                var swapped = labels.map(String.init)
                swapped[0] = String(first.dropLast()) + "b"
                c.host = swapped.joined(separator: ".")
                return c.string
            }
        }
        return nil
    }
}

// MARK: - Nearby hosts (Bonjour)

/// Pure helpers for hosts found by browsing `_clamshell._tcp`. TXT records are
/// hints only: they label an entry, they never decide who a host is.
enum NearbyHost {
    static let serviceType = "_clamshell._tcp"

    /// `ws://<host>:<port>` for a resolved address. IPv6 literals are
    /// bracketed and any zone suffix (`%en0`) is dropped.
    static func url(host: String, port: UInt16) -> String? {
        var h = host.trimmingCharacters(in: .whitespaces)
        if let zone = h.firstIndex(of: "%") { h = String(h[..<zone]) }
        guard !h.isEmpty, port > 0 else { return nil }
        if h.contains(":") && !h.hasPrefix("[") { h = "[\(h)]" }
        guard URLComponents(string: "ws://\(h):\(port)")?.host != nil else { return nil }
        return "ws://\(h):\(port)"
    }

    /// A display label from a TXT `name` hint, falling back to the service
    /// name: control characters removed, whitespace trimmed, capped at 60.
    static func label(hint: String?, serviceName: String) -> String {
        func clean(_ s: String) -> String {
            let kept = String(String.UnicodeScalarView(s.unicodeScalars.filter {
                !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
            }))
            return String(kept.trimmingCharacters(in: .whitespaces).prefix(60))
        }
        let h = clean(hint ?? "")
        return h.isEmpty ? clean(serviceName) : h
    }
}
