import Foundation
import CoreGraphics

// Pure geometry for the shared-desk KVM (PROTOCOL.md "Peer link — shared
// mouse and keyboard"). No event taps, no AppKit: everything here is driven
// by `clamshell edge-selftest` with synthetic displays and deltas, and the
// same rules are mirrored in WindowsServer/Peer/EdgeGeometry.cs.
//
// Coordinates are global, top-left origin (CGDisplayBounds / CGEvent
// location on the Mac, virtual-screen pixels on Windows).

enum EdgeGeometry {
    /// If `p` sits on `edge` of the display containing it, with no other
    /// display continuing past that edge at that point, and the pointer is
    /// being pushed outward, returns the display and the 0...1 position
    /// along that edge. Otherwise nil (cursor just moves on locally).
    static func exit(at p: CGPoint, delta: CGVector, edge: PeerEdge,
                     displays: [CGRect]) -> (display: CGRect, fraction: CGFloat)? {
        guard let d = displays.first(where: { $0.contains(p) }) ?? nearest(p, displays) else { return nil }
        let slack: CGFloat = 1
        let atEdge: Bool, pushing: Bool, beyond: CGPoint, fraction: CGFloat
        switch edge {
        case .left:
            atEdge = p.x <= d.minX + slack; pushing = delta.dx < 0
            beyond = CGPoint(x: d.minX - 2, y: p.y); fraction = (p.y - d.minY) / d.height
        case .right:
            atEdge = p.x >= d.maxX - 1 - slack; pushing = delta.dx > 0
            beyond = CGPoint(x: d.maxX + 1, y: p.y); fraction = (p.y - d.minY) / d.height
        case .top:
            atEdge = p.y <= d.minY + slack; pushing = delta.dy < 0
            beyond = CGPoint(x: p.x, y: d.minY - 2); fraction = (p.x - d.minX) / d.width
        case .bottom:
            atEdge = p.y >= d.maxY - 1 - slack; pushing = delta.dy > 0
            beyond = CGPoint(x: p.x, y: d.maxY + 1); fraction = (p.x - d.minX) / d.width
        }
        guard atEdge, pushing, !displays.contains(where: { $0.contains(beyond) }) else { return nil }
        return (d, min(max(fraction, 0), 1))
    }

    /// Where the local cursor reappears when control comes back through
    /// `edge` of `display` at `fraction` — inset so the very next movement
    /// doesn't immediately cross again.
    static func reentryPoint(display d: CGRect, edge: PeerEdge, fraction: CGFloat) -> CGPoint {
        let inset: CGFloat = 3
        let f = min(max(fraction, 0), 1)
        switch edge {
        case .left: return CGPoint(x: d.minX + inset, y: d.minY + f * (d.height - 1))
        case .right: return CGPoint(x: d.maxX - 1 - inset, y: d.minY + f * (d.height - 1))
        case .top: return CGPoint(x: d.minX + f * (d.width - 1), y: d.minY + inset)
        case .bottom: return CGPoint(x: d.minX + f * (d.width - 1), y: d.maxY - 1 - inset)
        }
    }

    private static func nearest(_ p: CGPoint, _ displays: [CGRect]) -> CGRect? {
        displays.min { dist($0, p) < dist($1, p) }
    }
    private static func dist(_ r: CGRect, _ p: CGPoint) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }

    /// Delta multiplier from the controller's units to the peer's, so
    /// crossing the peer's screen takes roughly as much hand movement as
    /// crossing your own (points vs pixels, different sizes). Clamped so a
    /// tiny or huge peer never feels broken.
    static func speedScale(localWidth: CGFloat, peerWidth: CGFloat) -> CGFloat {
        guard localWidth > 0, peerWidth > 0 else { return 1 }
        return min(max(peerWidth / localWidth, 0.5), 3)
    }
}

/// The controller's idea of where the cursor is on the peer's screen while
/// it's driving the peer, in the peer's own units. Moving back out through
/// the edge it came in by returns control.
struct RemoteCursor {
    let size: CGSize
    let entryEdge: PeerEdge   // edge of the PEER's screen we came in on
    private(set) var position: CGPoint

    init(entryEdge: PeerEdge, fraction: CGFloat, peerSize: CGSize) {
        self.size = CGSize(width: max(peerSize.width, 1), height: max(peerSize.height, 1))
        self.entryEdge = entryEdge
        let f = min(max(fraction, 0), 1)
        let w = size.width - 1, h = size.height - 1
        switch entryEdge {
        case .left: position = CGPoint(x: 0, y: f * h)
        case .right: position = CGPoint(x: w, y: f * h)
        case .top: position = CGPoint(x: f * w, y: 0)
        case .bottom: position = CGPoint(x: f * w, y: h)
        }
    }

    /// Applies a delta. Returns the 0...1 position along the entry edge when
    /// the cursor leaves through it (control goes home); otherwise nil and
    /// the cursor is clamped to the peer's screen.
    mutating func move(dx: CGFloat, dy: CGFloat) -> CGFloat? {
        var p = CGPoint(x: position.x + dx, y: position.y + dy)
        let w = size.width - 1, h = size.height - 1
        let out: Bool
        switch entryEdge {
        case .left: out = p.x < 0
        case .right: out = p.x > w
        case .top: out = p.y < 0
        case .bottom: out = p.y > h
        }
        p.x = min(max(p.x, 0), w); p.y = min(max(p.y, 0), h)
        position = p
        guard out else { return nil }
        switch entryEdge {
        case .left, .right: return h > 0 ? p.y / h : 0
        case .top, .bottom: return w > 0 ? p.x / w : 0
        }
    }

    /// 0...1 in the peer's screen — what INPUT_MOUSE_MOVE carries.
    var normalized: (x: Float32, y: Float32) {
        (Float32(position.x / max(size.width - 1, 1)), Float32(position.y / max(size.height - 1, 1)))
    }
}

/// Key forwarding rules shared by the Mac tap and (mirrored) the Windows
/// hook: which modifier a flagsChanged key code is, and whether it went down.
enum EdgeKeys {
    /// flagsChanged carries the new flag word; the key went down iff its
    /// modifier bit is now set. Caps Lock toggles, so it is sent as a tap.
    static func modifierTransition(keyCode: UInt16, flags: CGEventFlags) -> (down: Bool, isToggle: Bool)? {
        guard let mask = InputInjector.modifierMask(for: keyCode) else { return nil }
        if mask == .maskAlphaShift { return (true, true) }
        return (flags.contains(mask), false)
    }

    /// Ctrl+Opt+Cmd+L — take control back locally no matter what (a peer
    /// that stopped answering, a stuck carry). kVK_ANSI_L = 0x25.
    static func isPanic(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        keyCode == 0x25 && flags.contains(.maskControl) && flags.contains(.maskAlternate) && flags.contains(.maskCommand)
    }
}
