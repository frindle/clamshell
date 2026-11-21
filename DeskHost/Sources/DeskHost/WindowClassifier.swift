import DeskProtocol

/// Window levels as macOS reports them (CGWindowLevelForKey). Only the ones the classifier looks at.
public enum HostWindowLevel {
    public static let normal = 0
    public static let floating = 3
    public static let modalPanel = 8
    public static let mainMenu = 24
    public static let status = 25
    public static let popUpMenu = 101
    public static let help = 200
    public static let dragging = 500
}

/// Decides what kind of window something is, from its accessibility role, its subrole and its window level.
/// A pure function: the same facts always give the same answer. The role wins when there is one. The level
/// is the fallback for windows the accessibility tree does not list (menus and tooltips often are not).
public enum WindowClassifier {
    public static func classify(role: String?, subrole: String?, level: Int) -> WindowKind {
        guard let role = role else { return fromLevel(level) }
        switch role {
        case "AXSheet": return .sheet
        case "AXPopover": return .popover
        case "AXMenu", "AXMenuItem", "AXMenuBar", "AXMenuBarItem": return .menu
        case "AXHelpTag": return .tooltip
        case "AXWindow":
            switch subrole ?? "" {
            case "AXStandardWindow", "AXDialog", "AXFloatingWindow": return .main
            case "AXSystemDialog": return level <= HostWindowLevel.modalPanel ? .main : .other
            case "AXSystemFloatingWindow": return .other
            default: break
            }
            // Role says window, subrole says nothing useful: let the level decide.
            let byLevel = fromLevel(level)
            return byLevel == .other && level < HostWindowLevel.mainMenu ? .main : byLevel
        default:
            return .other
        }
    }

    /// Level only. Ordinary levels give `.other`: with no role there is nothing to call a main window.
    static func fromLevel(_ level: Int) -> WindowKind {
        if level >= HostWindowLevel.dragging { return .other }
        if level >= HostWindowLevel.help { return .tooltip }
        if level >= HostWindowLevel.popUpMenu { return .menu }
        return .other
    }

    /// Kinds that sit on a parent window and are positioned relative to it.
    public static func isChildKind(_ kind: WindowKind) -> Bool {
        switch kind {
        case .sheet, .popover, .menu, .tooltip: return true
        case .main, .other: return false
        }
    }
}
