import DeskProtocol

/// One hosted window as the operator sees it.
public struct RemoteWindow: Equatable {
    /// Names this window on the operator for good. The host's `windowId` can change when the connection is
    /// rebuilt; this does not, so the native window and its position survive a reconnect.
    public let localId: UInt64
    /// The host's window number on the current connection. Stale while the window is frozen.
    public var windowId: UInt32
    public var appId: UInt32
    /// Empty until APP_LIST has named the app.
    public var bundleId: String
    public var kind: WindowKind
    /// The window this one hangs from (a sheet, popover, menu or tooltip). Nil for top-level windows and orphans.
    public var parentLocalId: UInt64?
    public var title: String
    /// Host geometry in points on the hosted display, as last announced.
    public var geometry: Geometry
    /// Where a child sits, relative to its parent's top-left corner, in host points. May be negative.
    public var childOffset: DeskPoint?
    /// The size the user last gave the native window, in operator points. Kept across reconnects.
    public var userSize: DeskSize?
    public var resize = ResizeState()
    /// False while the connection is down and the window shows its last frame.
    public var isLive = true

    public var hostSize: DeskSize { DeskSize(width: Double(geometry.width), height: Double(geometry.height)) }
    public var isChild: Bool { parentLocalId != nil }
}

public enum AddOutcome: Equatable {
    case added(RemoteWindow)
    /// A window that was frozen by a connection loss has come back.
    case restored(RemoteWindow)
    case protocolError(String)
}

/// What the operator knows about one host: its apps and their windows. Pure state, driven by messages.
public struct HostModel {
    public private(set) var apps: [AppInfo] = []
    /// Live windows by the host's window number.
    public private(set) var windows: [UInt32: RemoteWindow] = [:]
    /// Windows frozen by a connection loss, waiting for the host to announce them again.
    public private(set) var ghosts: [RemoteWindow] = []
    private var registry = WindowRegistry()
    private var nextLocalId: UInt64 = 1

    public init() {}

    // MARK: lookups

    public func bundleId(ofApp appId: UInt32) -> String {
        apps.first(where: { $0.appId == appId })?.bundleId ?? ""
    }

    public func window(localId: UInt64) -> RemoteWindow? {
        if let w = windows.values.first(where: { $0.localId == localId }) { return w }
        return ghosts.first(where: { $0.localId == localId })
    }

    public func localId(forWindowId id: UInt32) -> UInt64? { windows[id]?.localId }

    /// Live windows, oldest first.
    public var liveWindows: [RemoteWindow] { windows.values.sorted(by: { $0.localId < $1.localId }) }

    /// Whether a stream frame or cursor message for this id may be used.
    public func accepts(_ windowId: UInt32) -> Bool { windows[windowId] != nil }

    // MARK: messages

    public mutating func setApps(_ list: [AppInfo]) {
        apps = list
        for (id, w) in windows where w.bundleId != bundleId(ofApp: w.appId) {
            var c = w
            c.bundleId = bundleId(ofApp: w.appId)
            windows[id] = c
        }
    }

    public mutating func add(windowId: UInt32, appId: UInt32, kind: WindowKind, parentId: UInt32,
                             title: String, geometry: Geometry) -> AddOutcome {
        guard registry.announce(windowId) else { return .protocolError("window id \(windowId) added twice or zero") }
        let bundle = bundleId(ofApp: appId)
        var parentLocal: UInt64?
        var offset: DeskPoint?
        if parentId != 0, windowId != parentId, let p = windows[parentId] {
            parentLocal = p.localId
            // Until CHILD_WINDOW says otherwise, the offset is the gap between the two corners on the host display.
            offset = DeskPoint(x: Double(geometry.x - p.geometry.x), y: Double(geometry.y - p.geometry.y))
        }
        if let i = matchGhost(windowId: windowId, bundleId: bundle, kind: kind, title: title) {
            var w = ghosts.remove(at: i)
            w.windowId = windowId
            w.appId = appId
            w.bundleId = bundle
            w.kind = kind
            w.parentLocalId = parentLocal
            w.childOffset = offset
            w.title = title
            w.geometry = geometry
            w.resize = ResizeState()
            w.isLive = true
            windows[windowId] = w
            return .restored(w)
        }
        let w = RemoteWindow(localId: nextLocalId, windowId: windowId, appId: appId, bundleId: bundle, kind: kind,
                             parentLocalId: parentLocal, title: title, geometry: geometry, childOffset: offset)
        nextLocalId += 1
        windows[windowId] = w
        return .added(w)
    }

    /// CHILD_WINDOW. Nil when the message is not usable: unknown ids, a window that is its own ancestor.
    public mutating func setChild(windowId: UInt32, parentId: UInt32, offsetX: Float, offsetY: Float, kind: WindowKind) -> RemoteWindow? {
        guard var w = windows[windowId], let p = windows[parentId], windowId != parentId else { return nil }
        // Walk up from the parent: if this window is on the way, the link would be a loop.
        var cursor: RemoteWindow? = p
        var steps = 0
        while let c = cursor, steps < 64 {
            if c.localId == w.localId { return nil }
            cursor = c.parentLocalId.flatMap { id in windows.values.first(where: { $0.localId == id }) }
            steps += 1
        }
        w.parentLocalId = p.localId
        w.childOffset = DeskPoint(x: Double(offsetX), y: Double(offsetY))
        w.kind = kind
        windows[windowId] = w
        return w
    }

    public mutating func moved(windowId: UInt32, x: Float, y: Float) -> RemoteWindow? {
        guard var w = windows[windowId] else { return nil }
        w.geometry.x = x
        w.geometry.y = y
        if let pid = w.parentLocalId, let p = windows.values.first(where: { $0.localId == pid }) {
            w.childOffset = DeskPoint(x: Double(x - p.geometry.x), y: Double(y - p.geometry.y))
        }
        windows[windowId] = w
        return w
    }

    public mutating func resized(windowId: UInt32, width: Float, height: Float, scale: Float,
                                 config: ResizeConfig) -> (window: RemoteWindow, answer: HostResizeAnswer)? {
        guard var w = windows[windowId] else { return nil }
        w.geometry.width = width
        w.geometry.height = height
        w.geometry.scale = scale
        let hostSize = w.hostSize
        let answer = ResizePolicy.hostResized(&w.resize, to: hostSize, config: config)
        windows[windowId] = w
        return (w, answer)
    }

    public mutating func retitled(windowId: UInt32, title: String) -> RemoteWindow? {
        guard var w = windows[windowId] else { return nil }
        w.title = title
        windows[windowId] = w
        return w
    }

    /// WINDOW_CLOSED. Returns every window that went away, children before parents. Empty for an unknown id.
    public mutating func close(windowId: UInt32) -> [RemoteWindow] {
        guard let root = windows[windowId] else { return [] }
        var order: [RemoteWindow] = []
        collectDescendants(of: root.localId, into: &order, depth: 0)
        order.append(root)
        for w in order {
            windows[w.windowId] = nil
            registry.close(w.windowId)
        }
        return order
    }

    private func collectDescendants(of localId: UInt64, into out: inout [RemoteWindow], depth: Int) {
        guard depth < 16 else { return }
        for w in liveWindows where w.parentLocalId == localId {
            collectDescendants(of: w.localId, into: &out, depth: depth + 1)
            out.append(w)
        }
    }

    // MARK: local changes

    /// Applies a change the operator makes itself (the user resized the native window).
    public mutating func update(localId: UInt64, _ body: (inout RemoteWindow) -> Void) -> RemoteWindow? {
        if let key = windows.first(where: { $0.value.localId == localId })?.key {
            var w = windows[key]!
            body(&w)
            windows[key] = w
            return w
        }
        if let i = ghosts.firstIndex(where: { $0.localId == localId }) {
            body(&ghosts[i])
            return ghosts[i]
        }
        return nil
    }

    // MARK: connection loss

    /// The connection is gone. Top-level windows and sheets freeze and wait for the host to announce them again;
    /// menus, tooltips and popovers are transient and are dropped. The next connection starts a new id space.
    public mutating func freeze() -> (frozen: [RemoteWindow], dropped: [RemoteWindow]) {
        var frozen: [RemoteWindow] = []
        var dropped: [RemoteWindow] = []
        for var w in liveWindows {
            switch w.kind {
            case .menu, .tooltip, .popover:
                dropped.append(w)
            case .main, .sheet, .other:
                w.isLive = false
                ResizePolicy.clear(&w.resize)
                frozen.append(w)
            }
        }
        windows.removeAll()
        registry = WindowRegistry()
        ghosts.append(contentsOf: frozen)
        return (frozen, dropped)
    }

    /// Gives up on the frozen windows the host never announced again.
    public mutating func expireGhosts() -> [RemoteWindow] {
        let gone = ghosts
        ghosts.removeAll()
        return gone
    }

    /// Everything goes: the user closed the session.
    public mutating func removeAll() -> [RemoteWindow] {
        let all = liveWindows + ghosts
        windows.removeAll()
        ghosts.removeAll()
        registry = WindowRegistry()
        apps.removeAll()
        return all
    }

    /// Bundle ids of frozen windows whose app the host's current list does not show as running.
    public func ghostBundlesNotRunning() -> [String] {
        var out: [String] = []
        for g in ghosts where !g.bundleId.isEmpty && !out.contains(g.bundleId) {
            let running = apps.contains(where: { $0.bundleId == g.bundleId && $0.running })
            if !running { out.append(g.bundleId) }
        }
        return out
    }

    // MARK: matching a returning window to a frozen one

    /// A window the host announces after a reconnect is matched to a frozen one in this order of preference:
    /// the same host window number, the same title, then the same app and kind. The app must agree when both
    /// sides know it, and the kind must always agree.
    private func matchGhost(windowId: UInt32, bundleId: String, kind: WindowKind, title: String) -> Int? {
        var best: Int?
        var bestScore = 0
        for (i, g) in ghosts.enumerated() {
            guard g.kind == kind else { continue }
            let bundleKnown = !g.bundleId.isEmpty && !bundleId.isEmpty
            if bundleKnown && g.bundleId != bundleId { continue }
            var score = 0
            if g.windowId == windowId { score += 4 }
            if g.title == title { score += 2 }
            if bundleKnown { score += 1 }
            if score > bestScore { best = i; bestScore = score }
        }
        return best
    }
}
