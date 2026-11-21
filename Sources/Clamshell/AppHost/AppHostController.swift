import AppKit
import DeskHost

/// Owns the app-host service when the setting is on. Everything runs on the main queue.
///
/// Not done yet: the listener on the control port. A connection must come through the same device
/// authentication and encrypted envelope as a stream connection before it reaches `attach`, and that
/// accept path is not wired. Until it is, turning the setting on only builds the service and polls nothing.
final class AppHostController {
    static let shared = AppHostController()

    private var service: AppHostService?
    private var timer: DispatchSourceTimer?
    private let input = MacInputDelivery()

    /// Called once at launch. Does nothing unless the setting is on.
    func startIfEnabled() {
        guard AppHostSettings.enabled, service == nil else { return }
        var config = HostConfig()
        config.routePreference = Self.routePreference(AppHostSettings.routePreference)
        config.log = { clog("APPHOST: \($0)") }
        service = AppHostService(
            dependencies: HostDependencies(launcher: MacAppLauncher(), windows: MacWindowSource(),
                                           streamer: MacWindowStreamer(), resizer: MacWindowResizer(), input: input),
            config: config)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.5, repeating: 0.25)
        t.setEventHandler { [weak self] in self?.service?.pollWindows() }
        t.resume()
        timer = t
        clog("APPHOST: app-host mode is on")
    }

    func stop() {
        timer?.cancel(); timer = nil
        service = nil
    }

    /// Hand over a connection that has already passed authentication. `peerCapabilities` is the capability
    /// word the operator sent in its hello.
    @discardableResult
    func attach(operatorId: String, connection: ControlConnection, peerCapabilities: UInt32) -> OperatorConnection? {
        service?.accept(operatorId: operatorId, connection: connection, peerCapabilities: peerCapabilities)
    }

    static func routePreference(_ name: String) -> RoutePreference {
        switch name {
        case "virtualDisplay": return .prefer(.virtualDisplayGlobal)
        case "perProcess": return .prefer(.perProcessEvent)
        case "accessibility": return .prefer(.accessibility)
        default: return .auto
        }
    }
}
