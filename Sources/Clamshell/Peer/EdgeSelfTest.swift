import AppKit

// `clamshell edge-selftest` — the shared-desk KVM logic without touching the
// real mouse: edge geometry across display layouts, the virtual cursor on
// the peer, key/modifier forwarding rules, and the EdgeController state
// machine driven with synthetic CGEvents (never posted) through its
// CursorOps seam, checking the exact wire messages it emits.
//
// Not covered here (needs a real session): the CGEventTap itself, cursor
// hiding/freezing, and RemoteInputSink's injection (it posts real events).
enum EdgeSelfTest {
    private static var failures = 0
    private static func check(_ ok: Bool, _ what: String) {
        if !ok { failures += 1; print("FAIL: \(what)") } else { print("ok   \(what)") }
    }
    private static func near(_ a: CGFloat, _ b: CGFloat, _ eps: CGFloat = 0.01) -> Bool { abs(a - b) <= eps }

    static func run() -> Int32 {
        failures = 0
        geometry()
        cursor()
        keys()
        controller()
        print(failures == 0 ? "PASS: edge selftest" : "FAIL: \(failures) check(s) failed")
        return failures == 0 ? 0 : 1
    }

    private static func geometry() {
        let single = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        let e = EdgeGeometry.exit(at: CGPoint(x: 1439, y: 450), delta: CGVector(dx: 4, dy: 0), edge: .right, displays: single)
        check(e != nil && near(e!.fraction, 0.5), "right edge exit at mid-height")
        check(EdgeGeometry.exit(at: CGPoint(x: 1439, y: 450), delta: CGVector(dx: -4, dy: 0), edge: .right, displays: single) == nil,
              "moving away from the edge doesn't cross")
        check(EdgeGeometry.exit(at: CGPoint(x: 1200, y: 450), delta: CGVector(dx: 4, dy: 0), edge: .right, displays: single) == nil,
              "not at the edge doesn't cross")
        check(EdgeGeometry.exit(at: CGPoint(x: 0, y: 225), delta: CGVector(dx: -3, dy: 0), edge: .left, displays: single).map { near($0.fraction, 0.25) } == true,
              "left edge exit at a quarter")
        check(EdgeGeometry.exit(at: CGPoint(x: 360, y: 0), delta: CGVector(dx: 0, dy: -2), edge: .top, displays: single).map { near($0.fraction, 0.25) } == true,
              "top edge exit")
        check(EdgeGeometry.exit(at: CGPoint(x: 1080, y: 899), delta: CGVector(dx: 0, dy: 2), edge: .bottom, displays: single).map { near($0.fraction, 0.75) } == true,
              "bottom edge exit")

        // Two displays side by side: the inner seam is not a peer edge.
        let dual = [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 1440, y: -90, width: 1920, height: 1080)]
        check(EdgeGeometry.exit(at: CGPoint(x: 1439, y: 450), delta: CGVector(dx: 5, dy: 0), edge: .right, displays: dual) == nil,
              "seam between two local displays is not an exit")
        let far = EdgeGeometry.exit(at: CGPoint(x: 3359, y: 450), delta: CGVector(dx: 5, dy: 0), edge: .right, displays: dual)
        check(far != nil && far!.display == dual[1] && near(far!.fraction, 0.5), "outer edge of the second display exits")
        // Offset layout: the part of display 1's top edge not under display 2 is an exit.
        let stacked = [CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: 500, y: -600, width: 1000, height: 600)]
        check(EdgeGeometry.exit(at: CGPoint(x: 200, y: 0), delta: CGVector(dx: 0, dy: -3), edge: .top, displays: stacked) != nil,
              "uncovered stretch of a top edge exits")
        check(EdgeGeometry.exit(at: CGPoint(x: 700, y: 0), delta: CGVector(dx: 0, dy: -3), edge: .top, displays: stacked) == nil,
              "covered stretch of a top edge does not")

        let r = EdgeGeometry.reentryPoint(display: single[0], edge: .right, fraction: 0.5)
        check(near(r.x, 1436) && near(r.y, 449.5), "re-entry point is inset from the edge")
        check(near(EdgeGeometry.speedScale(localWidth: 1440, peerWidth: 2880), 2) &&
              near(EdgeGeometry.speedScale(localWidth: 1440, peerWidth: 100), 0.5) &&
              near(EdgeGeometry.speedScale(localWidth: 1000, peerWidth: 9000), 3), "speed scale clamps to 0.5...3")
    }

    private static func cursor() {
        var c = RemoteCursor(entryEdge: .left, fraction: 0.5, peerSize: CGSize(width: 1921, height: 1081))
        check(near(c.position.x, 0) && near(c.position.y, 540), "enters on the peer's left edge")
        check(c.move(dx: 100, dy: 0) == nil && near(CGFloat(c.normalized.x), 100.0 / 1920), "moves inward")
        check(c.move(dx: 0, dy: 5000) == nil && near(c.position.y, 1080), "clamped at the bottom")
        let back = c.move(dx: -150, dy: 0)
        check(back != nil && near(back!, 1.0), "leaving through the entry edge returns the along-edge position")
        var t = RemoteCursor(entryEdge: .top, fraction: 0.25, peerSize: CGSize(width: 1001, height: 501))
        check(near(t.position.x, 250) && near(t.position.y, 0), "enters on the top edge")
        check(t.move(dx: 0, dy: 10) == nil && t.move(dx: 0, dy: -11) != nil, "top entry leaves upward")
        var r = RemoteCursor(entryEdge: .right, fraction: 0, peerSize: CGSize(width: 101, height: 101))
        check(r.move(dx: 1000, dy: 0) != nil, "right entry leaves rightward")
    }

    private static func keys() {
        check(EdgeKeys.modifierTransition(keyCode: 55, flags: .maskCommand)?.down == true, "cmd flagsChanged with cmd set = down")
        check(EdgeKeys.modifierTransition(keyCode: 55, flags: [])?.down == false, "cmd flagsChanged without cmd = up")
        check(EdgeKeys.modifierTransition(keyCode: 60, flags: .maskShift)?.down == true, "right shift maps to shift")
        check(EdgeKeys.modifierTransition(keyCode: 57, flags: [])?.isToggle == true, "caps lock is a toggle tap")
        check(EdgeKeys.modifierTransition(keyCode: 0, flags: []) == nil, "letters aren't modifiers")
        check(EdgeKeys.isPanic(keyCode: 0x25, flags: [.maskControl, .maskAlternate, .maskCommand]), "ctrl+opt+cmd+L is the panic key")
        check(!EdgeKeys.isPanic(keyCode: 0x25, flags: [.maskCommand]), "cmd+L is not")
    }

    private static func controller() {
        var sent: [(StreamMessageType, Data)] = []
        let parser = StreamMessageParser()
        parser.onMessage = { t, p in sent.append((t, p)) }
        let ec = EdgeController(edge: .right)
        var warped: CGPoint?
        var frozen = false
        ec.ops = EdgeController.CursorOps(freeze: { frozen = $0 }, warp: { warped = $0 }, hide: { _ in },
                                          cancelLocalDrag: { _, _ in }, displays: { [CGRect(x: 0, y: 0, width: 1000, height: 500)] })
        ec.send = { parser.feed($0) }
        ec.peerSize = { CGSize(width: 2001, height: 1001) }
        var controlling = false
        ec.onControlChange = { controlling = $0 }

        func mouse(_ type: CGEventType, _ p: CGPoint, dx: Double = 0, dy: Double = 0, injected: Bool = false) -> CGEvent {
            let e = CGEvent(mouseEventSource: injected ? InputInjector.source : nil, mouseType: type,
                            mouseCursorPosition: p, mouseButton: .left)!
            e.setDoubleValueField(.mouseEventDeltaX, value: dx)
            e.setDoubleValueField(.mouseEventDeltaY, value: dy)
            return e
        }
        func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = []) -> CGEvent {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
            e.flags = flags
            return e
        }

        // Cross out through the right edge.
        var out = ec.handle(.mouseMoved, mouse(.mouseMoved, CGPoint(x: 999, y: 250), dx: 6))
        check(out == nil && controlling && frozen, "pushing through the edge swallows the event and takes control")
        check(sent.count == 2 && sent[0].0 == .edgeEnter && sent[1].0 == .mouseMove, "EDGE_ENTER then MOUSE_MOVE on the wire")
        if let enter = sent.first.flatMap({ PeerParse.edgeEnter($0.1) }) {
            check(enter.edge == .left && enter.x == 0 && abs(enter.y - 0.5) < 0.001 && !enter.leftButtonDown,
                  "enters the peer's LEFT edge at mid-height, no carry")
        } else { check(false, "EDGE_ENTER parses") }
        sent.removeAll()

        // Deltas are scaled (peer twice as wide) and sent as normalized moves.
        out = ec.handle(.mouseMoved, mouse(.mouseMoved, CGPoint(x: 999, y: 250), dx: 10, dy: 0))
        check(out == nil && sent.last?.0 == .mouseMove, "remote move forwarded")
        if let m = sent.last, m.0 == .mouseMove {
            check(abs(m.1.beFloat32(at: 0) - 20.0 / 2000) < 0.0005, "delta scaled by peer/local width (x = 20px on a 2000px peer)")
        }
        sent.removeAll()

        // Injected events always pass through untouched.
        out = ec.handle(.mouseMoved, mouse(.mouseMoved, CGPoint(x: 10, y: 10), dx: 50, injected: true))
        check(out != nil && sent.isEmpty, "injected (CLAM-tagged) events pass through")

        // Keys, modifiers, buttons, scroll.
        _ = ec.handle(.keyDown, key(0, down: true, flags: .maskCommand))
        check(sent.last?.0 == .key && sent.last!.1.beUInt16(at: 0) == 0 && sent.last!.1[sent.last!.1.startIndex + 2] == 1 &&
              sent.last!.1.beUInt64(at: 3) & CGEventFlags.maskCommand.rawValue != 0, "keyDown forwarded with its flags")
        let shift = CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: true)!
        shift.type = .flagsChanged
        shift.flags = .maskShift
        _ = ec.handle(.flagsChanged, shift)
        check(sent.last?.0 == .key && sent.last!.1.beUInt16(at: 0) == 56 && sent.last!.1[sent.last!.1.startIndex + 2] == 1,
              "shift flagsChanged becomes a key-down")
        _ = ec.handle(.leftMouseDown, mouse(.leftMouseDown, CGPoint(x: 999, y: 250)))
        check(sent.last?.0 == .mouseButton && sent.last!.1[sent.last!.1.startIndex] == 0 && sent.last!.1[sent.last!.1.startIndex + 1] == 1,
              "left press forwarded")
        _ = ec.handle(.leftMouseUp, mouse(.leftMouseUp, CGPoint(x: 999, y: 250)))
        if let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -12, wheel2: 3, wheel3: 0) {
            _ = ec.handle(.scrollWheel, scroll)
            check(sent.last?.0 == .scroll && sent.last!.1.beFloat32(at: 4) == -12 && sent.last!.1.beFloat32(at: 0) == 3,
                  "scroll forwarded as dx/dy pixels")
        }
        sent.removeAll()

        // Come back out through the entry edge.
        out = ec.handle(.mouseMoved, mouse(.mouseMoved, CGPoint(x: 999, y: 250), dx: -40, dy: 0))
        check(out == nil && !controlling && !frozen && sent.last?.0 == .edgeLeave, "leaving the peer's entry edge returns control")
        check(warped.map { abs($0.x - 996) < 0.01 && abs($0.y - 249.5) < 1 } == true, "cursor re-appears inset at the matching height")
        sent.removeAll()

        // Local movement is untouched; a button-down drag with nothing carried is blocked at the edge.
        out = ec.handle(.mouseMoved, mouse(.mouseMoved, CGPoint(x: 500, y: 250), dx: 3))
        check(out != nil && sent.isEmpty, "ordinary local movement passes through")
        _ = ec.handle(.leftMouseDown, mouse(.leftMouseDown, CGPoint(x: 999, y: 250)))
        out = ec.handle(.leftMouseDragged, mouse(.leftMouseDragged, CGPoint(x: 999, y: 250), dx: 6))
        check(out != nil && sent.isEmpty && !controlling, "a plain drag (text selection) stays local at the edge")
        _ = ec.handle(.leftMouseUp, mouse(.leftMouseUp, CGPoint(x: 999, y: 250)))

        // Panic key.
        _ = ec.handle(.mouseMoved, mouse(.mouseMoved, CGPoint(x: 999, y: 100), dx: 6))
        check(controlling, "crossed again")
        sent.removeAll()
        out = ec.handle(.keyDown, key(0x25, down: true, flags: [.maskControl, .maskAlternate, .maskCommand]))
        check(out == nil && !controlling && sent.last?.0 == .edgeLeave && !sent.contains { $0.0 == .key },
              "ctrl+opt+cmd+L takes control back and is not forwarded")

        // Unlinked: nothing crosses.
        ec.peerSize = { nil }
        out = ec.handle(.mouseMoved, mouse(.mouseMoved, CGPoint(x: 999, y: 250), dx: 6))
        check(out != nil && !controlling, "no peer, no crossing")
    }
}
