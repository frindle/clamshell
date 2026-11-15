import Foundation
import CoreGraphics
import ApplicationServices
import AppKit

// Maps normalized client coordinates (0..1, origin top-left) into the
// streamed target's global bounds and injects CGEvents. Target is either a
// whole display (bounds fixed for the session) or a single window (bounds
// re-queried live since the window can move — see the window init).

final class InputInjector {
    private let core: InputCore
    /// All keyboard events (keys and typed text) are posted from this serial
    /// queue, in arrival order, so a long paste cannot stall the server queue
    /// (which also sends video).
    private let keyboard = KeyboardQueue { InputInjector.post($0) }

    private static func makeCore(_ bounds: @escaping () -> CGRect) -> InputCore {
        InputCore(
            boundsProvider: bounds,
            displaysProvider: { activeDisplayBounds() },
            cursorProvider: { CGEvent(source: nil)?.location ?? .zero },
            clock: { ProcessInfo.processInfo.systemUptime },
            doubleClickInterval: { NSEvent.doubleClickInterval })
    }

    private static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    init(displayID: CGDirectDisplayID) {
        core = Self.makeCore { CGDisplayBounds(displayID) } // global desktop coords, points
        Self.warnIfNoAccessibilityPermission()
    }

    /// Window Handoff: map into the *window's* current global frame instead
    /// of a display's. Looked up live (not cached at connect time) because
    /// the window can be dragged mid-session; explicit-selection v1 has no
    /// AX hide/move (see WindowHandoff/WindowHideSelfTest.swift), so the
    /// window stays wherever the user leaves it while streamed.
    init(windowID: UInt32) {
        core = Self.makeCore { Self.liveWindowBounds(windowID) ?? .zero }
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

    /// Logged once per process (static let initializer runs once), not per event.
    private static let untrustedLogOnce: Void = {
        if !AXIsProcessTrusted() {
            clog("INPUT: WARNING — process is not Accessibility-trusted (AXIsProcessTrusted false); injected events may be ignored.")
        }
    }()

    func mouseMove(x: Float32, y: Float32) {
        _ = Self.untrustedLogOnce
        post(core.mouseMove(x: x, y: y))
    }

    func mouseButton(button: UInt8, down: Bool, x: Float32, y: Float32) {
        _ = Self.untrustedLogOnce
        post(core.mouseButton(button: button, down: down, x: x, y: y))
    }

    func mouseRelative(dx: Float32, dy: Float32) {
        _ = Self.untrustedLogOnce
        post(core.mouseRelative(dx: dx, dy: dy))
    }

    func text(_ payload: Data) {
        _ = Self.untrustedLogOnce
        let events = core.text(payload)
        guard !events.isEmpty else { return }
        if case .dropped(let first) = keyboard.enqueueText(events, byteCount: payload.count), first {
            clog("INPUT: text backlog over \(KeyboardQueue.maxBacklogBytes) bytes; dropping new INPUT_TEXT (logged once per session).")
        }
    }

    /// Releases held buttons now; held keys' ups go behind queued keyboard
    /// events, and unstarted text is abandoned.
    func releaseAll() {
        let events = core.releaseAll()
        post(events.filter { if case .mouse = $0 { return true } else { return false } })
        keyboard.releaseAll(events.filter { if case .key = $0 { return true } else { return false } })
    }

    func scroll(dx: Float32, dy: Float32) {
        _ = Self.untrustedLogOnce
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
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                wheel1: sane(dy * sign), wheel2: sane(dx * sign), wheel3: 0)?.post(tap: .cghidEventTap)
    }

    func key(macKeyCode: UInt16, down: Bool, flags: UInt64) {
        _ = Self.untrustedLogOnce
        keyboard.enqueueKey(core.key(macKeyCode: macKeyCode, down: down, flags: flags))
    }

    // MARK: - CGEvent layer

    private func post(_ events: [InputEvent]) { for e in events { Self.post(e) } }

    private static func post(_ event: InputEvent) {
        switch event {
        case let .mouse(action, button, point, clickCount, delta):
            let type: CGEventType
            switch (action, button) {
            case (.move, _): type = .mouseMoved
            case (.down, 0): type = .leftMouseDown
            case (.down, 1): type = .rightMouseDown
            case (.down, _): type = .otherMouseDown
            case (.up, 0): type = .leftMouseUp
            case (.up, 1): type = .rightMouseUp
            case (.up, _): type = .otherMouseUp
            case (.drag, 0): type = .leftMouseDragged
            case (.drag, 1): type = .rightMouseDragged
            case (.drag, _): type = .otherMouseDragged
            }
            let cgButton = CGMouseButton(rawValue: UInt32(button)) ?? .left
            guard let ev = CGEvent(mouseEventSource: nil, mouseType: type,
                                   mouseCursorPosition: point, mouseButton: cgButton) else { return }
            if button > 1 { ev.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button)) }
            if action != .move { ev.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount)) }
            if let d = delta {
                ev.setIntegerValueField(.mouseEventDeltaX, value: Int64(d.dx.rounded()))
                ev.setIntegerValueField(.mouseEventDeltaY, value: Int64(d.dy.rounded()))
            }
            ev.post(tap: .cghidEventTap)
        case let .key(code, down, flags):
            guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down) else { return }
            ev.flags = CGEventFlags(rawValue: flags)
            ev.post(tap: .cghidEventTap)
        case let .text(chunk):
            let units = Array(chunk.utf16)
            for down in [true, false] {
                guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
                ev.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                ev.post(tap: .cghidEventTap)
            }
        }
    }
}
