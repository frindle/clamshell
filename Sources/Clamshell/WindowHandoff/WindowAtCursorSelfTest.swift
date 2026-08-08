import AppKit

// `clamshell window-at-cursor-selftest` — fourth slice of Window Handoff:
// proves the position->window lookup PROTOCOL.md's drag-trigger design
// depends on (identify which window is under the cursor at drag-start).
// Deliberately NOT the same operation as WindowHideSelfTest's failed
// CGWindowID<->AXUIElement matching: this hit-tests a screen coordinate
// directly via AXUIElementCopyElementAtPosition, no ID correlation at all.
// Passive/non-invasive -- reads the real current cursor position, posts no
// synthetic mouse events, moves nothing on screen.
//
// ALSO FAILS, and this result matters beyond just this technique: tested
// live 2026-08-08 at the cursor's real position AND (via CGWarpMouseCursorPosition,
// no click/drag) at Terminal's exact known on-screen center -- both times
// this returned "loginwindow" (pid 605), not the real window actually at
// that location. That's a THIRD independent AX technique (after title-match
// and the private _AXUIElementGetWindow) all showing the same shape of
// failure: the call succeeds and returns *something*, but not the correct
// real answer. Three different APIs failing the same way is a much stronger
// signal than any one of them alone -- it points at the common denominator
// (this ad-hoc-signed bare `.build/debug/Clamshell` binary's AX trust level)
// rather than at any individual technique being wrong. Testing from inside
// the real signed Clamshell.app bundle is the next step, deliberately not
// done yet tonight: it would mean either overwriting the live, currently-
// running production /Applications/Clamshell.app, or building to a new path
// that would need a fresh interactive permission grant -- both need the
// user, not something to do silently.
enum WindowAtCursorSelfTest {
    static func run() -> Int32 {
        guard AXIsProcessTrusted() else {
            print("FAILED: Accessibility permission not granted.")
            return 1
        }

        guard let loc = CGEvent(source: nil)?.location else {
            print("FAILED: could not read cursor position")
            return 1
        }
        print("Cursor at: \(loc)")

        // The system-wide element is the one AXUIElementCopyElementAtPosition
        // hit-tests against -- same pattern as CGEvent(source: nil)?.location
        // for reading global cursor position elsewhere in this codebase
        // (PROTOCOL.md "Cursor-follow auto-pan").
        let systemWide = AXUIElementCreateSystemWide()
        var hitRef: AXUIElement?
        // AXUIElementCopyElementAtPosition takes Float, not CGFloat/Double,
        // and top-left-origin global screen coordinates (same space as
        // CGEvent location) -- no coordinate flip needed.
        let err = AXUIElementCopyElementAtPosition(systemWide, Float(loc.x), Float(loc.y), &hitRef)
        guard err == .success, let hit = hitRef else {
            print("FAILED: AXUIElementCopyElementAtPosition returned err=\(err.rawValue)")
            return 1
        }

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(hit, kAXRoleAttribute as CFString, &roleRef)
        print("Hit element role: \(roleRef as? String ?? "nil")")

        // The hit-tested element is often a child control (a button, a text
        // view), not the window itself -- walk up kAXParentAttribute until
        // finding role == AXWindow, same technique real window-management
        // tools use to go from "whatever's under the cursor" to "its window".
        var current = hit
        var steps = 0
        while steps < 20 {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &role)
            if (role as? String) == kAXWindowRole {
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(current, kAXTitleAttribute as CFString, &titleRef)
                var pidRef: pid_t = 0
                AXUIElementGetPid(current, &pidRef)
                let appName = NSRunningApplication(processIdentifier: pidRef)?.localizedName ?? "?"
                print("PASS: found window \"\(titleRef as? String ?? "?")\" (\(appName), pid \(pidRef)) after \(steps) parent hop(s)")
                return 0
            }
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parent = parentRef else {
                break
            }
            current = parent as! AXUIElement
            steps += 1
        }
        print("FAILED: walked \(steps) parent hop(s) without finding an AXWindow-role ancestor")
        return 1
    }
}
