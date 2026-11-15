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
    /// Every injected event goes through this queue and is posted from its
    /// serial queue in arrival order; the injector posts nothing directly.
    private let queue: InputQueue

    private static func makeQueue() -> InputQueue {
        InputQueue(cursor: { CGEvent(source: nil)?.location ?? .zero },
                   onFirstDrop: { clog("INPUT: backlog full; dropping new input events (logged once per session).") },
                   sink: { InputInjector.post($0) })
    }

    private static func makeCore(_ bounds: @escaping () -> CGRect, queue: InputQueue) -> InputCore {
        let core = InputCore(
            boundsProvider: bounds,
            displaysProvider: { activeDisplayBounds() },
            cursorProvider: { CGEvent(source: nil)?.location ?? .zero },
            clock: { ProcessInfo.processInfo.systemUptime },
            doubleClickInterval: { NSEvent.doubleClickInterval })
        core.isBacklogged = { [unowned queue] in queue.isBacklogged }
        return core
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
        queue = Self.makeQueue()
        core = Self.makeCore({ CGDisplayBounds(displayID) }, queue: queue) // global desktop coords, points
        Self.warnIfNoAccessibilityPermission()
    }

    /// Window Handoff: map into the *window's* current global frame instead
    /// of a display's. Looked up live (not cached at connect time) because
    /// the window can be dragged mid-session; explicit-selection v1 has no
    /// AX hide/move (see WindowHandoff/WindowHideSelfTest.swift), so the
    /// window stays wherever the user leaves it while streamed.
    init(windowID: UInt32) {
        queue = Self.makeQueue()
        core = Self.makeCore({ Self.liveWindowBounds(windowID) ?? .zero }, queue: queue)
        Self.warnIfNoAccessibilityPermission()
    }

    /// For tests: a core and queue the caller built, with a recording sink.
    init(core: InputCore, queue: InputQueue) {
        self.core = core
        self.queue = queue
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
        guard queue.hasRoom() else { return }
        queue.enqueue(core.mouseMove(x: x, y: y))
    }

    func mouseButton(button: UInt8, down: Bool, x: Float32, y: Float32) {
        _ = Self.untrustedLogOnce
        // Ask for room before InputCore sees a press, so a dropped down never
        // becomes "held" there. Over the bound only the release of a button
        // InputCore has as held gets through.
        if !queue.hasRoom() && (down || !core.isButtonHeld(Int(button))) { return }
        queue.enqueue(core.mouseButton(button: button, down: down, x: x, y: y))
    }

    func mouseButtonAtCursor(button: UInt8, down: Bool) {
        _ = Self.untrustedLogOnce
        if !queue.hasRoom() && (down || !core.isButtonHeld(Int(button))) { return }
        queue.enqueue(core.mouseButtonAtCursor(button: button, down: down))
    }

    func mouseRelative(dx: Float32, dy: Float32) {
        _ = Self.untrustedLogOnce
        guard queue.hasRoom() else { return }
        queue.enqueue(core.mouseRelative(dx: dx, dy: dy))
    }

    func text(_ payload: Data) {
        _ = Self.untrustedLogOnce
        guard queue.hasRoom(textBytes: payload.count) else { return }
        let events = core.text(payload)
        queue.enqueue(events, textBytes: payload.count)
    }

    /// End of session: abandons everything waiting, releases what was actually
    /// posted as down, and posts nothing more.
    func releaseAll() {
        _ = core.releaseAll() // clear InputCore's held state
        queue.releaseAll()
    }

    func scroll(dx: Float32, dy: Float32) {
        _ = Self.untrustedLogOnce
        // Clamping and Clamshell's own inversion live in InputCore.scroll:
        // injected at .cghidEventTap, scroll-direction utilities don't reliably
        // invert synthetic events the way they do hardware scrolling.
        guard queue.hasRoom() else { return }
        let invert = UserDefaults.standard.bool(forKey: "invertScroll")
        queue.enqueue(core.scroll(dx: dx, dy: dy, invert: invert))
    }

    func key(macKeyCode: UInt16, down: Bool, flags: UInt64) {
        _ = Self.untrustedLogOnce
        if !queue.hasRoom() && (down || !core.isKeyHeld(macKeyCode)) { return }
        queue.enqueue(core.key(macKeyCode: macKeyCode, down: down, flags: flags))
    }

    // MARK: - CGEvent layer

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
        case let .scroll(dx, dy):
            // Pixel-unit wheel: wheel1 is vertical, wheel2 horizontal.
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                    wheel1: dy, wheel2: dx, wheel3: 0)?.post(tap: .cghidEventTap)
        case let .key(code, down, flags):
            guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down) else { return }
            ev.flags = CGEventFlags(rawValue: flags)
            ev.post(tap: .cghidEventTap)
        case let .text(chunk):
            let units = Array(chunk.utf16)
            for down in [true, false] {
                guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
                // A modifier the user holds on the host must not turn typed
                // text into shortcuts.
                ev.flags = []
                ev.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                ev.post(tap: .cghidEventTap)
            }
        }
    }
}
