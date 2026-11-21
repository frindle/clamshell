import DeskProtocol

/// How a child window behaves as a native window.
public struct ChildBehavior: Equatable {
    /// Shift the window, never resize it, so it stays inside the visible screen. A sheet is not shifted: it
    /// belongs to its parent and goes where the parent goes.
    public var keepsOnScreen: Bool
    /// Whether the window may become the key window (take keyboard focus).
    public var becomesKey: Bool
    /// Clicks pass through to whatever is below (a tooltip).
    public var ignoresMouse: Bool

    public init(keepsOnScreen: Bool, becomesKey: Bool, ignoresMouse: Bool) {
        self.keepsOnScreen = keepsOnScreen; self.becomesKey = becomesKey; self.ignoresMouse = ignoresMouse
    }
}

/// Sheets, popovers, menus and tooltips are borderless child windows placed relative to their parent. They may
/// extend past the parent's edge, as they do natively.
public enum ChildPlacement {
    /// The deepest chain of parents followed when resolving a frame. A longer chain is a bug in the data.
    public static let maxDepth = 8

    public static func behavior(for kind: WindowKind) -> ChildBehavior {
        switch kind {
        case .sheet: return ChildBehavior(keepsOnScreen: false, becomesKey: true, ignoresMouse: false)
        case .popover: return ChildBehavior(keepsOnScreen: true, becomesKey: true, ignoresMouse: false)
        case .menu: return ChildBehavior(keepsOnScreen: true, becomesKey: false, ignoresMouse: false)
        case .tooltip: return ChildBehavior(keepsOnScreen: true, becomesKey: false, ignoresMouse: true)
        case .main: return ChildBehavior(keepsOnScreen: false, becomesKey: true, ignoresMouse: false)
        case .other: return ChildBehavior(keepsOnScreen: true, becomesKey: false, ignoresMouse: false)
        }
    }

    /// The child's frame in operator screen points (y down), given its parent's frame on the screen.
    /// The parent may be stretched (its operator size differs from its host size); the child is scaled by the
    /// same ratios, so a sheet stays where it belongs while the host catches up with a resize.
    public static func frame(of child: RemoteWindow, parent: RemoteWindow, parentFrame: DeskRect, screen: DeskRect?) -> DeskRect {
        let pw = Double(parent.geometry.width), ph = Double(parent.geometry.height)
        let rx = pw > 0 ? parentFrame.size.width / pw : 1
        let ry = ph > 0 ? parentFrame.size.height / ph : 1
        let offset = child.childOffset ?? DeskPoint(x: 0, y: 0)
        var r = DeskRect(x: parentFrame.origin.x + offset.x * rx,
                         y: parentFrame.origin.y + offset.y * ry,
                         width: Double(child.geometry.width) * rx,
                         height: Double(child.geometry.height) * ry)
        if let s = screen, behavior(for: child.kind).keepsOnScreen { r = shifted(r, into: s) }
        return r
    }

    /// Resolves a child through its chain of parents (a submenu hangs from a menu, which hangs from a window).
    /// `windows` finds a window by local id; `topLevelFrame` gives the operator frame of a top-level window.
    /// Nil when the chain is broken, loops, or its top has no frame.
    public static func resolve(_ child: RemoteWindow, windows: (UInt64) -> RemoteWindow?,
                               topLevelFrame: (UInt64) -> DeskRect?, screen: DeskRect?) -> DeskRect? {
        resolve(child, windows: windows, topLevelFrame: topLevelFrame, screen: screen, depth: 0)
    }

    private static func resolve(_ child: RemoteWindow, windows: (UInt64) -> RemoteWindow?,
                                topLevelFrame: (UInt64) -> DeskRect?, screen: DeskRect?, depth: Int) -> DeskRect? {
        guard depth < maxDepth, let pid = child.parentLocalId, let parent = windows(pid) else { return nil }
        let parentFrame: DeskRect?
        if parent.parentLocalId != nil {
            // The parent is shifted onto the screen the same way, so a submenu follows its menu.
            parentFrame = resolve(parent, windows: windows, topLevelFrame: topLevelFrame, screen: screen, depth: depth + 1)
        } else {
            parentFrame = topLevelFrame(parent.localId)
        }
        guard let pf = parentFrame else { return nil }
        return frame(of: child, parent: parent, parentFrame: pf, screen: screen)
    }

    /// Moves `r` the least distance that puts it inside `screen`. A side longer than the screen is aligned to the
    /// screen's top or left edge.
    public static func shifted(_ r: DeskRect, into screen: DeskRect) -> DeskRect {
        var out = r
        if out.size.width >= screen.size.width || out.minX < screen.minX {
            out.origin.x = screen.minX
        } else if out.maxX > screen.maxX {
            out.origin.x = screen.maxX - out.size.width
        }
        if out.size.height >= screen.size.height || out.minY < screen.minY {
            out.origin.y = screen.minY
        } else if out.maxY > screen.maxY {
            out.origin.y = screen.maxY - out.size.height
        }
        return out
    }
}
