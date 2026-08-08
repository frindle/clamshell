import AppKit
import AXPrivateShim
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
// STATUS as of 2026-08-08, live-tested, NEITHER approach works yet:
//
// 1. Matching an SCWindow to its AXUIElement by title (the "official",
//    documented approach) does NOT work reliably -- confirmed against both
//    Terminal and Finder: kAXWindowsAttribute's array didn't contain an
//    element matching either the target window's real title or its real
//    frame.
// 2. `_AXUIElementGetWindow` (AXPrivateShim) -- the private, undocumented
//    ApplicationServices function real window-management tools (Rectangle,
//    yabai, Hammerspoon) rely on for this exact CGWindowID<->AXUIElement
//    mapping problem -- ALSO fails: returns AXError -25201 (illegal
//    argument) for every AX window tried, against both apps, despite a
//    standard-looking call (valid non-null AXUIElement from a successful
//    kAXWindowsAttribute read, non-null out-pointer). The shim itself
//    compiles/links correctly and the call executes without crashing --
//    this is a genuine behavioral rejection by the system implementation,
//    not a declaration/linking bug.
//
// Both are real dead ends investigated live, not guesses. Not yet isolated:
// whether this Mac's specific macOS version changed `_AXUIElementGetWindow`'s
// behavior/requirements, or whether an ad-hoc-signed bare CLI binary (not
// the real signed Clamshell.app bundle) gets systematically different AX
// treatment than what AXIsProcessTrusted()==true implies -- that would
// explain BOTH failures at once. Needs either a reference implementation to
// diff the exact call convention against, or testing from inside the real
// signed .app bundle, before spending more time guessing at this private
// API's undocumented contract. Left in place (not reverted) as the current
// best attempt and a clear record of what's been tried.
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

        // SCWindow doesn't expose an AXUIElement directly, and matching by
        // title/frame against kAXWindowsAttribute doesn't work reliably (see
        // header comment) -- instead, walk the app's AX windows and ask each
        // one its REAL CGWindowID via the private _AXUIElementGetWindow, then
        // compare that directly against target.windowID. No title/frame
        // guessing involved.
        let axApp = AXUIElementCreateApplication(owningApp.processID)
        var axWindowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &axWindowsRef) == .success,
              let axWindows = axWindowsRef as? [AXUIElement] else {
            print("FAILED: could not read \(owningApp.applicationName)'s AX windows (permission granted but app may not expose AX windows)")
            return 1
        }
        var axWindow: AXUIElement?
        for w in axWindows {
            var wid: CGWindowID = 0
            let err = _AXUIElementGetWindow(w, &wid)
            print("  AX candidate: _AXUIElementGetWindow -> id=\(wid) err=\(err.rawValue)")
            if err == .success, wid == target.windowID { axWindow = w; break }
        }
        guard let axWindow else {
            print("FAILED: no AX window's real CGWindowID matched target \(target.windowID) in \(owningApp.applicationName)")
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
