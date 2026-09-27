import AppKit

// What, if anything, the left button is carrying when the cursor reaches the
// peer edge: dragged files (Finder or any app that puts file URLs on the
// drag pasteboard), a window being moved by its title bar, or one of our own
// ReceiverWindows being dragged home. Used by EdgeController (the physical
// mouse on this Mac) and RemoteInputSink (a peer's injected mouse on this
// Mac) — both record the press and ask at the crossing.
//
// Public APIs only: the global drag pasteboard (NSPasteboard(name: .drag),
// whose changeCount bumps when a drag session starts) and the window list
// (CGWindowListCopyWindowInfo) — "a window is being dragged" = the window
// under the press has since moved. No Accessibility needed to *detect*.

enum Carry {
    case files([URL])
    /// A real window of another app. `grab` = where the cursor holds it,
    /// 0...1 within the window's frame.
    case window(id: CGWindowID, pid: pid_t, frame: CGRect, title: String, app: String, grab: CGPoint)
    /// One of our ReceiverWindows (identified by the source's window id).
    case receiver(sourceWindowId: UInt32)
}

final class CarryDetector {
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    private var pressed: (id: CGWindowID, pid: pid_t, frame: CGRect, title: String, app: String, at: CGPoint)?
    /// Maps one of our own window numbers to the source window id it shows.
    var receiverLookup: (CGWindowID) -> UInt32? = { _ in nil }
    /// Frame of the window under the last press, before the drag moved it
    /// (a handed-off window goes back there on a plain return).
    private(set) var pressedFrame: CGRect?

    /// Call on every left-button press (before it's delivered). Main thread.
    func mouseDown(at p: CGPoint) {
        dragChangeCount = NSPasteboard(name: .drag).changeCount
        pressed = Self.window(at: p).map { ($0.id, $0.pid, $0.frame, $0.title, $0.app, p) }
        pressedFrame = pressed?.frame
    }

    func mouseUp() { pressed = nil }

    /// Called at the edge while the left button is still down.
    func evaluate(at p: CGPoint) -> Carry? {
        let pb = NSPasteboard(name: .drag)
        if pb.changeCount != dragChangeCount,
           let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return .files(urls)
        }
        guard let w = pressed, let now = Self.frame(of: w.id),
              abs(now.minX - w.frame.minX) > 2 || abs(now.minY - w.frame.minY) > 2 else { return nil }
        if let src = receiverLookup(w.id) { return .receiver(sourceWindowId: src) }
        let grab = CGPoint(x: (w.at.x - w.frame.minX) / max(w.frame.width, 1),
                           y: (w.at.y - w.frame.minY) / max(w.frame.height, 1))
        return .window(id: w.id, pid: w.pid, frame: now, title: w.title, app: w.app,
                       grab: CGPoint(x: min(max(grab.x, 0), 1), y: min(max(grab.y, 0), 1)))
    }

    /// Frontmost normal-layer window containing `p` (global, top-left).
    static func window(at p: CGPoint) -> (id: CGWindowID, pid: pid_t, frame: CGRect, title: String, app: String)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? Int,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary),
                  r.contains(p) else { continue }
            return (CGWindowID(id), pid_t(pid), r,
                    info[kCGWindowName as String] as? String ?? "",
                    info[kCGWindowOwnerName as String] as? String ?? "")
        }
        return nil
    }

    static func frame(of id: CGWindowID) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first,
              let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        return CGRect(dictionaryRepresentation: b as CFDictionary)
    }

    /// Ends a drag this Mac is still running locally after the cursor went
    /// to the peer: Escape cancels a file drag (so nothing is dropped at the
    /// frozen edge position), then the button is released so the window
    /// server's button state matches reality. Tagged as injected.
    static func cancelLocalDrag(files: Bool, at p: CGPoint) {
        let src = InputInjector.source
        if files {
            CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: false)?.post(tap: .cghidEventTap)
        }
        let delay = files ? 0.05 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p,
                    mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }
}
