import AppKit
import DeskHost

/// Starts apps, or finds the running copy, through NSWorkspace. Only web links and file paths are
/// accepted as targets; anything else is refused.
final class MacAppLauncher: AppLauncher {
    func launch(bundleId: String, activate: Bool, targets: [String], completion: @escaping (LaunchOutcome) -> Void) {
        let urls = targets.compactMap(Self.targetURL)
        guard urls.count == targets.count else { completion(.refused); return }

        if urls.isEmpty, let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            if activate { running.activate(options: []) }
            completion(.started(pid: running.processIdentifier, name: running.localizedName ?? bundleId))
            return
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            completion(.notInstalled)
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = activate
        let done: (NSRunningApplication?, Error?) -> Void = { app, error in
            DispatchQueue.main.async {
                if let app = app, error == nil {
                    completion(.started(pid: app.processIdentifier, name: app.localizedName ?? bundleId))
                } else {
                    clog("APPHOST: launch failed for an app")
                    completion(.failed)
                }
            }
        }
        if urls.isEmpty {
            NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: done)
        } else {
            NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: config, completionHandler: done)
        }
    }

    /// http, https, file URLs, or an absolute path. Nothing else.
    static func targetURL(_ s: String) -> URL? {
        if s.hasPrefix("/") { return URL(fileURLWithPath: s) }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased() else { return nil }
        return ["http", "https", "file"].contains(scheme) ? url : nil
    }
}
