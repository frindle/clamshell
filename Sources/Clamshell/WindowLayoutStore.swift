import AppKit
import ApplicationServices

/// Snapshots and restores window positions across displays via the
/// Accessibility API. Used around a collapse so that un-mirroring puts
/// every window back where it lived on the physical monitors.
final class WindowLayoutStore {
    struct SavedWindow {
        let pid: pid_t
        let appName: String
        let index: Int      // index within the app's AXWindows array
        let title: String   // best-effort identity check alongside index
        let frame: CGRect
    }

    private(set) var saved: [SavedWindow] = []

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Prompts the user for Accessibility permission if not yet granted.
    static func requestAccessibilityPermission() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    func snapshot() {
        saved = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let pid = app.processIdentifier
            let axApp = AXUIElementCreateApplication(pid)
            guard let windows = copyAttribute(axApp, kAXWindowsAttribute) as? [AXUIElement] else { continue }
            for (i, win) in windows.enumerated() {
                guard let frame = frame(of: win) else { continue }
                let title = (copyAttribute(win, kAXTitleAttribute) as? String) ?? ""
                saved.append(SavedWindow(
                    pid: pid,
                    appName: app.localizedName ?? "?",
                    index: i,
                    title: title,
                    frame: frame
                ))
            }
        }
        clog("snapshot: \(saved.count) windows across \(Set(saved.map(\.pid)).count) apps")
    }

    func restore() {
        var restored = 0
        for w in saved {
            let axApp = AXUIElementCreateApplication(w.pid)
            guard let windows = copyAttribute(axApp, kAXWindowsAttribute) as? [AXUIElement] else { continue }
            // Prefer identity by title; fall back to positional index.
            var target: AXUIElement?
            if !w.title.isEmpty {
                target = windows.first { (copyAttribute($0, kAXTitleAttribute) as? String) == w.title }
            }
            if target == nil, w.index < windows.count {
                target = windows[w.index]
            }
            guard let win = target else { continue }
            if setFrame(of: win, to: w.frame) { restored += 1 }
        }
        clog("restore: \(restored)/\(saved.count) windows restored")
    }

    // MARK: - AX plumbing

    private func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return err == .success ? value : nil
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        guard let posValue = copyAttribute(window, kAXPositionAttribute),
              let sizeValue = copyAttribute(window, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    @discardableResult
    private func setFrame(of window: AXUIElement, to frame: CGRect) -> Bool {
        var origin = frame.origin
        var size = frame.size
        guard let posValue = AXValueCreate(.cgPoint, &origin),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return false }
        let posErr = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        let sizeErr = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        return posErr == .success && sizeErr == .success
    }
}
