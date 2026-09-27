import AppKit

// Window handoff over the peer link (PROTOCOL.md "Peer link — window
// handoff"), both roles on this Mac:
//
// Source — a window of some app here was dragged across the peer edge (or
// picked from the menu): park it (WindowHider), serve it on a fresh v1
// window-stream port that only the peer's address may connect to, and send
// HANDOFF_BEGIN. HANDOFF_RETURN puts it back (under the cursor when it was
// dragged home, where it came from otherwise) and stops the stream; the
// window closing here sends WINDOW_CLOSED.
//
// Receiver — HANDOFF_BEGIN opens a ReceiverWindow on that stream; it
// follows the cursor while the carrying drag is still held. ↩ / close /
// dragging it back across the edge sends HANDOFF_RETURN.
//
// Main-thread only.

final class HandoffManager {
    var send: (Data) -> Void = { _ in }
    var peerHost: () -> String? = { nil }
    /// Is the drag that carried a window here still held? (the peer's
    /// injected button while it controls us, else our own physical button)
    var isCarryHeld: () -> Bool = { false }
    var onChange: () -> Void = {}
    static let portRange: ClosedRange<UInt16> = 5921...5940

    private struct Outgoing {
        let id: UInt32
        let pid: pid_t
        let title: String
        let server: StreamServer
        let port: UInt16
        let hider: WindowHider?
        let grab: CGPoint
        var accepted = false
    }
    private var outgoing: [UInt32: Outgoing] = [:]
    private var receivers: [UInt32: ReceiverWindow] = [:]
    private var watchTimer: Timer?
    private var followTimer: Timer?

    var outgoingCount: Int { outgoing.count }
    var receiverCount: Int { receivers.count }
    func receiver(for sourceWindowId: UInt32) -> ReceiverWindow? { receivers[sourceWindowId] }

    /// CarryDetector hook: which source window one of our windows shows.
    func sourceWindowId(forWindowNumber n: CGWindowID) -> UInt32? {
        receivers.first { CGWindowID($0.value.windowNumber) == n }?.key
    }

    // MARK: - Source

    /// Hands `window` to the peer. `preDragOrigin` = where it sat before the
    /// drag started (restored there on a plain return).
    @discardableResult
    func begin(windowId: CGWindowID, pid: pid_t, frame: CGRect, title: String, app: String, grab: CGPoint,
               preDragOrigin: CGPoint?, peerEdge: PeerEdge, position: CGFloat) -> Bool {
        let id = UInt32(windowId)
        guard outgoing[id] == nil else { return false }
        guard pid != getpid() else { clog("HANDOFF: not handing off Clamshell's own window"); return false }
        guard let host = peerHost() else { clog("HANDOFF: no peer address"); return false }
        guard let port = Self.portRange.first(where: { p in !outgoing.values.contains { $0.port == p } && Self.isPortFree(p) }) else {
            clog("HANDOFF: no free window-stream port in \(Self.portRange)"); return false
        }
        let hider = WindowHider.find(windowID: windowId, pid: pid, frame: frame, title: title)
        if let hider, let o = preDragOrigin { hider.originalOrigin = o }
        let server = StreamServer(source: .window(id), port: port, isPrimary: false,
                                  allowedRemoteHost: host, windowScale: Self.backingScale(for: frame))
        do { try server.start() } catch {
            clog("HANDOFF: could not serve window \(id) on \(port): \(error)"); return false
        }
        let parked = hider?.hide() ?? false
        if hider == nil { clog("HANDOFF: window \(id) not reachable via Accessibility — streaming it in place") }
        outgoing[id] = Outgoing(id: id, pid: pid, title: title, server: server, port: port, hider: hider, grab: grab)
        send(StreamMessage.handoffBegin(HandoffBeginPayload(
            windowId: id, edge: peerEdge, position: Float32(position), grabX: Float32(grab.x), grabY: Float32(grab.y),
            width: UInt32(max(frame.width, 1)), height: UInt32(max(frame.height, 1)), streamPort: port,
            title: title, appName: app)))
        clog("HANDOFF: \"\(app) — \(title)\" → peer on port \(port)\(parked ? ", parked off-screen" : "")")
        startWatching()
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, let o = self.outgoing[id], !o.accepted else { return }
            clog("HANDOFF: peer never accepted window \(id) — putting it back")
            self.finishOutgoing(id, underCursor: false)
        }
        onChange()
        return true
    }

    /// Menu: take every handed-off window back from the peer.
    func bringBackAll() {
        for id in Array(outgoing.keys) {
            send(StreamMessage.windowClosed(windowId: id))
            finishOutgoing(id, underCursor: false)
        }
    }

    private func finishOutgoing(_ id: UInt32, underCursor: Bool) {
        guard let o = outgoing.removeValue(forKey: id) else { return }
        o.server.stop()
        if let h = o.hider, h.hidden {
            if underCursor {
                h.restore()
                followCursor(h, grab: o.grab)
            } else {
                h.restore()
            }
            h.raise(pid: o.pid)
        }
        clog("HANDOFF: window \(id) back on this Mac")
        if outgoing.isEmpty { watchTimer?.invalidate(); watchTimer = nil }
        onChange()
    }

    /// A returned window follows the cursor (grab point under it) while
    /// the drag that brought it home is still held.
    private func followCursor(_ h: WindowHider, grab: CGPoint) {
        followTimer?.invalidate()
        let move = { [weak self] in
            guard self != nil else { return }
            let c = NSEventLocationTopLeft()
            h.setPosition(CGPoint(x: c.x - grab.x * h.size.width, y: c.y - grab.y * h.size.height))
        }
        move()
        followTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] t in
            guard let self, self.isCarryHeld() else { t.invalidate(); return }
            move()
        }
    }

    private func startWatching() {
        guard watchTimer == nil else { return }
        watchTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            for id in Array(self.outgoing.keys) where CarryDetector.frame(of: CGWindowID(id)) == nil {
                clog("HANDOFF: window \(id) closed on this Mac")
                self.send(StreamMessage.windowClosed(windowId: id))
                self.outgoing[id]?.server.stop()
                self.outgoing[id] = nil
                self.onChange()
            }
            if self.outgoing.isEmpty { self.watchTimer?.invalidate(); self.watchTimer = nil }
        }
    }

    // MARK: - Receiver

    /// Sends a receiver window home (↩, close, or carried back across).
    func returnReceiver(_ sourceWindowId: UInt32, edge: PeerEdge?, position: CGFloat) {
        guard let w = receivers.removeValue(forKey: sourceWindowId) else { return }
        w.closeQuietly()
        send(StreamMessage.handoffReturn(windowId: sourceWindowId, edge: edge, position: Float32(position)))
        onChange()
    }

    private func openReceiver(_ b: HandoffBeginPayload) {
        guard let host = peerHost() else {
            send(StreamMessage.handoffReject(windowId: b.windowId, reason: .error)); return
        }
        receivers.removeValue(forKey: b.windowId)?.closeQuietly()
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        var size = CGSize(width: CGFloat(b.width), height: CGFloat(b.height))
        let fit = min(1, screen.width * 0.9 / size.width, (screen.height * 0.9 - ReceiverWindow.stripHeight) / size.height)
        size = CGSize(width: size.width * fit, height: size.height * fit)
        let w = ReceiverWindow(sourceWindowId: b.windowId, title: b.title, app: b.appName, size: size,
                               host: host, port: b.streamPort)
        w.onReturnRequested = { [weak self] in self?.returnReceiver(b.windowId, edge: nil, position: 0) }
        receivers[b.windowId] = w
        w.place(edge: b.edge, position: CGFloat(b.position))
        if isCarryHeld() { w.follow(grab: CGPoint(x: CGFloat(b.grabX), y: CGFloat(b.grabY)), isHeld: isCarryHeld) }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        send(StreamMessage.handoffAccept(windowId: b.windowId))
        clog("HANDOFF: showing \"\(b.appName) — \(b.title)\" from the peer (\(b.width)x\(b.height), port \(b.streamPort))")
        onChange()
    }

    // MARK: - Messages

    /// Returns true when `type` was a handoff message.
    func receive(type: StreamMessageType, payload: Data) -> Bool {
        switch type {
        case .handoffBegin:
            if let b = PeerParse.handoffBegin(payload) { openReceiver(b) }
        case .handoffAccept:
            if let id = PeerParse.windowId(payload) { outgoing[id]?.accepted = true }
        case .handoffReject:
            if let r = PeerParse.idAndReason(payload) {
                clog("HANDOFF: peer declined window \(r.id) (\(r.reason))")
                finishOutgoing(r.id, underCursor: false)
            }
        case .handoffReturn:
            if let r = PeerParse.handoffReturn(payload) { finishOutgoing(r.windowId, underCursor: r.edge != nil) }
        case .windowClosed:
            if let id = PeerParse.windowId(payload), let w = receivers.removeValue(forKey: id) {
                w.closeQuietly()
                onChange()
            }
        default:
            return false
        }
        return true
    }

    /// Link dropped: everything comes home, every receiver closes.
    func reset() {
        for id in Array(outgoing.keys) { finishOutgoing(id, underCursor: false) }
        for w in receivers.values { w.closeQuietly() }
        receivers.removeAll()
        onChange()
    }

    // MARK: - Helpers

    static func isPortFree(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in6()
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_addr = in6addr_any
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
            }
        }
    }

    /// Backing scale of the screen showing most of `frame` (top-left global).
    static func backingScale(for frame: CGRect) -> CGFloat {
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        let flipped = CGRect(x: frame.minX, y: mainHeight - frame.maxY, width: frame.width, height: frame.height)
        let best = NSScreen.screens.max { a, b in
            let ia = a.frame.intersection(flipped), ib = b.frame.intersection(flipped)
            return (ia.isNull ? 0 : ia.width * ia.height) < (ib.isNull ? 0 : ib.width * ib.height)
        }
        return best?.backingScaleFactor ?? 1
    }
}
