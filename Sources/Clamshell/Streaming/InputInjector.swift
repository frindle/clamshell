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
    private var modifierFlags: CGEventFlags = []

    /// Every event this class posts is tagged with this user-data value on a
    /// private event source, so the peer link's own CGEventTap
    /// (Peer/EdgeController.swift) can recognise and pass through injected
    /// input instead of treating it as the local user reaching a screen edge.
    static let injectedTag: Int64 = 0x434C_414D // "CLAM"
    static let source: CGEventSource? = {
        let s = CGEventSource(stateID: .privateState)
        s?.userData = injectedTag
        return s
    }()
    static func isInjected(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == injectedTag
    }

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
        let event = CGEvent(mouseEventSource: Self.source, mouseType: type,
                            mouseCursorPosition: point, mouseButton: button)
        event?.flags = modifierFlags
        event?.post(tap: .cghidEventTap)
    }

    func mouseButton(button: UInt8, down: Bool, x: Float32, y: Float32) {
        let point = map(x, y)
        let right = button == 1
        if right { rightDown = down } else { leftDown = down }
        let type: CGEventType = right ? (down ? .rightMouseDown : .rightMouseUp)
                                      : (down ? .leftMouseDown : .leftMouseUp)
        let event = CGEvent(mouseEventSource: Self.source, mouseType: type,
                            mouseCursorPosition: point,
                            mouseButton: right ? .right : .left)
        event?.flags = modifierFlags
        event?.post(tap: .cghidEventTap)
    }

    func scroll(dx: Float32, dy: Float32) {
        // Pixel-unit scroll wheel: dy is vertical, dx horizontal. CGEvent's
        // wheel1 is vertical, wheel2 horizontal. Deltas come from the network
        // trust boundary: Int32(NaN/±inf/huge) traps, so clamp non-finite to 0
        // and cap magnitude before the conversion.
        //
        // Injected directly at .cghidEventTap (as low-level as a synthetic
        // event can go), which system scroll-direction utilities like Scroll
        // Reverser don't reliably intercept/invert the same way they do real
        // hardware scroll input -- confirmed live, not guessed. Rather than
        // depend on third-party tap interop that may silently vary by
        // version/tool, Clamshell owns inversion itself.
        func sane(_ v: Float32) -> Int32 { v.isFinite ? Int32(min(max(v, -10000), 10000)) : 0 }
        let invert = UserDefaults.standard.bool(forKey: "invertScroll")
        let sign: Float32 = invert ? -1 : 1
        CGEvent(scrollWheelEvent2Source: Self.source, units: .pixel, wheelCount: 2,
                wheel1: sane(dy * sign), wheel2: sane(dx * sign), wheel3: 0)?.post(tap: .cghidEventTap)
    }

    /// Only the documented modifier bits cross the trust boundary; the rest
    /// of a CGEventFlags word (non-coalesced, secondary-fn, private bits)
    /// is not something a remote peer gets to set on events posted here.
    static let allowedFlagBits: UInt64 =
        CGEventFlags.maskAlphaShift.rawValue | CGEventFlags.maskShift.rawValue |
        CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue |
        CGEventFlags.maskCommand.rawValue | CGEventFlags.maskNumericPad.rawValue |
        CGEventFlags.maskSecondaryFn.rawValue | CGEventFlags.maskHelp.rawValue

    func key(macKeyCode: UInt16, down: Bool, flags: UInt64) {
        guard let event = CGEvent(keyboardEventSource: Self.source,
                                  virtualKey: CGKeyCode(macKeyCode), keyDown: down) else { return }
        let masked = CGEventFlags(rawValue: flags & Self.allowedFlagBits)
        event.flags = masked
        // Modifier keys posted as plain key events don't make the system
        // hold the modifier for the *mouse* events that follow (a Cmd-click
        // from a peer), so remember the peer's modifier state and stamp it
        // on mouse events too.
        if Self.modifierMask(for: macKeyCode) != nil {
            modifierFlags = masked
        }
        event.post(tap: .cghidEventTap)
    }

    /// Which CGEventFlags bit a modifier key code toggles, nil for non-modifiers.
    static func modifierMask(for keyCode: UInt16) -> CGEventFlags? {
        switch keyCode {
        case 54, 55: return .maskCommand
        case 56, 60: return .maskShift
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        case 57: return .maskAlphaShift
        case 63: return .maskSecondaryFn
        default: return nil
        }
    }

    /// Lets go of anything a peer left pressed — called when its cursor
    /// leaves this machine or the link drops, so a button or modifier can't
    /// stay stuck down on a machine nobody is touching.
    /// Caps Lock is a toggle, not a held key, so it is deliberately left alone.
    func releaseAll() {
        let p = lastPointNormalized()
        if leftDown { mouseButton(button: 0, down: false, x: Float32(p.x), y: Float32(p.y)) }
        if rightDown { mouseButton(button: 1, down: false, x: Float32(p.x), y: Float32(p.y)) }
        for (code, mask) in [(55, CGEventFlags.maskCommand), (56, .maskShift), (58, .maskAlternate), (59, .maskControl), (63, .maskSecondaryFn)]
            where modifierFlags.contains(mask) {
            modifierFlags.remove(mask)
            key(macKeyCode: UInt16(code), down: false, flags: modifierFlags.rawValue)
        }
        modifierFlags = []
    }

    private func lastPointNormalized() -> CGPoint {
        let b = boundsProvider()
        guard b.width > 0, b.height > 0 else { return .zero }
        return CGPoint(x: (lastPoint.x - b.origin.x) / b.width, y: (lastPoint.y - b.origin.y) / b.height)
    }
}
