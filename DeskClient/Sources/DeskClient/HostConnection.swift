import DeskProtocol

/// The control connection to one host, over Window Handoff v3. It owns the host's window model, reconnects with
/// backoff, and brings windows back by itself after a drop, a sleep or a wake.
///
/// Everything runs on one queue. The owner calls in from that queue, and the link and the scheduler call back on it.
///
/// What a lost connection does to windows: top-level windows and sheets are frozen. The native windows stay, with
/// their last frame. When the link is back, the host announces its windows again (the host side must replay
/// WINDOW_ADDED for every open window after a new connection; PROTOCOL.md does not say so yet). Each announced
/// window is matched to a frozen one, keeps its `localId`, and goes live. Frozen windows nobody claims are closed
/// after `restoreGrace`, or after `offlineLimit` if the host never returns. Menus, tooltips and popovers are
/// dropped at once.
public final class DeskHostConnection {
    public let hostId: String
    public let name: String
    public private(set) var state: ConnectionState = .idle
    public private(set) var model = HostModel()

    private let factory: DeskLinkFactory
    private let scheduler: DeskScheduler
    private let config: DeskConnectionConfig
    private let emit: (DeskEvent) -> Void

    private var backoff: Backoff
    private var attempt = 0
    private var wanted = false
    private var link: DeskLink?
    /// Bumped whenever a link is dropped or replaced. A callback from an older link sees a different number and
    /// does nothing.
    private var epoch = 0
    private var parser = FrameParser()
    private var lastReceive = 0.0
    private var nextRequestId: UInt32 = 1
    private var relaunched = Set<String>()

    private var retryTimer: DeskTimer?
    private var heartbeatTimer: DeskTimer?
    private var stableTimer: DeskTimer?
    private var graceTimer: DeskTimer?
    private var offlineTimer: DeskTimer?
    private var resizeTimers: [UInt64: DeskTimer] = [:]

    public init(hostId: String, name: String, factory: DeskLinkFactory, scheduler: DeskScheduler,
                config: DeskConnectionConfig = DeskConnectionConfig(), emit: @escaping (DeskEvent) -> Void) {
        self.hostId = hostId
        self.name = name
        self.factory = factory
        self.scheduler = scheduler
        self.config = config
        self.backoff = config.backoff
        self.emit = emit
    }

    // MARK: control

    /// Connects, and keeps the connection up until `stop`.
    public func start() {
        guard !wanted else { return }
        wanted = true
        backoff.reset()
        attempt = 0
        connectNow()
    }

    /// Closes the connection and every window of this host.
    public func stop() {
        wanted = false
        dropLink()
        cancelAllTimers()
        for w in model.removeAll() { emit(.windowClosed(hostId: hostId, localId: w.localId)) }
        setState(.idle)
    }

    /// The Mac is about to sleep. The link is closed, the windows are frozen, and no attempts are made.
    public func systemWillSleep() {
        guard wanted else { return }
        dropLink()
        cancelAllTimers()
        freezeWindows()
        // Sleeping time is not time the host was unreachable.
        offlineTimer?.cancel()
        offlineTimer = nil
        setState(.asleep)
    }

    /// The Mac woke. A link that looks alive after sleep may be dead, so it is rebuilt, at once.
    public func systemDidWake() {
        guard wanted else { return }
        dropLink()
        cancelAllTimers()
        freezeWindows()
        backoff.reset()
        attempt = 0
        connectNow()
    }

    /// A route to the network appeared. If the connection is waiting to retry, it retries now.
    public func networkChanged(available: Bool) {
        guard wanted, available else { return }
        if case .waiting = state { connectNow() }
    }

    // MARK: requests

    /// Sends a message. False when the connection is not ready or the message cannot be encoded.
    @discardableResult
    public func send(_ message: DeskMessage) -> Bool {
        guard state == .ready, let l = link else { return false }
        guard let bytes = try? message.encodeFrame() else { return false }
        l.send(bytes)
        return true
    }

    /// Asks the host to start or focus an app. Returns the request id, or nil if it could not be sent.
    @discardableResult
    public func launch(bundleId: String, activate: Bool = true, targets: [String] = []) -> UInt32? {
        let id = nextRequestId
        guard send(.appLaunch(requestId: id, bundleId: bundleId, activate: activate, targets: targets)) else { return nil }
        nextRequestId &+= 1
        return id
    }

    /// The user changed the size of a native window. The size is remembered for good; the request goes out at
    /// most every `resize.minInterval`, newest size last. Until the host answers, the last frame is stretched.
    public func userResized(localId: UInt64, to size: DeskSize) {
        let now = scheduler.now
        let cfg = config.resize
        let canSend = state == .ready
        var action = ResizeAction.none
        let updated = model.update(localId: localId) { w in
            w.userSize = ResizePolicy.clamp(size, cfg)
            if w.isLive && canSend {
                let hostSize = w.hostSize
                action = ResizePolicy.userResized(&w.resize, to: size, hostSize: hostSize, now: now, config: cfg)
            }
        }
        guard let w = updated else { return }
        if case .send(let s) = action { sendResizeRequest(w, s) }
        rescheduleResize(localId)
    }

    // MARK: connecting

    private func connectNow() {
        retryTimer?.cancel()
        retryTimer = nil
        attempt += 1
        epoch += 1
        let mine = epoch
        setState(.connecting(attempt: attempt))
        parser = FrameParser()
        let events = DeskLinkEvents(
            opened: { [weak self] caps in self?.linkOpened(mine, caps) },
            received: { [weak self] bytes in self?.linkReceived(mine, bytes) },
            closed: { [weak self] reason in self?.linkClosed(mine, reason) })
        let l = factory.connect(hostId: hostId, events: events)
        if epoch == mine { link = l } else { l.close() }
    }

    private func linkOpened(_ mine: Int, _ caps: UInt32) {
        guard mine == epoch, case .connecting = state else { return }
        if caps & DeskCapability.appHost == 0 {
            // Retrying would get the same answer.
            wanted = false
            dropLink()
            cancelAllTimers()
            for w in model.removeAll() { emit(.windowClosed(hostId: hostId, localId: w.localId)) }
            setState(.failed("the host does not host apps"))
            return
        }
        lastReceive = scheduler.now
        setState(.ready)
        relaunched.removeAll()
        offlineTimer?.cancel()
        offlineTimer = nil
        stableTimer = scheduler.schedule(after: config.stableAfter) { [weak self] in
            guard let self = self, self.epoch == mine else { return }
            self.backoff.reset()
            self.attempt = 0
        }
        heartbeatTimer = scheduler.schedule(after: config.heartbeatInterval) { [weak self] in self?.heartbeat(mine) }
        if !model.ghosts.isEmpty {
            graceTimer = scheduler.schedule(after: config.restoreGrace) { [weak self] in
                guard let self = self, self.epoch == mine else { return }
                self.expireGhosts()
            }
        }
        send(.appListRequest)
    }

    private func linkReceived(_ mine: Int, _ bytes: [UInt8]) {
        guard mine == epoch, state == .ready else { return }
        lastReceive = scheduler.now
        let frames: [RawFrame]
        do { frames = try parser.feed(bytes) } catch {
            lost("bad framing: \(error)")
            return
        }
        for f in frames {
            // A protocol error in an earlier frame has already dropped this link.
            guard mine == epoch else { return }
            let message: DeskMessage
            do { message = try DeskMessage.decode(f) } catch {
                // A message of a known type that fails to decode closes the connection (PROTOCOL.md).
                lost("undecodable message 0x\(String(f.type, radix: 16)): \(error)")
                return
            }
            handle(message)
        }
    }

    private func linkClosed(_ mine: Int, _ reason: String?) {
        guard mine == epoch else { return }
        lost(reason ?? "closed")
    }

    /// The link is gone, or is not to be trusted. Freeze the windows and plan another attempt.
    private func lost(_ reason: String) {
        dropLink()
        cancelLiveTimers()
        guard wanted else { return }
        freezeWindows()
        let delay = backoff.next()
        setState(.waiting(attempt: attempt, retryIn: delay))
        retryTimer = scheduler.schedule(after: delay) { [weak self] in self?.connectNow() }
    }

    private func dropLink() {
        epoch += 1
        let l = link
        link = nil
        l?.close()
    }

    private func heartbeat(_ mine: Int) {
        guard mine == epoch, state == .ready else { return }
        let silent = scheduler.now - lastReceive
        if silent >= config.silenceLimit {
            lost("no data for \(silent) s")
            return
        }
        // APP_LIST_REQUEST is cheap and the host must answer it, so a quiet but healthy link shows itself.
        if silent >= config.heartbeatInterval { send(.appListRequest) }
        heartbeatTimer = scheduler.schedule(after: config.heartbeatInterval) { [weak self] in self?.heartbeat(mine) }
    }

    // MARK: messages from the host

    private func handle(_ m: DeskMessage) {
        switch m {
        case .appList(let list):
            model.setApps(list)
            emit(.apps(hostId: hostId, list))
            relaunchFrozenApps()
        case .appLaunchResult(let req, let status, let appId):
            emit(.launchResult(hostId: hostId, requestId: req, status: status, appId: appId))
        case .windowAdded(let id, let app, let kind, let parent, let title, let g):
            switch model.add(windowId: id, appId: app, kind: kind, parentId: parent, title: title, geometry: g) {
            case .protocolError(let why):
                lost(why)
            case .added(let w):
                emit(.windowOpened(hostId: hostId, w))
                send(.windowStreamStart(windowId: id))
            case .restored(let w):
                emit(.windowChanged(hostId: hostId, w, .restored))
                send(.windowStreamStart(windowId: id))
                resendUserSize(w)
            }
        case .childWindow(let id, let parent, let ox, let oy, let kind):
            if let w = model.setChild(windowId: id, parentId: parent, offsetX: ox, offsetY: oy, kind: kind) {
                emit(.windowChanged(hostId: hostId, w, .placed))
            }
        case .windowMoved(let id, let x, let y):
            if let w = model.moved(windowId: id, x: x, y: y) { emit(.windowChanged(hostId: hostId, w, .moved)) }
        case .windowResized(let id, let wd, let ht, let scale):
            if let r = model.resized(windowId: id, width: wd, height: ht, scale: scale, config: config.resize) {
                emit(.windowChanged(hostId: hostId, r.window, .resized(r.answer)))
                rescheduleResize(r.window.localId)
            }
        case .windowTitle(let id, let title):
            if let w = model.retitled(windowId: id, title: title) { emit(.windowChanged(hostId: hostId, w, .retitled)) }
        case .windowClosed(let id):
            for w in model.close(windowId: id) {
                resizeTimers[w.localId]?.cancel()
                resizeTimers[w.localId] = nil
                emit(.windowClosed(hostId: hostId, localId: w.localId))
            }
        case .windowStreamFrame(let id, _, _, _):
            if model.accepts(id) { emit(.message(hostId: hostId, m)) }
        case .cursorShape(let id, _, _, _, _):
            if model.accepts(id) { emit(.message(hostId: hostId, m)) }
        case .unknown:
            break
        default:
            emit(.message(hostId: hostId, m))
        }
    }

    /// After a reconnect, an app that had windows and is no longer running on the host is started again, once.
    private func relaunchFrozenApps() {
        for bundle in model.ghostBundlesNotRunning() where !relaunched.contains(bundle) {
            relaunched.insert(bundle)
            launch(bundleId: bundle, activate: false)
        }
    }

    /// A window came back. If the user had resized it while the link was down, say so to the host.
    private func resendUserSize(_ w: RemoteWindow) {
        guard let u = w.userSize, !u.isClose(to: w.hostSize, tolerance: config.resize.tolerance) else { return }
        userResized(localId: w.localId, to: u)
    }

    // MARK: freezing and expiry

    private func freezeWindows() {
        let r = model.freeze()
        for w in r.dropped { emit(.windowClosed(hostId: hostId, localId: w.localId)) }
        for w in r.frozen { emit(.windowChanged(hostId: hostId, w, .frozen)) }
        if !model.ghosts.isEmpty && offlineTimer == nil {
            offlineTimer = scheduler.schedule(after: config.offlineLimit) { [weak self] in self?.expireGhosts() }
        }
    }

    private func expireGhosts() {
        graceTimer?.cancel()
        graceTimer = nil
        offlineTimer?.cancel()
        offlineTimer = nil
        for w in model.expireGhosts() { emit(.windowClosed(hostId: hostId, localId: w.localId)) }
    }

    // MARK: resize timers

    private func sendResizeRequest(_ w: RemoteWindow, _ s: DeskSize) {
        send(.windowResizeRequest(windowId: w.windowId, width: Float(s.width), height: Float(s.height)))
    }

    private func rescheduleResize(_ localId: UInt64) {
        resizeTimers[localId]?.cancel()
        resizeTimers[localId] = nil
        guard let w = model.window(localId: localId), w.isLive,
              let wake = ResizePolicy.nextWake(w.resize, config: config.resize) else { return }
        let delay = max(0, wake - scheduler.now)
        resizeTimers[localId] = scheduler.schedule(after: delay) { [weak self] in self?.resizeTick(localId) }
    }

    private func resizeTick(_ localId: UInt64) {
        resizeTimers[localId] = nil
        guard state == .ready else { return }
        let now = scheduler.now
        let cfg = config.resize
        var toSend: DeskSize?
        var timedOut = false
        let updated = model.update(localId: localId) { w in
            toSend = ResizePolicy.flushDue(&w.resize, now: now, config: cfg)
            timedOut = ResizePolicy.expired(&w.resize, now: now)
        }
        guard let w = updated else { return }
        if let s = toSend { sendResizeRequest(w, s) }
        if timedOut { emit(.windowChanged(hostId: hostId, w, .resizeTimedOut)) }
        rescheduleResize(localId)
    }

    // MARK: bookkeeping

    private func setState(_ s: ConnectionState) {
        guard s != state else { return }
        state = s
        emit(.state(hostId: hostId, s))
    }

    private func cancelLiveTimers() {
        heartbeatTimer?.cancel(); heartbeatTimer = nil
        stableTimer?.cancel(); stableTimer = nil
        graceTimer?.cancel(); graceTimer = nil
        for (_, t) in resizeTimers { t.cancel() }
        resizeTimers.removeAll()
    }

    private func cancelAllTimers() {
        cancelLiveTimers()
        retryTimer?.cancel(); retryTimer = nil
        offlineTimer?.cancel(); offlineTimer = nil
    }
}
