import AppKit
@preconcurrency import ScreenCaptureKit

// `clamshell window-hide-selftest [windowId]` — third slice of Window Handoff.
// Proves the actual hiding mechanism PROTOCOL.md specifies: capture requires
// a window not be MINIMIZED, so "hide the source window locally" has to mean
// moving it far off-screen instead -- this test moves a real window off-screen
// via the Accessibility API, confirms window-capture-selftest's capture path
// still receives real frames while it's off-screen, then restores the
// window's original position. Needs Accessibility permission (separate from
// window-list/window-capture-selftest's Screen Recording permission).
//
// KNOWN LIMITATION, confirmed live 2026-08-08, not yet fixed: matching an
// SCWindow to its AXUIElement by title (the "official", documented approach)
// does not work reliably. Tested against both Terminal and Finder via this
// binary (Accessibility permission genuinely granted, AXIsProcessTrusted()
// true, AXUIElementCopyAttributeValue calls return .success) --
// kAXWindowsAttribute's array does not contain an element matching the
// target window's real title OR its real frame. Finder's two "windows" were
// a zero-size stub and what looks like a full-desktop-bounds phantom element
// -- neither is the actual 920x436 "Applications" window SCShareableContent
// correctly reports. Root cause not yet isolated: possibly a genuine AX
// quirk for these specific apps, possibly degraded AX tree fidelity for an
// ad-hoc-signed bare CLI binary (untested: whether this behaves differently
// from inside the real signed Clamshell.app bundle).
//
// The robust fix used by real window-management tools (Rectangle, yabai,
// Hammerspoon) for exactly this CGWindowID<->AXUIElement mapping problem is
// `_AXUIElementGetWindow` -- a private, undocumented ApplicationServices
// function, not part of the public AX API. That's a deliberate tradeoff to
// make explicitly (private APIs can break across macOS updates without
// notice), not something to reach for silently. Left unimplemented here
// until that decision is made on purpose.
enum WindowHideSelfTest {
    static func run(windowId: UInt32?) async -> Int32 {
        guard AXIsProcessTrusted() else {
            print("FAILED: Accessibility permission not granted. Grant it in System Settings > Privacy & Security > Accessibility, then quit & reopen (or re-run from a fresh shell).")
            return 1
        }
        if !CGPreflightScreenCaptureAccess() {
            print("FAILED: Screen Recording permission not granted.")
            return 1
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            print("FAILED: could not list shareable content: \(error)")
            return 1
        }
        let selfPid = ProcessInfo.processInfo.processIdentifier
        let candidates = content.windows.filter { w in
            guard let title = w.title, !title.isEmpty else { return false }
            guard let app = w.owningApplication, app.processID != selfPid else { return false }
            return w.frame.width >= 100 && w.frame.height >= 100
        }
        guard let target = (windowId.map { id in candidates.first(where: { $0.windowID == id }) } ?? candidates.first) ?? nil else {
            print("FAILED: no matching capturable window" + (windowId.map { " (id \($0))" } ?? ""))
            return 1
        }
        guard let owningApp = target.owningApplication, let title = target.title else {
            print("FAILED: target window missing owning app or title")
            return 1
        }
        print("Target: \(owningApp.applicationName) — \(title) (pid \(owningApp.processID))")

        // SCWindow doesn't expose an AXUIElement directly -- get the app's AX
        // element from its pid, then match the specific window by title
        // against kAXWindowsAttribute. Title match is good enough here (a
        // real handoff would also cross-check frame size); multiple
        // same-titled windows on the same app is a known edge case, not
        // handled by this self-test.
        let axApp = AXUIElementCreateApplication(owningApp.processID)
        var axWindowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &axWindowsRef) == .success,
              let axWindows = axWindowsRef as? [AXUIElement] else {
            print("FAILED: could not read \(owningApp.applicationName)'s AX windows (permission granted but app may not expose AX windows)")
            return 1
        }
        var axWindow: AXUIElement?
        for w in axWindows {
            var titleRef: CFTypeRef?
            let titleErr = AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &titleRef)
            let axTitle = titleRef as? String
            var posRef: CFTypeRef?, sizeRef: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posRef)
            AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeRef)
            var pos = CGPoint.zero, size = CGSize.zero
            if let p = posRef { _ = AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
            if let s = sizeRef { _ = AXValueGetValue(s as! AXValue, .cgSize, &size) }
            print("  AX candidate: title=\(axTitle.map { "\"\($0)\"" } ?? "nil") err=\(titleErr.rawValue) frame=\(pos) \(size)")
            if titleErr == .success, axTitle == title { axWindow = w; break }
        }
        guard let axWindow else {
            print("FAILED: no AX window matched title \"\(title)\" in \(owningApp.applicationName)")
            return 1
        }

        // Save the real position so it can be restored -- a real handoff
        // needs this to bring the window back on HANDOFF_RETURN.
        guard let originalPos = readPosition(axWindow) else {
            print("FAILED: could not read window's current position")
            return 1
        }
        print("Original position: \(originalPos)")

        let offscreen = CGPoint(x: -5000, y: originalPos.y)
        guard setPosition(axWindow, offscreen) else {
            print("FAILED: could not move window off-screen")
            return 1
        }
        print("Moved to \(offscreen) — capturing while off-screen…")

        let captureResult = await WindowCaptureSelfTest.run(windowId: target.windowID)

        // Always restore, even on capture failure -- a self-test shouldn't
        // leave the user's real window stranded off-screen.
        let restored = setPosition(axWindow, originalPos)
        print(restored ? "Restored to \(originalPos)" : "WARNING: failed to restore original position — move \"\(title)\" back manually")

        if captureResult != 0 {
            print("FAILED: capture did not receive frames while window was off-screen")
            return 1
        }
        print("PASS: window hidden off-screen, captured, and restored")
        return 0
    }

    private static func readPosition(_ window: AXUIElement) -> CGPoint? {
        var posRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              let posValue = posRef, CFGetTypeID(posValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func setPosition(_ window: AXUIElement, _ point: CGPoint) -> Bool {
        var mutablePoint = point
        guard let value = AXValueCreate(.cgPoint, &mutablePoint) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
    }
}
