import AppKit
import DeskHost

/// Input to hosted windows. Which routes work here is a first guess until experiment E3 runs on two Macs:
///  - route 1 (global events, pointer warped) is offered when the window's app is frontmost on the host,
///    using the existing window-mapped `InputInjector`. The per-app virtual display of the full plan is not built yet.
///  - route 2 (private per-process call) is not offered.
///  - route 3 (accessibility press) is offered for clicks when the accessibility permission is granted.
final class MacInputDelivery: InputDelivery {
    private var injectors: [UInt32: InputInjector] = [:]

    func capabilities(windowId: UInt32, pid: Int32) -> InputCapabilities {
        InputCapabilities(
            frontmostOnHostedDisplay: NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
            perProcessEventAvailable: false,
            accessibilityTrusted: AXIsProcessTrusted())
    }

    func deliver(_ event: HostInputEvent, windowId: UInt32, pid: Int32, route: InputRoute) -> Bool {
        switch route {
        case .virtualDisplayGlobal:
            let injector = injectors[windowId] ?? InputInjector(windowID: windowId)
            injectors[windowId] = injector
            switch event {
            case .mouseMove(let x, let y): injector.mouseMove(x: x, y: y)
            case .mouseButton(let b, let down, let x, let y): injector.mouseButton(button: b, down: down, x: x, y: y)
            case .key(let code, let down, let flags): injector.key(macKeyCode: code, down: down, flags: flags)
            case .scroll(let dx, let dy): injector.scroll(dx: dx, dy: dy)
            }
            return true
        case .perProcessEvent:
            return false
        case .accessibility:
            guard case .mouseButton(_, let down, let x, let y) = event else { return false }
            return down ? pressElement(windowId: windowId, pid: pid, x: x, y: y) : true
        }
    }

    /// Forget a window's injector (it released its held keys and buttons first).
    func windowClosed(_ windowId: UInt32) {
        injectors.removeValue(forKey: windowId)?.releaseAll()
    }

    private func pressElement(windowId: UInt32, pid: Int32, x: Float, y: Float) -> Bool {
        guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(windowId)) as? [[String: Any]])?.first,
              let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
              let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { return false }
        let px = Float(rect.origin.x) + x * Float(rect.width)
        let py = Float(rect.origin.y) + y * Float(rect.height)
        var element: AXUIElement?
        let app = AXUIElementCreateApplication(pid)
        guard AXUIElementCopyElementAtPosition(app, px, py, &element) == .success, let hit = element else { return false }
        return AXUIElementPerformAction(hit, kAXPressAction as CFString) == .success
    }
}
