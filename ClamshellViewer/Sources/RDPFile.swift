import Foundation

/// Fields pulled out of a standard `.rdp` file (simple `key:type:value` text
/// format — Microsoft's RDP client and mstsc.exe both write/read it).
/// Deliberately does NOT attempt to read a `password 51:b:` entry: that's a
/// DPAPI blob encrypted to the machine/user that saved it, undecryptable
/// anywhere else, so it's simplest and safest to always prompt for the
/// password separately rather than try to make sense of it.
struct RDPFileInfo: Equatable {
    var host: String
    var port: UInt16
    var username: String?
    var domain: String?
    var desktopWidth: Int?
    var desktopHeight: Int?
}

enum RDPFileParser {
    static func parse(_ text: String) -> RDPFileInfo? {
        var fields: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let parts = rawLine.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            fields[key] = String(parts[2])
        }
        guard let addr = fields["full address"]?.trimmingCharacters(in: .whitespaces), !addr.isEmpty else {
            return nil
        }

        var host = addr
        var port: UInt16 = 3389
        if let idx = addr.lastIndex(of: ":"), let parsedPort = UInt16(addr[addr.index(after: idx)...]) {
            host = String(addr[..<idx])
            port = parsedPort
        }

        return RDPFileInfo(
            host: host,
            port: port,
            username: fields["username"]?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            domain: fields["domain"]?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            desktopWidth: fields["desktopwidth"].flatMap { Int($0) },
            desktopHeight: fields["desktopheight"].flatMap { Int($0) }
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
