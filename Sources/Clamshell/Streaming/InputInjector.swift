import Foundation
import CoreGraphics

// Maps normalized client coordinates (0..1, origin top-left) into the
// streamed target's global bounds and injects CGEvents. Target is either a
// whole display (bounds fixed for the session) or a single window (bounds
// re-queried live since the window can move — see the window init).

final class InputInjector {
    private let boundsProvider: () -> CGRect
    private var leftDown = false
    private var rightDown = false
    private var lastPoint = CGPoint.zero

    init(displayID: CGDirectDisplayID) {
        self.boundsProvider = { CGDisplayBounds(displayID) } // global desktop coords, points
        Self.warnIfNoAccessibilityPermission()
    }

    /// Window Handoff: map into the *window's* current global frame instead
    /// of a display's. Looked up live (not cached at connect time) because
    /// the window can be dragged mid-session; explicit-selection v1 has no
    /// AX hide/move (see WindowHandoff/WindowHideSelfTest.swift), so the
    /// window stays wherever the user leaves it while streamed.
    init(windowID: UInt32) {
        self.boundsProvider = { Self.liveWindowBounds(windowID) ?? .zero }
        Self.warnIfNoAccessibilityPermission()
    }

    private static func warnIfNoAccessibilityPermission() {
        // CGEventPost silently no-ops without Accessibility permission — the
        // stream would look healthy while every click/key vanishes. Say so.
        if !CGPreflightPostEventAccess() {
            clog("STREAM: WARNING — Accessibility permission NOT granted; injected mouse/keyboard events will be silently ignored. Grant it in System Settings > Privacy & Security > Accessibility.")
        }
    }

    /// Current global-coordinate frame of a window (points, top-left origin —
    /// same convention as CGDisplayBounds), via the Window Server's own list
    /// rather than Accessibility (which is blocked on this dev Mac — see
    /// WindowHideSelfTest.swift). Returns nil if the window has closed.
    private static func liveWindowBounds(_ windowID: UInt32) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(windowID)) as? [[String: Any]])?.first,
              let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
              let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) as CGRect? else { return nil }
        return rect
    }

    private func map(_ x: Float32, _ y: Float32) -> CGPoint {
        let bounds = boundsProvider()
        // Trust boundary: a network-supplied event landing at (0,0) — the
        // Apple menu — because the window closed/moved mid-lookup would be a
        // real hazard, not just a cosmetic glitch. Re-inject at the last
        // known-good point instead of trusting a zeroed bounds rect.
        guard bounds.width > 0, bounds.height > 0 else { return lastPoint }
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
