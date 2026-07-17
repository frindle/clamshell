import Foundation
import CoreGraphics

// Maps normalized client coordinates (0..1, origin top-left) into the
// streamed display's global bounds and injects CGEvents.

final class InputInjector {
    private let displayID: CGDirectDisplayID
    private var leftDown = false
    private var rightDown = false
    private var lastPoint = CGPoint.zero

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        // CGEventPost silently no-ops without Accessibility permission — the
        // stream would look healthy while every click/key vanishes. Say so.
        if !CGPreflightPostEventAccess() {
            clog("STREAM: WARNING — Accessibility permission NOT granted; injected mouse/keyboard events will be silently ignored. Grant it in System Settings > Privacy & Security > Accessibility.")
        }
    }

    private func map(_ x: Float32, _ y: Float32) -> CGPoint {
        let bounds = CGDisplayBounds(displayID) // global desktop coords, points
        let p = CGPoint(
            x: bounds.origin.x + CGFloat(min(max(x, 0), 1)) * bounds.width,
            y: bounds.origin.y + CGFloat(min(max(y, 0), 1)) * bounds.height
        )
        lastPoint = p
        return p
    }

    func mouseMove(x: Float32, y: Float32) {
        let point = map(x, y)
        let type: CGEventType = leftDown ? .leftMouseDragged
                              : rightDown ? .rightMouseDragged
                              : .mouseMoved
        let button: CGMouseButton = rightDown ? .right : .left
        CGEvent(mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
    }

    func mouseButton(button: UInt8, down: Bool, x: Float32, y: Float32) {
        let point = map(x, y)
        let right = button == 1
        if right { rightDown = down } else { leftDown = down }
        let type: CGEventType = right ? (down ? .rightMouseDown : .rightMouseUp)
                                      : (down ? .leftMouseDown : .leftMouseUp)
        CGEvent(mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: point,
                mouseButton: right ? .right : .left)?.post(tap: .cghidEventTap)
    }

    func scroll(dx: Float32, dy: Float32) {
        // Pixel-unit scroll wheel: dy is vertical, dx horizontal. CGEvent's
        // wheel1 is vertical, wheel2 horizontal. Deltas come from the network
        // trust boundary: Int32(NaN/±inf/huge) traps, so clamp non-finite to 0
        // and cap magnitude before the conversion.
        func sane(_ v: Float32) -> Int32 { v.isFinite ? Int32(min(max(v, -10000), 10000)) : 0 }
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                wheel1: sane(dy), wheel2: sane(dx), wheel3: 0)?.post(tap: .cghidEventTap)
    }

    func key(macKeyCode: UInt16, down: Bool, flags: UInt64) {
        guard let event = CGEvent(keyboardEventSource: nil,
                                  virtualKey: CGKeyCode(macKeyCode), keyDown: down) else { return }
        event.flags = CGEventFlags(rawValue: flags)
        event.post(tap: .cghidEventTap)
    }
}
