#if os(macOS)
import AppKit
import ApplicationServices
import DeskNotify

public enum DockAccessError: Error, Equatable {
    /// Accessibility is not granted to this process. This reader never shows the system prompt.
    case notTrusted
    case dockNotRunning
    case unreadable
}

/// Reads badge labels from the Dock through Accessibility (`AXStatusLabel` on each Dock item).
/// E7 measured 4 to 17 ms per read on macOS 27.
public struct DockAccessibilitySource: DockBadgeSource {
    public init() {}

    public func read() throws -> [DockBadge] {
        guard AXIsProcessTrusted() else { throw DockAccessError.notTrusted }
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            throw DockAccessError.dockNotRunning
        }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &kids) == .success,
              let lists = kids as? [AXUIElement] else { throw DockAccessError.unreadable }
        var out: [DockBadge] = []
        for list in lists {
            var sub: CFTypeRef?
            guard AXUIElementCopyAttributeValue(list, kAXChildrenAttribute as CFString, &sub) == .success,
                  let items = sub as? [AXUIElement] else { continue }
            for item in items {
                guard let label = string(item, "AXStatusLabel"), !label.isEmpty else { continue }
                let title = string(item, kAXTitleAttribute as String) ?? ""
                out.append(DockBadge(title: title, appPath: url(item)?.path, label: label))
            }
        }
        return out
    }

    private func string(_ e: AXUIElement, _ name: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private func url(_ e: AXUIElement) -> URL? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXURLAttribute as CFString, &v) == .success else { return nil }
        return v as? URL
    }
}

/// Finds the bundle id of a Dock item from its app path.
public struct DockBundleResolver: BundleResolver {
    public init() {}
    public func bundleId(for item: DockBadge) -> String? {
        guard let p = item.appPath else { return nil }
        return Bundle(path: p)?.bundleIdentifier
    }
}
#endif
