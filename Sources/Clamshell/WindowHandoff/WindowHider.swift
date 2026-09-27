import AppKit
import ApplicationServices

// Hides a handed-off window on the source Mac and puts it back afterwards,
// with the public Accessibility API only.
//
// Finding the window: CGWindowID → AXUIElement has no public mapping, so the
// window is matched inside its owning app's kAXWindowsAttribute by frame
// (position + size, which the window list and AX report in the same global
// top-left point space), with the title as a tie-breaker. The private
// _AXUIElementGetWindow is deliberately not used (see AXPrivateShim and
// WindowHideSelfTest.swift for why that route was investigated and
// dropped).
//
// Hiding: capture needs the window un-minimized, so "hide" = move it into
// the bottom-right corner of its display, where macOS keeps only a sliver
// on screen (the same trick AeroSpace uses — the window server won't let a
// window go entirely off every display). If the app refuses the move, or AX
// isn't answering (the environmental AX fault documented in
// WindowHideSelfTest.swift), `hide` reports failure and the handoff goes
// ahead with the window streamed in place, still visible here.

final class WindowHider {
    let element: AXUIElement
    /// Where `restore()` puts it — the handoff sets this to where the window
    /// sat before the drag that carried it off started.
    var originalOrigin: CGPoint
    let size: CGSize
    private(set) var hidden = false

    private init(element: AXUIElement, origin: CGPoint, size: CGSize) {
        self.element = element
        self.originalOrigin = origin
        self.size = size
    }

    /// Finds `windowID`'s AX element by frame. nil if AX is untrusted, the
    /// app exposes no matching window, or AX isn't answering.
    static func find(windowID: CGWindowID, pid: pid_t, frame: CGRect, title: String) -> WindowHider? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return nil }
        var best: (AXUIElement, CGRect, Int)?
        for w in windows {
            guard let f = Self.frame(of: w) else { continue }
            let err = abs(f.minX - frame.minX) + abs(f.minY - frame.minY) + abs(f.width - frame.width) + abs(f.height - frame.height)
            guard err <= 4 else { continue }
            let t = copyString(w, kAXTitleAttribute) ?? ""
            let score = (t == title ? 0 : 1) * 100 + Int(err)
            if best == nil || score < best!.2 { best = (w, f, score) }
        }
        guard let (el, f, _) = best else { return nil }
        return WindowHider(element: el, origin: f.origin, size: f.size)
    }

    /// Parks the window in the corner of the display it's on. Returns true
    /// when it really ended up (mostly) off-screen.
    @discardableResult
    func hide() -> Bool {
        let displays = EdgeController.displayBounds()
        let here = displays.first { $0.intersects(CGRect(origin: originalOrigin, size: size)) } ?? displays.first ?? .zero
        _ = setPosition(CGPoint(x: here.maxX - 1, y: here.maxY - 1))
        let now = Self.frame(of: element) ?? CGRect(origin: originalOrigin, size: size)
        hidden = InputInjector.isMostlyOffscreen(now)
        if !hidden {
            _ = setPosition(originalOrigin)
            clog("HANDOFF: app refused to park the window off-screen — streaming it in place")
        }
        return hidden
    }

    func restore() {
        guard hidden else { return }
        _ = setPosition(originalOrigin)
        hidden = false
    }

    /// Top-left origin, global points.
    @discardableResult
    func setPosition(_ p: CGPoint) -> Bool {
        var point = p
        guard let v = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, v) == .success
    }

    /// Brings the window's app forward and raises the window (after a return).
    func raise(pid: pid_t) {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    static func frame(of w: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &s) == .success,
              let pv = p, let sv = s, CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &origin), AXValueGetValue(sv as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func copyString(_ e: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success ? v as? String : nil
    }
}
