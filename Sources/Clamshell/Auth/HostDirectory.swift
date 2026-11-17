import Foundation
import SystemConfiguration

// Where this host's displays can be reached, as told to the devices it lets
// in (HOST_INFO), and the addresses those devices say they came in on
// (CLIENT_INFO). An address here is a hint: whatever a client dials still has
// to pass the handshake with the host key it saved.

final class HostDirectory {
    struct Display: Equatable {
        let index: Int
        let name: String
        let primary: Bool
        let port: UInt16
    }

    static let maxURLBytes = 256
    static let maxURLsPerDisplay = 16
    static let maxDisplays = 8
    static let fileName = "reported-urls.json"
    private static let maxFileBytes = 64 << 10

    private let directory: URL
    private let lock = NSLock()
    private var displays: [Display] = []
    /// Per display, oldest use first.
    private var reported: [Int: [String]] = [:]

    init(directory: URL) {
        self.directory = directory
        reported = Self.load(directory.appendingPathComponent(Self.fileName))
    }

    // MARK: displays

    /// The displays this host serves right now, one listener each.
    func setDisplays(_ list: [Display]) {
        lock.lock()
        displays = list
        lock.unlock()
    }

    // MARK: addresses reported by clients

    /// Keeps an address a trusted device says it connected to. The caller has
    /// checked that the device is trusted.
    func report(url raw: String, display: Int) {
        guard (0 ..< Self.maxDisplays).contains(display), let url = Self.cleanURL(raw) else { return }
        lock.lock()
        var list = reported[display] ?? []
        let known = list.contains(url)
        list.removeAll { $0 == url }
        list.append(url)
        if list.count > Self.maxURLsPerDisplay { list.removeFirst(list.count - Self.maxURLsPerDisplay) }
        reported[display] = list
        let snapshot = reported
        lock.unlock()
        // The order only matters for which one is dropped, so the file is
        // rewritten when an address is new, not every time one is used.
        if !known { save(snapshot) }
    }

    func reportedURLs(display: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return reported[display] ?? []
    }

    /// A reported address as the host will keep it, or nil. `ws://` or
    /// `wss://`, at most 256 bytes, no user info, query or fragment.
    static func cleanURL(_ raw: String) -> String? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~:/[]%".utf8)
        guard !raw.isEmpty, raw.utf8.count <= maxURLBytes, raw.utf8.allSatisfy(allowed.contains),
              let parts = URLComponents(string: raw),
              let scheme = parts.scheme?.lowercased(), scheme == "ws" || scheme == "wss",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            return nil
        }
        return raw
    }

    // MARK: HOST_INFO

    /// `display` is the index the asking connection serves, nil for a window.
    /// Addresses reported by clients are included only for a trusted device.
    func hostInfo(name: String, hostId: String, display: Int?, includeReported: Bool) -> Data {
        lock.lock()
        let displays = self.displays
        let reported = self.reported
        lock.unlock()
        let hosts = Self.ownHosts()
        let list: [[String: Any]] = displays.map { d in
            var urls = hosts.map { "ws://\($0):\(d.port)" }
            if includeReported {
                // Most recently used first.
                for url in (reported[d.index] ?? []).reversed() where !urls.contains(url) { urls.append(url) }
            }
            return ["index": d.index, "name": d.name, "primary": d.primary, "urls": urls]
        }
        var info: [String: Any] = [
            "name": AuthWire.cleanName(name),
            "kind": "mac",
            "version": Self.version,
            "hostId": hostId,
            "displays": list,
        ]
        if let display { info["display"] = display }
        let json = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys, .withoutEscapingSlashes])
        return json ?? Data("{}".utf8)
    }

    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    /// Names and addresses this Mac answers to on its own networks: its
    /// Bonjour name, then each IPv4 address of an interface that is up.
    static func ownHosts() -> [String] {
        var hosts: [String] = []
        if let local = SCDynamicStoreCopyLocalHostName(nil) as String?, !local.isEmpty,
           local.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A)
               || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D }) {
            hosts.append("\(local).local")
        }
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let head = first else { return hosts }
        defer { freeifaddrs(first) }
        for entry in sequence(first: head, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else {
                continue
            }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: buffer)
            // Self-assigned addresses reach nothing useful.
            if text.hasPrefix("169.254.") || hosts.contains(text) { continue }
            hosts.append(text)
        }
        return hosts
    }

    // MARK: the file

    private static func load(_ file: URL) -> [Int: [String]] {
        guard let data = try? SecureFile.read(file, maxBytes: maxFileBytes),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let saved = object["displays"] as? [String: Any] else { return [:] }
        var out: [Int: [String]] = [:]
        for (key, value) in saved {
            guard let index = Int(key), (0 ..< maxDisplays).contains(index), let urls = value as? [Any] else { continue }
            var list: [String] = []
            for case let url as String in urls {
                if let clean = cleanURL(url), !list.contains(clean) { list.append(clean) }
            }
            if !list.isEmpty { out[index] = Array(list.suffix(maxURLsPerDisplay)) }
        }
        return out
    }

    private func save(_ reported: [Int: [String]]) {
        var displays: [String: Any] = [:]
        for (index, urls) in reported { displays[String(index)] = urls }
        guard let data = try? JSONSerialization.data(withJSONObject: ["v": 1, "displays": displays],
                                                     options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        do {
            try HostState.prepare(directory)
            try SecureFile.replace(directory.appendingPathComponent(Self.fileName), contents: data)
        } catch {
            clog("DEVICES: could not save the addresses clients reported (\(error))")
        }
    }
}
