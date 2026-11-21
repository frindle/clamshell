import DeskProtocol

/// Host side of Window Handoff v3. It owns the hosted apps (which outlive connections) and one
/// `OperatorConnection` per operator. The caller does the listening, the authentication and the
/// encryption, then hands each ready connection to `accept`. The caller also calls `pollWindows()` on
/// a timer, and whenever the system says windows changed.
public final class AppHostService {
    let deps: HostDependencies
    var config: HostConfig
    private var sessionsByBundle: [String: AppSession] = [:]
    private var nextAppId: UInt32 = 1
    private var connections: [String: OperatorConnection] = [:]

    public init(dependencies: HostDependencies, config: HostConfig = HostConfig()) {
        self.deps = dependencies
        self.config = config
    }

    public var sessions: [AppSession] { sessionsByBundle.values.sorted { $0.appId < $1.appId } }
    public func session(bundleId: String) -> AppSession? { sessionsByBundle[bundleId] }
    public func connection(operatorId: String) -> OperatorConnection? { connections[operatorId] }

    /// A new control connection. One per operator: a second one from the same operator replaces the first,
    /// which is closed. A peer that did not set the `appHost` capability bit gets nothing and is closed.
    /// The new connection starts from nothing: it is sent the app list and every open window as new.
    @discardableResult
    public func accept(operatorId: String, connection: ControlConnection, peerCapabilities: UInt32) -> OperatorConnection? {
        guard peerCapabilities & DeskCapability.appHost != 0 else {
            config.log("app-host: peer did not offer the appHost capability; closing")
            connection.close()
            return nil
        }
        if let old = connections[operatorId] { old.close() }
        let conn = OperatorConnection(operatorId: operatorId, connection: connection, service: self)
        connections[operatorId] = conn
        conn.start()
        return conn
    }

    /// Looks at every running app's windows and tells each operator what changed. Also notices apps that quit.
    public func pollWindows() {
        for s in sessions where s.running { refresh(s) }
        for c in connections.values { c.sendAppListIfChanged() }
    }

    // MARK: used by OperatorConnection

    func connectionClosed(_ conn: OperatorConnection) {
        if connections[conn.operatorId] === conn { connections[conn.operatorId] = nil }
        for s in sessions {
            for w in s.windowsStreamed(by: conn.operatorId) { stopStream(s, window: w, owner: conn.operatorId) }
        }
    }

    func refresh(_ s: AppSession) {
        guard s.running else { return }
        if !deps.windows.isRunning(pid: s.pid) {
            for w in s.streamingWindowIds { deps.streamer.stopStream(windowId: w) }
            s.exited()
            for c in connections.values { c.appExited(s) }
            return
        }
        s.windows = deps.windows.windows(pid: s.pid)
        s.residentMB = deps.windows.residentMB(pid: s.pid)
        for c in connections.values { c.apply(s) }
    }

    func launch(requestId: UInt32, bundleId: String, activate: Bool, targets: [String], from conn: OperatorConnection) {
        guard !bundleId.isEmpty, config.allowLaunch(bundleId) else {
            conn.send(.appLaunchResult(requestId: requestId, status: 2, appId: 0))
            return
        }
        deps.launcher.launch(bundleId: bundleId, activate: activate, targets: targets) { [weak self, weak conn] outcome in
            guard let self = self else { return }
            var status: UInt8 = 3
            var appId: UInt32 = 0
            switch outcome {
            case .started(let pid, let name):
                let s = self.sessionsByBundle[bundleId] ?? self.makeSession(bundleId: bundleId, name: name)
                s.started(pid: pid, name: name)
                status = 0; appId = s.appId
                self.refresh(s)
            case .notInstalled: status = 1
            case .refused: status = 2
            case .failed: status = 3
            }
            if let conn = conn, conn.isOpen { conn.send(.appLaunchResult(requestId: requestId, status: status, appId: appId)) }
            for c in self.connections.values { c.sendAppListIfChanged() }
        }
    }

    private func makeSession(bundleId: String, name: String) -> AppSession {
        let s = AppSession(appId: nextAppId, bundleId: bundleId, name: name)
        nextAppId += 1
        sessionsByBundle[bundleId] = s
        return s
    }

    func startStream(_ s: AppSession, window: UInt32, owner: String) {
        if s.addStreamOwner(owner, window: window) {
            deps.streamer.startStream(windowId: window) { [weak self, weak s] key, pts, nal in
                guard let self = self, let s = s else { return }
                for o in s.streamOwners(of: window) { self.connections[o]?.sendFrame(window: window, keyframe: key, pts: pts, nal: nal) }
            }
        } else {
            deps.streamer.requestKeyframe(windowId: window)
        }
    }

    func stopStream(_ s: AppSession, window: UInt32, owner: String) {
        if s.removeStreamOwner(owner, window: window) { deps.streamer.stopStream(windowId: window) }
    }

    func sessionStreams(window: UInt32, closedFor owner: String) {
        for s in sessions { stopStream(s, window: window, owner: owner) }
    }

    func session(appId: UInt32) -> AppSession? { sessions.first { $0.appId == appId } }
}

/// The host's end of one operator's control connection.
public final class OperatorConnection {
    public let operatorId: String
    private let connection: ControlConnection
    private unowned let service: AppHostService
    private var parser = FrameParser()
    private var registry = WindowRegistry()
    private var trackers: [UInt32: WindowTracker] = [:]       // by appId
    private var windowApp: [UInt32: UInt32] = [:]              // windowId -> appId
    private var pendingResizeAnswers = Set<UInt32>()
    private var lastAppList: [AppInfo]?
    public private(set) var isOpen = true

    init(operatorId: String, connection: ControlConnection, service: AppHostService) {
        self.operatorId = operatorId; self.connection = connection; self.service = service
    }

    func start() {
        sendAppListIfChanged()
        for s in service.sessions where s.running { apply(s) }
    }

    /// Bytes from the operator, in any chunking. A frame that cannot be read closes the connection.
    public func receive(_ bytes: [UInt8]) {
        guard isOpen else { return }
        let frames: [RawFrame]
        do { frames = try parser.feed(bytes) } catch {
            service.config.log("app-host: bad framing from an operator; closing")
            close(); return
        }
        for f in frames {
            guard isOpen else { return }
            do { handle(try DeskMessage.decode(type: f.type, payload: f.payload)) } catch {
                service.config.log("app-host: message type \(f.type) did not decode; closing")
                close(); return
            }
        }
    }

    public func close() {
        guard isOpen else { return }
        isOpen = false
        connection.close()
        service.connectionClosed(self)
    }

    // MARK: sending

    func send(_ m: DeskMessage) {
        guard isOpen else { return }
        do { connection.send(try m.encodeFrame()) } catch {
            service.config.log("app-host: could not encode message type \(m.typeByte)")
        }
    }

    func sendFrame(window: UInt32, keyframe: Bool, pts: UInt64, nal: [UInt8]) {
        guard isOpen, registry.accepts(window) else { return }
        // A frame too large to send is dropped; the next keyframe replaces it.
        if let bytes = try? DeskMessage.windowStreamFrame(windowId: window, flags: keyframe ? 1 : 0, ptsMicros: pts, nal: nal).encodeFrame() {
            connection.send(bytes)
        }
    }

    func sendAppListIfChanged() {
        guard isOpen else { return }
        let list = service.sessions.map { s in s.info(windowCount: s.windows.filter { $0.kind == .main }.count) }
        if list == lastAppList { return }
        lastAppList = list
        send(.appList(list))
    }

    // MARK: window changes

    func apply(_ s: AppSession) {
        guard isOpen else { return }
        var tracker = trackers[s.appId] ?? WindowTracker()
        var events = tracker.update(s.windows)
        // A resize request is always answered, even when the app kept its size.
        for id in pendingResizeAnswers where windowApp[id] == s.appId || tracker.snapshot(of: id) != nil {
            let answered = events.contains { if case .resized(let w, _, _, _) = $0 { return w == id } else { return false } }
            if !answered, let snap = tracker.snapshot(of: id) {
                events.append(.resized(windowId: id, width: snap.width, height: snap.height, scale: snap.scale))
            }
            pendingResizeAnswers.remove(id)
        }
        trackers[s.appId] = tracker
        for e in events { emit(e, app: s) }
    }

    func appExited(_ s: AppSession) {
        guard isOpen else { return }
        var tracker = trackers[s.appId] ?? WindowTracker()
        for e in tracker.update([]) { emit(e, app: s) }
        trackers[s.appId] = tracker
        sendAppListIfChanged()
    }

    private func emit(_ e: WindowEvent, app s: AppSession) {
        switch e {
        case .added(let id, let kind, let parent, let title, let g, let offset):
            guard registry.announce(id) else {
                service.config.log("app-host: window id announced twice; not sent")
                return
            }
            windowApp[id] = s.appId
            send(.windowAdded(windowId: id, appId: s.appId, kind: kind, parentId: parent, title: title, geometry: g))
            if let o = offset { send(.childWindow(windowId: id, parentId: parent, offsetX: o.x, offsetY: o.y, kind: kind)) }
        case .moved(let id, let x, let y):
            if registry.accepts(id) { send(.windowMoved(windowId: id, x: x, y: y)) }
        case .resized(let id, let w, let h, let scale):
            if registry.accepts(id) { send(.windowResized(windowId: id, width: w, height: h, scale: scale)) }
        case .titled(let id, let t):
            if registry.accepts(id) { send(.windowTitle(windowId: id, title: t)) }
        case .closed(let id):
            guard registry.accepts(id) else { return }
            service.sessionStreams(window: id, closedFor: operatorId)
            registry.close(id)
            windowApp[id] = nil
            send(.windowClosed(windowId: id))
        }
    }

    // MARK: messages from the operator

    private func session(forWindow id: UInt32) -> AppSession? {
        guard registry.accepts(id), let appId = windowApp[id] else { return nil }
        return service.session(appId: appId)
    }

    private func handle(_ m: DeskMessage) {
        switch m {
        case .appListRequest:
            lastAppList = nil
            sendAppListIfChanged()
        case .windowListRequest:
            var list: [WindowInfo] = []
            for s in service.sessions {
                guard let t = trackers[s.appId] else { continue }
                for id in t.openWindowIds.sorted() {
                    guard let snap = t.snapshot(of: id), !WindowClassifier.isChildKind(t.kind(of: id) ?? .other) else { continue }
                    list.append(WindowInfo(windowId: id, title: snap.title, appName: s.name,
                                           widthPx: UInt32(max(0, min(snap.width * snap.scale, Float(Limits.maxPixels)))),
                                           heightPx: UInt32(max(0, min(snap.height * snap.scale, Float(Limits.maxPixels))))))
                }
            }
            registry.listed(list.map { $0.windowId })
            send(.windowListResponse(list))
        case .appLaunch(let req, let bundle, let activate, let targets):
            service.launch(requestId: req, bundleId: bundle, activate: activate, targets: targets, from: self)
        case .windowStreamStart(let id):
            if let s = session(forWindow: id) { service.startStream(s, window: id, owner: operatorId) }
        case .handoffReturn(let id):
            // v3 has no stop message of its own: the operator stops watching a window with HANDOFF_RETURN.
            if let s = session(forWindow: id) { service.stopStream(s, window: id, owner: operatorId) }
        case .windowResizeRequest(let id, let w, let h):
            guard let s = session(forWindow: id), w >= 1, h >= 1 else { return }
            pendingResizeAnswers.insert(id)
            service.deps.resizer.resize(windowId: id, pid: s.pid, width: w, height: h)
            service.refresh(s)
        case .windowInputMouseMove(let id, let x, let y): route(.mouseMove(x: x, y: y), window: id)
        case .windowInputMouseButton(let id, let b, let down, let x, let y): route(.mouseButton(button: b, down: down, x: x, y: y), window: id)
        case .windowInputKey(let id, let code, let down, let flags): route(.key(macKeyCode: code, down: down, flags: flags), window: id)
        case .windowInputScroll(let id, let dx, let dy): route(.scroll(dx: dx, dy: dy), window: id)
        default:
            // Host-to-operator messages, v2 handoff, menus, clipboard and files: not handled by this service yet.
            break
        }
    }

    private func route(_ event: HostInputEvent, window id: UInt32) {
        guard let s = session(forWindow: id) else { return }
        let caps = service.deps.input.capabilities(windowId: id, pid: s.pid)
        for r in InputRouter.candidates(event: event.kind, capabilities: caps, preference: service.config.routePreference) {
            if service.deps.input.deliver(event, windowId: id, pid: s.pid, route: r) { return }
        }
    }
}
