import Foundation
import UserNotifications

// The host's own switches for what a connected device may bring along: files
// (PROTOCOL.md "File transfer") and peripherals ("Peripherals attached to the
// client"). Both are on unless the user turns them off in the menu bar app.
// Stored in the app's preferences like its other settings.

enum HostDeviceSettings {
    static let filesKey = "receiveFilesEnabled"
    static let peripheralsKey = "peripheralsEnabled"

    /// Posted (on the thread that changed it) when `peripheralsEnabled` changes.
    static let peripheralsDidChange = Notification.Name("com.frindle.clamshell.peripheralsEnabledChanged")

    private static func flag(_ key: String) -> Bool {
        (UserDefaults.standard.object(forKey: key) as? Bool) ?? true
    }

    /// False: every file offer is answered with status 4.
    static var filesEnabled: Bool {
        get { flag(filesKey) }
        set { UserDefaults.standard.set(newValue, forKey: filesKey) }
    }

    /// False: every peripheral attach is answered with status 4, and the ones
    /// attached are removed with status 4.
    static var peripheralsEnabled: Bool {
        get { flag(peripheralsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: peripheralsKey)
            NotificationCenter.default.post(name: HostDeviceSettings.peripheralsDidChange, object: nil)
        }
    }
}

/// A short notice for the user when something arrives. A notification needs
/// an app bundle; the bare binary has none, and then the log line is all
/// there is.
enum HostNotice {
    private static let canNotify = Bundle.main.bundleIdentifier != nil

    static func post(title: String, body: String) {
        clog("NOTICE: \(title): \(body)")
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.interruptionLevel = .passive
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { clog("NOTICE: could not post a notification (\(error))") }
        }
    }
}
