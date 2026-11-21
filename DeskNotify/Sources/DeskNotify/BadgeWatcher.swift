import DeskProtocol

/// One Dock item that shows a badge label.
public struct DockBadge: Equatable {
    /// The item's title (the app name).
    public var title: String
    /// Path of the app bundle when the Dock gives it; nil otherwise.
    public var appPath: String?
    /// The badge text, for example "3" or "•".
    public var label: String

    public init(title: String, appPath: String?, label: String) {
        self.title = title; self.appPath = appPath; self.label = label
    }
}

/// Reads the badge labels now on the Dock. Throws when it cannot (for example Accessibility not granted).
public protocol DockBadgeSource {
    func read() throws -> [DockBadge]
}

/// Maps a Dock item to a bundle id.
public protocol BundleResolver {
    func bundleId(for item: DockBadge) -> String?
}

public enum BadgeDiff {
    /// Pairs (bundle id, new text) for every bundle whose label changed. An empty text clears the badge.
    public static func changes(old: [String: String], new: [String: String]) -> [(bundleId: String, text: String)] {
        var out: [(bundleId: String, text: String)] = []
        for key in Set(old.keys).union(new.keys).sorted() where old[key] != new[key] {
            out.append((bundleId: key, text: new[key] ?? ""))
        }
        return out
    }
}

/// Host side: watches Dock badges and emits v3 BADGE messages for hosted apps.
public final class BadgeWatcher {
    public var allowed: Set<String>
    private let source: DockBadgeSource
    private let resolver: BundleResolver
    private let appIds: HostAppIds
    private let log: LogSink
    /// What the operator has been told.
    private var sent: [String: String] = [:]
    private var lastFailure: String?

    public init(source: DockBadgeSource, resolver: BundleResolver, allowed: Set<String>, appIds: HostAppIds,
                log: @escaping LogSink = { _ in }) {
        self.source = source; self.resolver = resolver; self.allowed = allowed; self.appIds = appIds; self.log = log
    }

    /// Forget what was sent, so the next poll sends every badge again. Call after a reconnect.
    public func reset() { sent = [:] }

    public func poll() -> [DeskMessage] {
        let items: [DockBadge]
        do {
            items = try source.read()
            if lastFailure != nil { log("badges: readable again"); lastFailure = nil }
        } catch {
            // Fail closed: keep what the operator has. A failed read is not "all badges cleared".
            let why = String(describing: error)
            if why != lastFailure { log("badges: read failed (\(why))"); lastFailure = why }
            return []
        }
        var current: [String: String] = [:]
        for item in items {
            let label = item.label.trimmingSpaces()
            guard !label.isEmpty, let bundle = resolver.bundleId(for: item), allowed.contains(bundle) else { continue }
            // Two Dock items for one bundle: the first one wins.
            if current[bundle] == nil { current[bundle] = label }
        }
        var out: [DeskMessage] = []
        for change in BadgeDiff.changes(old: sent, new: current) {
            guard let id = appIds.appId(forBundleId: change.bundleId) else { continue }
            out.append(.badge(appId: id, text: clipUTF8(change.text, maxBytes: 64)))
            if change.text.isEmpty { sent[change.bundleId] = nil } else { sent[change.bundleId] = change.text }
        }
        return out
    }
}

extension String {
    func trimmingSpaces() -> String {
        var s = Substring(self)
        while let f = s.first, f == " " || f == "\t" || f == "\n" { s.removeFirst() }
        while let l = s.last, l == " " || l == "\t" || l == "\n" { s.removeLast() }
        return String(s)
    }
}
