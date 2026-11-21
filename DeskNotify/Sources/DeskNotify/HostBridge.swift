import DeskProtocol

/// The host's numbering of apps on one connection (the `appId` of APP_LIST).
public protocol HostAppIds {
    func appId(forBundleId bundleId: String) -> UInt32?
}

public struct StaticAppIds: HostAppIds {
    public var ids: [String: UInt32]
    public init(_ ids: [String: UInt32]) { self.ids = ids }
    public func appId(forBundleId bundleId: String) -> UInt32? { ids[bundleId] }
}

/// Cuts text to a byte budget on a character boundary. NOTIFY text is short; the wire limit is 65535 bytes per string.
func clipUTF8(_ s: String, maxBytes: Int) -> String {
    guard s.utf8.count > maxBytes else { return s }
    var out = ""
    var used = 0
    for ch in s {
        let n = String(ch).utf8.count
        if used + n > maxBytes { break }
        out.append(ch); used += n
    }
    return out
}

/// Host side: turns store records into v3 NOTIFY messages for the apps the operator is hosting.
public final class HostNotifyBridge {
    /// Bundle ids the operator is hosting. Nothing else leaves the host.
    public var allowed: Set<String>
    private let appIds: HostAppIds
    private let log: LogSink
    static let titleBytes = 1024
    static let bodyBytes = 4096

    public init(allowed: Set<String>, appIds: HostAppIds, log: @escaping LogSink = { _ in }) {
        self.allowed = allowed; self.appIds = appIds; self.log = log
    }

    /// Stable per row, so a resend after a restart carries the same id and the operator can drop it.
    public static func notificationId(_ r: NotificationRecord) -> String {
        "\(r.recId)-\(Int64(((r.date ?? 0) * 1000).rounded()))"
    }

    public func messages(for records: [NotificationRecord]) -> [DeskMessage] {
        var out: [DeskMessage] = []
        var notAllowed = 0, noId = 0
        for r in records {
            guard allowed.contains(r.bundleId) else { notAllowed += 1; continue }
            guard let id = appIds.appId(forBundleId: r.bundleId) else { noId += 1; continue }
            out.append(.notify(appId: id, notificationId: Self.notificationId(r),
                               title: clipUTF8(r.title, maxBytes: Self.titleBytes),
                               subtitle: clipUTF8(r.subtitle, maxBytes: Self.titleBytes),
                               body: clipUTF8(r.body, maxBytes: Self.bodyBytes),
                               sound: false))
        }
        if notAllowed > 0 { log("notify: \(notAllowed) not forwarded (app not hosted)") }
        if noId > 0 { log("notify: \(noId) not forwarded (app has no id on this connection)") }
        return out
    }
}
