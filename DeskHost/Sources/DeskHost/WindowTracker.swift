import DeskProtocol

/// What changed in one app's windows between two looks.
public enum WindowEvent: Equatable {
    /// `childOffset` is set for a sheet, popover, menu or tooltip whose parent is known: its position relative to the parent.
    case added(windowId: UInt32, kind: WindowKind, parentId: UInt32, title: String, geometry: Geometry, childOffset: ChildOffset?)
    case moved(windowId: UInt32, x: Float, y: Float)
    case resized(windowId: UInt32, width: Float, height: Float, scale: Float)
    case titled(windowId: UInt32, title: String)
    case closed(windowId: UInt32)
}

public struct ChildOffset: Equatable {
    public var x: Float, y: Float
    public init(x: Float, y: Float) { self.x = x; self.y = y }
}

/// Compares what an app's windows look like now with what one operator was last told, and says what to send.
/// One tracker per app per connection. Pure: it holds no system handles.
public struct WindowTracker {
    private var known: [UInt32: HostWindowSnapshot] = [:]
    private var kinds: [UInt32: WindowKind] = [:]
    /// Ids that closed. The protocol never lets an id be added twice, so a closed id stays closed.
    private var retired = Set<UInt32>()

    public init() {}

    public var openWindowIds: Set<UInt32> { Set(known.keys) }
    public func snapshot(of id: UInt32) -> HostWindowSnapshot? { known[id] }
    public func kind(of id: UInt32) -> WindowKind? { kinds[id] }
    /// Windows a user would call windows: not menus, tooltips and the like.
    public var mainWindowCount: Int { kinds.values.filter { $0 == .main }.count }

    /// `current` is the app's windows front to back. Returns events in a safe order: closes (children first),
    /// then adds (parents before children), then moves, resizes and title changes.
    public mutating func update(_ current: [HostWindowSnapshot]) -> [WindowEvent] {
        var events: [WindowEvent] = []
        let now = Dictionary(current.map { ($0.windowId, $0) }, uniquingKeysWith: { first, _ in first })

        // Closes. A child closes before its parent so the operator never draws a child with no parent.
        let gone = known.keys.filter { now[$0] == nil }.sorted()
        let goneChildren = gone.filter { WindowClassifier.isChildKind(kinds[$0] ?? .other) }
        let goneRest = gone.filter { !WindowClassifier.isChildKind(kinds[$0] ?? .other) }
        for id in goneChildren + goneRest {
            events.append(.closed(windowId: id))
            known[id] = nil; kinds[id] = nil; retired.insert(id)
        }

        // Adds. Ordinary windows first, so a child can name its parent.
        let fresh = current.filter { known[$0.windowId] == nil && !retired.contains($0.windowId) && $0.windowId != 0 }
        var seen = Set<UInt32>()
        let ordered = (fresh.filter { !WindowClassifier.isChildKind($0.kind) } + fresh.filter { WindowClassifier.isChildKind($0.kind) })
        for w in ordered where seen.insert(w.windowId).inserted {
            let kind = w.kind
            var parent: UInt32 = 0
            var offset: ChildOffset?
            if WindowClassifier.isChildKind(kind) {
                parent = parentFor(w, in: current)
                if parent != 0, let p = known[parent] ?? now[parent] {
                    offset = ChildOffset(x: w.x - p.x, y: w.y - p.y)
                }
            }
            events.append(.added(windowId: w.windowId, kind: kind, parentId: parent, title: w.title, geometry: w.geometry, childOffset: offset))
            known[w.windowId] = w; kinds[w.windowId] = kind
        }

        // Changes to windows the operator already knows.
        for w in current where seen.contains(w.windowId) == false {
            guard let old = known[w.windowId] else { continue }
            if old.x != w.x || old.y != w.y { events.append(.moved(windowId: w.windowId, x: w.x, y: w.y)) }
            if old.width != w.width || old.height != w.height || old.scale != w.scale {
                events.append(.resized(windowId: w.windowId, width: w.width, height: w.height, scale: w.scale))
            }
            if old.title != w.title { events.append(.titled(windowId: w.windowId, title: w.title)) }
            known[w.windowId] = w
        }
        return events
    }

    /// The system's hint if that window is known, else the frontmost ordinary window of the app, else 0.
    private func parentFor(_ child: HostWindowSnapshot, in current: [HostWindowSnapshot]) -> UInt32 {
        if child.parentHint != 0, child.parentHint != child.windowId,
           known[child.parentHint] != nil || current.contains(where: { $0.windowId == child.parentHint }) {
            return child.parentHint
        }
        for w in current where w.windowId != child.windowId && w.kind == .main { return w.windowId }
        return 0
    }

    /// Forget everything (a new connection starts from nothing). Closed ids are forgotten too: the new connection has not seen them.
    public mutating func reset() { known = [:]; kinds = [:]; retired = [] }
}
