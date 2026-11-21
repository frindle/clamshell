import Foundation

/// App-host mode (Window Handoff v3, host side). Off unless this default is set:
///   defaults write <bundle id> appHostEnabled -bool true
/// With it off, nothing in this folder runs.
enum AppHostSettings {
    static let enabledKey = "appHostEnabled"
    static let routeKey = "appHostInputRoute"   // "auto" (default), "virtualDisplay", "perProcess", "accessibility"

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static var routePreference: String { UserDefaults.standard.string(forKey: routeKey) ?? "auto" }
}
