import Foundation

// Derives Display B's address from Display A's so nobody types a second
// address. Foundation only: compiled into the host and the iOS app.

enum DisplayEndpoint {
    /// Display B's address for a Display A address (a bare host such as
    /// `192.168.1.5` or `mac.local:5903`, or a `ws://` / `wss://` URL).
    /// First rule that applies wins:
    ///  1. path `/ws/a` (or ending in `/ws/a`) becomes `/ws/b`;
    ///  2. a first host label ending in `-a` becomes `-b`;
    ///  3. the port plus one (a bare host with no port uses the default).
    /// nil when none applies (a URL with no explicit port and no a/b marker).
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

        if !host.contains(":") { // not an IPv6 literal
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            if let first = labels.first, first.count > 2, first.hasSuffix("-a") {
                var swapped = labels.map(String.init)
                swapped[0] = String(first.dropLast()) + "b"
                c.host = swapped.joined(separator: ".")
                return bare(c, wasURL: isURL, defaultPort: defaultPort)
            }
        }

        if let port = c.port {
            guard port < 65535 else { return nil }
            c.port = port + 1
        } else if !isURL {
            c.port = Int(defaultPort) + 1
        } else {
            return nil
        }
        return c.string
    }

    /// A bare host input always yields a full ws:// URL, with the default
    /// port filled in so A and B differ only by the swapped label.
    private static func bare(_ c: URLComponents, wasURL: Bool, defaultPort: UInt16) -> String? {
        var c = c
        if !wasURL, c.port == nil { c.port = Int(defaultPort) }
        return c.string
    }
}
