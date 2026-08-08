import AppKit
@preconcurrency import ScreenCaptureKit

// First slice of the Window Handoff feature (see PROTOCOL.md "Window Handoff
// (v2, PROPOSED)"): prove window-level enumeration/capture works on this Mac
// before building the full capture->encode->stream->receiver pipeline. Mirrors
// StreamServer's SCShareableContent usage (same permission-check pattern) but
// lists windows instead of starting a capture session.
enum WindowList {
    struct Entry {
        let windowId: UInt32
        let title: String
        let appName: String
        let width: Int
        let height: Int
    }

    /// Every capturable, on-screen, titled window not owned by this process
    /// itself and not a system UI surface (menu bar, dock, wallpaper) --
    /// those show up in SCShareableContent but would never make sense as a
    /// handoff target.
    static func listCapturable() async throws -> [Entry] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let selfPid = ProcessInfo.processInfo.processIdentifier
        return content.windows.compactMap { w -> Entry? in
            guard let title = w.title, !title.isEmpty else { return nil }
            guard let app = w.owningApplication, app.processID != selfPid else { return nil }
            guard w.frame.width >= 100, w.frame.height >= 100 else { return nil } // filter out tooltips/menus
            return Entry(
                windowId: w.windowID,
                title: title,
                appName: app.applicationName,
                width: Int(w.frame.width),
                height: Int(w.frame.height)
            )
        }
    }

    /// `clamshell window-list` CLI entry point.
    static func run() async -> Int32 {
        if !CGPreflightScreenCaptureAccess() {
            print("FAILED: Screen Recording permission not granted. Grant it in System Settings > Privacy & Security > Screen Recording.")
            return 1
        }
        do {
            let entries = try await listCapturable()
            if entries.isEmpty {
                print("No capturable windows found.")
                return 0
            }
            for e in entries {
                print("\(e.windowId)\t\(e.appName)\t\(e.title)\t\(e.width)x\(e.height)")
            }
            return 0
        } catch {
            print("FAILED: \(error)")
            return 1
        }
    }
}
