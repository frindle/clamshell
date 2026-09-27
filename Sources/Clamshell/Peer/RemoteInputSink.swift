import AppKit

// The controlled half of the shared-desk KVM: input a linked peer forwards
// while its cursor is on this Mac, injected on the main display through the
// same InputInjector the stream server uses (so it's tagged and our own
// EdgeController ignores it). Input is only honoured between EDGE_ENTER and
// EDGE_LEAVE — a peer can't type into this Mac without having crossed.
//
// "Carry" mode: EDGE_ENTER with leftButtonDown=1 means the peer is dragging
// something across (files or a window). No press is injected here — the
// ReceiverWindow / file drop follows the cursor instead — and the matching
// left-button release ends the carry without being injected.
//
// Main-thread only.

final class RemoteInputSink {
    private var injector: InputInjector?
    private(set) var active = false
    /// Edge of THIS screen the peer's cursor came in on (it leaves by it too).
    private(set) var entryEdge: PeerEdge = .left
    /// Peer is carrying something across; cleared by its left-button release.
    private(set) var carrying = false
    private var leftDown = false
    let carryDetector = CarryDetector()
    var onActiveChange: (Bool) -> Void = { _ in }
    var onCarryEnded: () -> Void = {}

    private var mainBounds: CGRect { CGDisplayBounds(CGMainDisplayID()) }

    func enter(_ e: EdgeEnterPayload) {
        injector = injector ?? InputInjector(displayID: CGMainDisplayID())
        active = true
        entryEdge = e.edge
        carrying = e.leftButtonDown
        leftDown = false
        injector?.mouseMove(x: e.x, y: e.y)
        clog("PEER: peer took control (entered on \(e.edge.name)\(carrying ? ", carrying" : ""))")
        onActiveChange(true)
    }

    /// Returns what the peer's (injected) left button was carrying when its
    /// cursor left, so the caller can hand it over; releases everything.
    func leave() -> (carry: Carry?, fraction: CGFloat) {
        guard active else { return (nil, 0.5) }
        let loc = NSEventLocationTopLeft()
        let b = mainBounds
        let fraction: CGFloat
        switch entryEdge {
        case .left, .right: fraction = b.height > 0 ? (loc.y - b.minY) / b.height : 0.5
        case .top, .bottom: fraction = b.width > 0 ? (loc.x - b.minX) / b.width : 0.5
        }
        var carry: Carry?
        if leftDown {
            carry = carryDetector.evaluate(at: loc)
            if let carry, case .files = carry {
                CarryDetector.cancelLocalDrag(files: true, at: loc)
                leftDown = false
            }
        }
        injector?.releaseAll()
        leftDown = false
        carrying = false
        active = false
        clog("PEER: peer released control\(carry.map { " carrying \(EdgeController.describe($0))" } ?? "")")
        onActiveChange(false)
        return (carry, min(max(fraction, 0), 1))
    }

    /// Link dropped while the peer had control.
    func reset() {
        guard active else { return }
        injector?.releaseAll()
        active = false; carrying = false; leftDown = false
        onActiveChange(false)
    }

    func handle(type: StreamMessageType, payload: Data) {
        guard active, let injector else { return }
        switch type {
        case .mouseMove:
            guard payload.count >= 8 else { return }
            injector.mouseMove(x: payload.beFloat32(at: 0), y: payload.beFloat32(at: 4))
        case .mouseButton:
            guard payload.count >= 10 else { return }
            let button = payload[payload.startIndex], down = payload[payload.startIndex + 1] == 1
            let x = payload.beFloat32(at: 2), y = payload.beFloat32(at: 6)
            if carrying && button == 0 {
                if !down { carrying = false; onCarryEnded() }
                return
            }
            if button == 0 {
                leftDown = down
                if down {
                    let b = mainBounds
                    carryDetector.mouseDown(at: CGPoint(x: b.minX + CGFloat(min(max(x, 0), 1)) * b.width,
                                                        y: b.minY + CGFloat(min(max(y, 0), 1)) * b.height))
                } else {
                    carryDetector.mouseUp()
                }
            }
            injector.mouseButton(button: button, down: down, x: x, y: y)
        case .key:
            guard payload.count >= 11 else { return }
            injector.key(macKeyCode: payload.beUInt16(at: 0), down: payload[payload.startIndex + 2] == 1,
                         flags: payload.beUInt64(at: 3))
        case .scroll:
            guard payload.count >= 8 else { return }
            injector.scroll(dx: payload.beFloat32(at: 0), dy: payload.beFloat32(at: 4))
        default:
            break
        }
    }
}

/// Current cursor position in global top-left coordinates (CGEvent space).
func NSEventLocationTopLeft() -> CGPoint {
    CGEvent(source: nil)?.location ?? .zero
}
