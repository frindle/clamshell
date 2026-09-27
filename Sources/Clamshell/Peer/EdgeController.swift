import AppKit

// The controlling half of the shared-desk KVM (PROTOCOL.md "Peer link —
// shared mouse and keyboard"): a session-level CGEventTap that watches the
// physical mouse. When it's pushed out through the configured edge, control
// moves to the peer — the local cursor is frozen and hidden, every mouse,
// scroll and key event is swallowed here and forwarded as the v1 INPUT_*
// messages (normalized to the peer's screen), until the virtual cursor
// comes back out through the edge it went in by.
//
// Events this process injected on a peer's behalf (InputInjector, tagged
// with its private event source's user data) are always passed through, so
// being controlled never looks like the local user reaching an edge.
//
// Needs Accessibility (an active tap). Secure Event Input (a focused
// password field) hides keystrokes from every tap — a macOS rule; they stay
// local while it's on. Main-thread only.

final class EdgeController {
    /// Edge of THIS machine's screen that leads to the peer.
    var edge: PeerEdge
    var send: (Data) -> Void = { _ in }
    /// The linked peer's primary-screen size in its units, nil when unlinked.
    var peerSize: () -> CGSize? = { nil }
    /// Crossed to the peer while carrying something (already cancelled locally).
    var onCarryCrossed: (Carry, _ peerEdge: PeerEdge, _ fraction: CGFloat) -> Void = { _, _, _ in }
    /// The carrying button was released on the peer's side.
    var onCarryDropped: (Carry) -> Void = { _ in }
    var onControlChange: (_ controllingPeer: Bool) -> Void = { _ in }

    let carryDetector = CarryDetector()
    /// Seams for `edge-selftest`: the real cursor/display calls by default,
    /// no-ops and synthetic screens under test (so a test never moves the
    /// real cursor or freezes the real mouse).
    struct CursorOps {
        var freeze: (Bool) -> Void = { CGAssociateMouseAndMouseCursorPosition($0 ? 0 : 1) }
        var warp: (CGPoint) -> Void = { CGWarpMouseCursorPosition($0) }
        var hide: (Bool) -> Void = { $0 ? CGDisplayHideCursor(CGMainDisplayID()) : CGDisplayShowCursor(CGMainDisplayID()) }
        var cancelLocalDrag: (_ files: Bool, _ at: CGPoint) -> Void = { CarryDetector.cancelLocalDrag(files: $0, at: $1) }
        var displays: () -> [CGRect] = { EdgeController.displayBounds() }
    }
    var ops = CursorOps()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var remote: RemoteCursor?
    private var exitDisplay = CGRect.zero
    private var scale: CGFloat = 1
    private var carry: Carry?
    private var leftHeld = false
    private var cursorHidden = false

    var isControllingPeer: Bool { remote != nil }

    init(edge: PeerEdge) { self.edge = edge }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                    .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                    .otherMouseDown, .otherMouseUp, .otherMouseDragged,
                                    .scrollWheel, .keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: edgeTapCallback, userInfo: refcon) else {
            clog("PEER: could not create the edge event tap — Accessibility permission missing?")
            return false
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        runLoopSource = src
        CGEvent.tapEnable(tap: tap, enable: true)
        clog("PEER: edge tap on (\(edge.name) edge leads to the peer)")
        return true
    }

    func stop() {
        if remote != nil { returnHome(fraction: 0.5) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil; runLoopSource = nil
    }

    /// Link dropped / panic key / peer gone: take control back right here.
    func returnHome(fraction: CGFloat, notifyPeer: Bool = true) {
        guard remote != nil else { return }
        if notifyPeer { send(StreamMessage.edgeLeave()) }
        remote = nil
        carry = nil
        let p = EdgeGeometry.reentryPoint(display: exitDisplay, edge: edge, fraction: fraction)
        ops.warp(p)
        ops.freeze(false)
        if cursorHidden { ops.hide(false); cursorHidden = false }
        clog("PEER: control back on this Mac")
        onControlChange(false)
    }

    fileprivate func reenableTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    // MARK: - Event handling (main thread, from the tap)

    func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        if InputInjector.isInjected(event) { return event }
        if remote == nil { return handleLocal(type, event) }
        return handleRemote(type, event)
    }

    private func handleLocal(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        switch type {
        case .leftMouseDown:
            leftHeld = true
            carryDetector.mouseDown(at: event.location)
        case .leftMouseUp:
            leftHeld = false
            carryDetector.mouseUp()
        case .mouseMoved, .leftMouseDragged:
            guard let peer = peerSize() else { return event }
            let delta = CGVector(dx: event.getDoubleValueField(.mouseEventDeltaX),
                                 dy: event.getDoubleValueField(.mouseEventDeltaY))
            guard let exit = EdgeGeometry.exit(at: event.location, delta: delta, edge: edge,
                                               displays: ops.displays()) else { return event }
            var carried: Carry?
            if type == .leftMouseDragged || leftHeld {
                // Only a real carry may cross with the button down: a text
                // selection or a slider drag stays on this machine.
                guard let c = carryDetector.evaluate(at: event.location) else { return event }
                carried = c
            }
            crossToPeer(exit: exit, carry: carried, peer: peer, at: event.location)
            return nil
        default:
            break
        }
        return event
    }

    private func crossToPeer(exit: (display: CGRect, fraction: CGFloat), carry: Carry?, peer: CGSize, at p: CGPoint) {
        let peerEdge = edge.opposite
        let cursor = RemoteCursor(entryEdge: peerEdge, fraction: exit.fraction, peerSize: peer)
        remote = cursor
        exitDisplay = exit.display
        scale = EdgeGeometry.speedScale(localWidth: exit.display.width, peerWidth: peer.width)
        self.carry = carry
        let n = cursor.normalized
        send(StreamMessage.edgeEnter(edge: peerEdge, x: n.x, y: n.y, leftButtonDown: carry != nil))
        send(StreamMessage.mouseMove(x: n.x, y: n.y))
        ops.freeze(true)
        // Hiding the cursor from a background app is best effort: macOS
        // only honours it for the frontmost app, so the frozen arrow may
        // stay visible at the edge. It never moves while the peer has control.
        if !cursorHidden { ops.hide(true); cursorHidden = true }
        clog("PEER: control → peer (\(peerEdge.name) edge at \(String(format: "%.2f", exit.fraction))\(carry.map { " carrying \(Self.describe($0))" } ?? ""))")
        onControlChange(true)
        if let carry {
            if case .files = carry { ops.cancelLocalDrag(true, p) } else { ops.cancelLocalDrag(false, p) }
            onCarryCrossed(carry, peerEdge, exit.fraction)
        }
    }

    private func handleRemote(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        guard var cursor = remote else { return event }
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let dx = CGFloat(event.getDoubleValueField(.mouseEventDeltaX)) * scale
            let dy = CGFloat(event.getDoubleValueField(.mouseEventDeltaY)) * scale
            if let back = cursor.move(dx: dx, dy: dy) {
                remote = cursor
                returnHome(fraction: back)
                return nil
            }
            remote = cursor
            let n = cursor.normalized
            send(StreamMessage.mouseMove(x: n.x, y: n.y))
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp:
            let down = type == .leftMouseDown || type == .rightMouseDown
            let button: UInt8 = (type == .rightMouseDown || type == .rightMouseUp) ? 1 : 0
            if button == 0 { leftHeld = down }
            let n = cursor.normalized
            send(StreamMessage.mouseButton(button: button, down: down, x: n.x, y: n.y))
            if button == 0, !down, let c = carry {
                carry = nil
                onCarryDropped(c)
            }
        case .scrollWheel:
            let dy = Float32(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
            let dx = Float32(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2))
            if dx != 0 || dy != 0 { send(StreamMessage.scroll(dx: dx, dy: dy)) }
        case .keyDown, .keyUp:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if type == .keyDown, EdgeKeys.isPanic(keyCode: code, flags: event.flags) {
                returnHome(fraction: 0.5)
                return nil
            }
            send(StreamMessage.key(macKeyCode: code, down: type == .keyDown,
                                   flags: event.flags.rawValue & InputInjector.allowedFlagBits))
        case .flagsChanged:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags.rawValue & InputInjector.allowedFlagBits
            if let t = EdgeKeys.modifierTransition(keyCode: code, flags: event.flags) {
                send(StreamMessage.key(macKeyCode: code, down: t.down, flags: flags))
                if t.isToggle { send(StreamMessage.key(macKeyCode: code, down: false, flags: flags)) }
            }
        default:
            break // other buttons: swallowed, not forwarded (wire has left/right only)
        }
        return nil
    }

    static func displayBounds() -> [CGRect] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).map { CGDisplayBounds($0) }
    }

    static func describe(_ c: Carry) -> String {
        switch c {
        case .files(let urls): return "\(urls.count) file(s)"
        case .window(_, _, _, let title, let app, _): return "window \"\(app) — \(title)\""
        case .receiver(let id): return "handed-off window \(id) (return)"
        }
    }
}

private func edgeTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                             refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<EdgeController>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        controller.reenableTap()
        return Unmanaged.passUnretained(event)
    }
    guard let out = controller.handle(type, event) else { return nil }
    return Unmanaged.passUnretained(out)
}
