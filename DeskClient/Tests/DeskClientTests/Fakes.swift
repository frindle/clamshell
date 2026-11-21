import XCTest
import DeskProtocol
@testable import DeskClient

/// A clock turned by hand. `advance` runs the timers that fall due, in time order.
final class FakeScheduler: DeskScheduler {
    final class Item: DeskTimer {
        let at: Double
        let seq: Int
        let work: () -> Void
        var cancelled = false
        init(at: Double, seq: Int, work: @escaping () -> Void) { self.at = at; self.seq = seq; self.work = work }
        func cancel() { cancelled = true }
    }

    private(set) var now: Double = 0
    private var items: [Item] = []
    private var seq = 0

    func schedule(after seconds: Double, _ work: @escaping () -> Void) -> DeskTimer {
        seq += 1
        let item = Item(at: now + max(0, seconds), seq: seq, work: work)
        items.append(item)
        return item
    }

    func advance(_ seconds: Double) {
        let end = now + seconds
        while true {
            items.removeAll(where: { $0.cancelled })
            let due = items.filter({ $0.at <= end }).sorted(by: { ($0.at, $0.seq) < ($1.at, $1.seq) })
            guard let next = due.first else { break }
            items.removeAll(where: { $0 === next })
            now = max(now, next.at)
            next.work()
        }
        now = end
    }
}

final class EventLog {
    var list: [DeskEvent] = []

    func opened() -> [RemoteWindow] {
        list.compactMap { e -> RemoteWindow? in
            if case .windowOpened(_, let w) = e { return w }
            return nil
        }
    }
    func changes(_ kind: WindowChange) -> [RemoteWindow] {
        list.compactMap { e -> RemoteWindow? in
            if case .windowChanged(_, let w, let c) = e, c == kind { return w }
            return nil
        }
    }
    func closed() -> [UInt64] {
        list.compactMap { e -> UInt64? in
            if case .windowClosed(_, let id) = e { return id }
            return nil
        }
    }
    func states() -> [ConnectionState] {
        list.compactMap { e -> ConnectionState? in
            if case .state(_, let s) = e { return s }
            return nil
        }
    }
    func clear() { list.removeAll() }
}

struct HostWindow {
    var id: UInt32
    var appId: UInt32
    var kind: WindowKind = .main
    var parentId: UInt32 = 0
    var title: String
    var geometry: Geometry
    var offset: (Float, Float)?
}

func geo(_ x: Float, _ y: Float, _ w: Float, _ h: Float, scale: Float = 2) -> Geometry {
    Geometry(x: x, y: y, width: w, height: h, scale: scale)
}

final class FakeLink: DeskLink {
    let events: DeskLinkEvents
    unowned let host: FakeHost
    var dead = false
    private var parser = FrameParser()
    init(host: FakeHost, events: DeskLinkEvents) { self.host = host; self.events = events }

    func send(_ bytes: [UInt8]) {
        guard !dead, let frames = try? parser.feed(bytes) else { return }
        for f in frames {
            if let m = try? DeskMessage.decode(f) { host.clientSent(m) }
        }
    }
    func close() {
        dead = true
        if host.active === self { host.active = nil }
    }
}

/// A host that speaks the v3 messages the operator needs. On every new connection it replays its app list and
/// its open windows, which is what the operator relies on to bring windows back.
final class FakeHost: DeskLinkFactory {
    let scheduler: FakeScheduler
    var reachable = true
    /// Traffic is swallowed both ways, and no close is reported: a silent network drop.
    var partitioned = false
    var capabilities: UInt32 = DeskCapability.appHost
    var connectLatency = 0.05
    /// Seconds before the host answers a resize request. Nil: it never answers.
    var resizeLatency: Double? = 0.1
    var minSize = (width: Float(0), height: Float(0))

    var apps: [AppInfo] = []
    var windows: [HostWindow] = []
    var active: FakeLink?
    var connectCount = 0
    var received: [DeskMessage] = []
    private var nextWindowId: UInt32 = 100

    init(scheduler: FakeScheduler) { self.scheduler = scheduler }

    func connect(hostId: String, events: DeskLinkEvents) -> DeskLink {
        connectCount += 1
        let link = FakeLink(host: self, events: events)
        if !reachable {
            link.dead = true
            events.closed("unreachable")
            return link
        }
        _ = scheduler.schedule(after: connectLatency) { [weak self, weak link] in
            guard let self = self, let link = link, !link.dead else { return }
            self.active = link
            events.opened(self.capabilities)
            if self.capabilities & DeskCapability.appHost != 0 { self.replay() }
        }
        return link
    }

    // MARK: host to operator

    func deliver(_ m: DeskMessage) {
        guard !partitioned, let l = active, !l.dead else { return }
        l.events.received(try! m.encodeFrame())
    }

    func deliverRaw(_ bytes: [UInt8]) {
        guard let l = active, !l.dead else { return }
        l.events.received(bytes)
    }

    func dropLink() {
        guard let l = active else { return }
        active = nil
        l.dead = true
        l.events.closed("reset")
    }

    func sendAppList() { deliver(.appList(apps)) }

    func replay() {
        sendAppList()
        for w in windows { announce(w) }
    }

    func announce(_ w: HostWindow) {
        deliver(.windowAdded(windowId: w.id, appId: w.appId, kind: w.kind, parentId: w.parentId, title: w.title, geometry: w.geometry))
        if let o = w.offset {
            deliver(.childWindow(windowId: w.id, parentId: w.parentId, offsetX: o.0, offsetY: o.1, kind: w.kind))
        }
    }

    func addWindow(_ w: HostWindow) {
        windows.append(w)
        announce(w)
    }

    func closeWindow(_ id: UInt32) {
        windows.removeAll(where: { $0.id == id })
        deliver(.windowClosed(windowId: id))
    }

    func moveWindow(_ id: UInt32, x: Float, y: Float) {
        if let i = windows.firstIndex(where: { $0.id == id }) { windows[i].geometry.x = x; windows[i].geometry.y = y }
        deliver(.windowMoved(windowId: id, x: x, y: y))
    }

    func resizeWindow(_ id: UInt32, width: Float, height: Float) {
        var scale: Float = 2
        if let i = windows.firstIndex(where: { $0.id == id }) {
            windows[i].geometry.width = width; windows[i].geometry.height = height
            scale = windows[i].geometry.scale
        }
        deliver(.windowResized(windowId: id, width: width, height: height, scale: scale))
    }

    func retitleWindow(_ id: UInt32, _ title: String) {
        if let i = windows.firstIndex(where: { $0.id == id }) { windows[i].title = title }
        deliver(.windowTitle(windowId: id, title: title))
    }

    // MARK: operator to host

    func clientSent(_ m: DeskMessage) {
        received.append(m)
        if partitioned { return }
        switch m {
        case .appListRequest:
            sendAppList()
        case .appLaunch(let req, let bundle, _, _):
            guard let i = apps.firstIndex(where: { $0.bundleId == bundle }) else {
                deliver(.appLaunchResult(requestId: req, status: 1, appId: 0))
                return
            }
            deliver(.appLaunchResult(requestId: req, status: 0, appId: apps[i].appId))
            if !apps[i].running {
                apps[i].running = true
                apps[i].pid = 4242
                sendAppList()
                nextWindowId += 1
                addWindow(HostWindow(id: nextWindowId, appId: apps[i].appId, title: "Untitled", geometry: geo(100, 100, 800, 600)))
            }
        case .windowResizeRequest(let id, let w, let h):
            guard let latency = resizeLatency else { return }
            let width = max(w, minSize.width), height = max(h, minSize.height)
            _ = scheduler.schedule(after: latency) { [weak self] in self?.resizeWindow(id, width: width, height: height) }
        default:
            break
        }
    }

    var streamStarts: [UInt32] {
        received.compactMap { m -> UInt32? in
            if case .windowStreamStart(let id) = m { return id }
            return nil
        }
    }

    var resizeRequests: [(UInt32, Float, Float)] {
        received.compactMap { m -> (UInt32, Float, Float)? in
            if case .windowResizeRequest(let id, let w, let h) = m { return (id, w, h) }
            return nil
        }
    }

    var launches: [(bundle: String, activate: Bool)] {
        received.compactMap { m -> (bundle: String, activate: Bool)? in
            if case .appLaunch(_, let b, let a, _) = m { return (b, a) }
            return nil
        }
    }
}

let editorApp = AppInfo(appId: 7, bundleId: "org.example.editor", name: "Editor", pid: 321, windowCount: 1, residentMB: 120, running: true)

final class Harness {
    let scheduler: FakeScheduler
    let host: FakeHost
    let log: EventLog
    let conn: DeskHostConnection

    init(config: DeskConnectionConfig = DeskConnectionConfig(), apps: [AppInfo] = [editorApp]) {
        let sched = FakeScheduler()
        let host = FakeHost(scheduler: sched)
        let log = EventLog()
        host.apps = apps
        self.scheduler = sched
        self.host = host
        self.log = log
        self.conn = DeskHostConnection(hostId: "h1", name: "Host One", factory: host, scheduler: sched,
                                       config: config, emit: { log.list.append($0) })
    }

    func advance(_ s: Double) { scheduler.advance(s) }

    /// Connects and gives the host one main window (id 100).
    func startWithWindow() {
        host.windows = [HostWindow(id: 100, appId: editorApp.appId, title: "Doc", geometry: geo(50, 60, 800, 600))]
        conn.start()
        advance(0.2)
    }

    var window: RemoteWindow? { conn.model.liveWindows.first }
}
