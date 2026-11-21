import DeskProtocol

/// One line of the session list: a host and what it is doing.
public struct DeskSession: Equatable {
    public var hostId: String
    public var name: String
    public var state: ConnectionState
    public var apps: [AppInfo]
    /// Windows that are live, children included.
    public var liveWindows: Int
    /// Windows frozen by a connection loss.
    public var frozenWindows: Int
}

/// All the hosts this Mac is a viewer for, one control connection each.
public final class DeskHub {
    private let factory: DeskLinkFactory
    private let scheduler: DeskScheduler
    private let config: DeskConnectionConfig
    private let onEvent: (DeskEvent) -> Void
    private var connections: [DeskHostConnection] = []

    public init(factory: DeskLinkFactory, scheduler: DeskScheduler,
                config: DeskConnectionConfig = DeskConnectionConfig(), onEvent: @escaping (DeskEvent) -> Void) {
        self.factory = factory
        self.scheduler = scheduler
        self.config = config
        self.onEvent = onEvent
    }

    /// Adds a host and connects to it. Adding the same id again returns the existing connection.
    @discardableResult
    public func addHost(id: String, name: String) -> DeskHostConnection {
        if let c = connection(id) { return c }
        let c = DeskHostConnection(hostId: id, name: name, factory: factory, scheduler: scheduler,
                                   config: config, emit: onEvent)
        connections.append(c)
        c.start()
        return c
    }

    /// Disconnects from a host and closes its windows.
    public func removeHost(id: String) {
        guard let i = connections.firstIndex(where: { $0.hostId == id }) else { return }
        connections[i].stop()
        connections.remove(at: i)
    }

    public func connection(_ id: String) -> DeskHostConnection? {
        connections.first(where: { $0.hostId == id })
    }

    /// The session list, in the order hosts were added.
    public var sessions: [DeskSession] {
        connections.map { c in
            DeskSession(hostId: c.hostId, name: c.name, state: c.state, apps: c.model.apps,
                        liveWindows: c.model.windows.count, frozenWindows: c.model.ghosts.count)
        }
    }

    /// Which hosts have an app running, by bundle id. For "open this app" when it already runs somewhere.
    public func hostsRunning(bundleId: String) -> [String] {
        connections.filter { c in c.model.apps.contains(where: { $0.bundleId == bundleId && $0.running }) }.map { $0.hostId }
    }

    @discardableResult
    public func launch(hostId: String, bundleId: String, activate: Bool = true, targets: [String] = []) -> UInt32? {
        connection(hostId)?.launch(bundleId: bundleId, activate: activate, targets: targets)
    }

    public func systemWillSleep() { for c in connections { c.systemWillSleep() } }
    public func systemDidWake() { for c in connections { c.systemDidWake() } }
    public func networkChanged(available: Bool) { for c in connections { c.networkChanged(available: available) } }
}
