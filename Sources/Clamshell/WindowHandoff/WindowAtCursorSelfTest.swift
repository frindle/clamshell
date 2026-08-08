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
// and the private _AXUIElementGetWindow) showing the same shape of failure:
// the call succeeds and returns *something*, but not the correct real answer.
//
// UPDATE, same night: the leading theory at that point ("this ad-hoc-signed
// bare CLI binary's AX trust level") is now DISPROVEN, not just unverified.
// Cross-checked with `osascript`/System Events -- a fully-trusted, always-
// signed Apple system component, not this binary at all:
//   osascript -e 'tell application "System Events" to tell process "Terminal" to count windows'
// returned **0** (Terminal genuinely has one real, visible, frontmost window
// at the time). Same 0-windows result for Finder AND Google Chrome -- every
// app tested, not Terminal-specific. `get properties of process "Terminal"`
// (the actual frontmost, focused, visible=true process) reports
// `position:missing value, size:missing value, focused:missing value` even
// at the AXApplication level. This is a genuine, system-wide Accessibility
// reporting problem on this Mac RIGHT NOW, independent of which binary or
// which app is asking.
//
// Ruled out as the cause: (1) headless/virtual-display state -- both
// `system_profiler SPDisplaysDataType` displays (built-in + an external
// Odyssey G95C ultrawide) report Online:Yes, this is NOT a lid-closed/
// Clamshell-collapsed Mac despite Clamshell.app running in the background;
// (2) an active remote Clamshell session interfering -- `clamshell
// test-detect` reports none, no established connections on its ports.
// Reading TCC.db directly to check the actual Accessibility grant list was
// attempted and correctly refused (SIP-protected, needs Full Disk Access) --
// appropriate OS behavior, not something to work around.
//
// Not yet tried, needs the user (state-changing, not something to do
// silently): rebooting/restarting the Accessibility-related daemons, or
// simply checking System Settings > Privacy & Security > Accessibility's
// actual toggle state directly instead of inferring it from AXIsProcessTrusted().
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
