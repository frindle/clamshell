/// The three ways to get input to a window that may not be frontmost on the host (execution plan 3.1,
/// "Input to background windows"). Experiment E3 picks between them on real hardware.
public enum InputRoute: Equatable {
    /// Route 1: the app is frontmost on its own virtual display; post global events with the pointer warped.
    case virtualDisplayGlobal
    /// Route 2: the private per-process event call.
    case perProcessEvent
    /// Route 3: accessibility actions. Clicks and menu picks only.
    case accessibility
}

/// Which route E3 chose. `auto` tries them in plan order.
public enum RoutePreference: Equatable {
    case auto
    case prefer(InputRoute)
}

public enum InputEventKind: Equatable {
    case pointerMove, pointerButton, key, scroll
    /// A menu item chosen by the operator. Not on the wire yet (MENU_INVOKE is for the menu bridge).
    case menuPick
}

/// What the host can do for one window at one moment.
public struct InputCapabilities: Equatable {
    /// The window sits on a hosted virtual display and its app is frontmost there.
    public var frontmostOnHostedDisplay: Bool
    /// The private per-process call is present on this macOS version.
    public var perProcessEventAvailable: Bool
    /// The accessibility permission is granted.
    public var accessibilityTrusted: Bool
    public init(frontmostOnHostedDisplay: Bool, perProcessEventAvailable: Bool, accessibilityTrusted: Bool) {
        self.frontmostOnHostedDisplay = frontmostOnHostedDisplay
        self.perProcessEventAvailable = perProcessEventAvailable
        self.accessibilityTrusted = accessibilityTrusted
    }
}

public enum InputRouter {
    /// The routes to try, in order, for one event. The caller tries the first, and the next only if delivery failed.
    /// Empty means no route can carry this event now, and the event is dropped.
    /// A route is only listed if it can work: route 1 needs the window frontmost on a hosted display, route 2 needs
    /// the private call, route 3 needs the accessibility permission and an event that is a click or a menu pick.
    public static func candidates(event: InputEventKind, capabilities c: InputCapabilities,
                                  preference: RoutePreference = .auto) -> [InputRoute] {
        var viable: [InputRoute] = []
        if c.frontmostOnHostedDisplay { viable.append(.virtualDisplayGlobal) }
        if c.perProcessEventAvailable { viable.append(.perProcessEvent) }
        if c.accessibilityTrusted, event == .pointerButton || event == .menuPick { viable.append(.accessibility) }
        if case .prefer(let first) = preference, let i = viable.firstIndex(of: first) {
            viable.remove(at: i)
            viable.insert(first, at: 0)
        }
        return viable
    }
}
