import AppKit
import AXPrivateShim
import Darwin
import DeskHost

/// Window lists from the Window Server (front to back), with accessibility roles added where the
/// accessibility tree will say. Where it will not, the level alone classifies the window.
final class MacWindowSource: WindowSource {
    func windows(pid: Int32) -> [HostWindowSnapshot] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let roles = AXWindowLookup.roles(pid: pid)
        var out: [HostWindowSnapshot] = []
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
                  let number = info[kCGWindowNumber as String] as? UInt32,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  rect.width > 0, rect.height > 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
            let level = info[kCGWindowLayer as String] as? Int ?? 0
            let ax = roles[number]
            out.append(HostWindowSnapshot(
                windowId: number,
                title: info[kCGWindowName as String] as? String ?? "",
                role: ax?.role, subrole: ax?.subrole, level: level,
                x: Float(rect.origin.x), y: Float(rect.origin.y), width: Float(rect.width), height: Float(rect.height),
                scale: Self.scale(for: rect), parentHint: ax?.parent ?? 0))
        }
        return out
    }

    func isRunning(pid: Int32) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return !app.isTerminated
    }

    func residentMB(pid: Int32) -> UInt32 {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return 0 }
        return UInt32(clamping: info.pti_resident_size / (1024 * 1024))
    }

    /// Backing scale of the display that holds most of the rectangle: pixels over points of its current mode.
    static func scale(for rect: CGRect) -> Float {
        var ids = [CGDirectDisplayID](repeating: 0, count: 4)
        var n: UInt32 = 0
        guard CGGetDisplaysWithRect(rect, 4, &ids, &n) == .success, n > 0,
              let mode = CGDisplayCopyDisplayMode(ids[0]), mode.width > 0 else { return 2 }
        let s = Float(mode.pixelWidth) / Float(mode.width)
        return s >= 0.1 && s <= 16 ? s : 2
    }
}

/// Accessibility lookups for one app's windows. Everything here may come back empty: the permission
/// may be missing, and the private window-id call fails on some systems.
enum AXWindowLookup {
    struct Facts {
        var role: String?
        var subrole: String?
        var parent: UInt32?
    }

    static func roles(pid: Int32) -> [UInt32: Facts] {
        guard AXIsProcessTrusted() else { return [:] }
        var out: [UInt32: Facts] = [:]
        for el in windows(pid: pid) {
            guard let id = windowID(el) else { continue }
            out[id] = Facts(role: string(el, kAXRoleAttribute), subrole: string(el, kAXSubroleAttribute), parent: nil)
            // A sheet is a child of its window, not a window in the app's list.
            for child in children(el) where string(child, kAXRoleAttribute) == "AXSheet" {
                if let cid = windowID(child) { out[cid] = Facts(role: "AXSheet", subrole: nil, parent: id) }
            }
        }
        return out
    }

    static func windows(pid: Int32) -> [AXUIElement] {
        var ref: CFTypeRef?
        let app = AXUIElementCreateApplication(pid)
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success else { return [] }
        return ref as? [AXUIElement] ?? []
    }

    static func element(pid: Int32, windowId: UInt32) -> AXUIElement? {
        windows(pid: pid).first { windowID($0) == windowId }
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ref) == .success else { return [] }
        return ref as? [AXUIElement] ?? []
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func windowID(_ el: AXUIElement) -> UInt32? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(el, &id) == .success && id != 0 ? id : nil
    }
}

/// Asks an app to resize a window through accessibility. The app may refuse or round.
final class MacWindowResizer: WindowResizer {
    func resize(windowId: UInt32, pid: Int32, width: Float, height: Float) {
        guard AXIsProcessTrusted(), let el = AXWindowLookup.element(pid: pid, windowId: windowId) else { return }
        var size = CGSize(width: CGFloat(width), height: CGFloat(height))
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, value)
    }
}
