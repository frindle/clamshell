import Foundation

/// A saved login a client sends to a host that is at the login window
/// (LOGIN_CREDENTIALS, PROTOCOL.md "Login window"). The host types it into
/// the login window's name and password fields.
///
/// The password is only ever in a SECURE message, in memory, and in the
/// typing events that follow. It is never logged: nothing here prints it, and
/// `description` hides it.
struct LoginCredentials: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    static let version = 1
    static let kind = "login"
    static let maxPayloadBytes = 2048
    static let maxFieldBytes = 512

    let user: String
    let password: String

    var description: String { "LoginCredentials(user: \(user.isEmpty ? "empty" : "set"), password: hidden)" }
    var debugDescription: String { description }

    /// The wire payload: UTF-8 JSON `{"v":1,"kind":"login","user":...,"password":...}`.
    func encode() -> Data {
        let object: [String: Any] = ["v": Self.version, "kind": Self.kind, "user": user, "password": password]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// Nil unless the payload is exactly what a client may send: a known
    /// version and kind, a non-empty user and password, each within the size
    /// limit and free of control characters (a tab or line break would be
    /// typed as a key press and move the cursor).
    static func decode(_ payload: Data) -> LoginCredentials? {
        guard payload.count <= maxPayloadBytes,
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              object["v"] as? Int == version, object["kind"] as? String == kind,
              let user = object["user"] as? String, let password = object["password"] as? String,
              valid(user), valid(password) else { return nil }
        return LoginCredentials(user: user, password: password)
    }

    private static func valid(_ field: String) -> Bool {
        guard !field.isEmpty, field.utf8.count <= maxFieldBytes else { return false }
        return !field.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || (0x80 ..< 0xA0).contains($0.value) }
    }

    /// What is typed into the login window: the name, Tab, the password,
    /// Return. `InputCore.text` turns the tab and the line feed into key
    /// presses and types the rest as Unicode.
    var typingPayload: Data { Data((user + "\t" + password + "\n").utf8) }
}

/// Whether the host acts on a LOGIN_CREDENTIALS message, kept apart from the
/// server so tests can drive it.
enum LoginCredentialsPolicy {
    /// Least time between two accepted messages on one listener.
    static let minInterval: TimeInterval = 3

    /// True only when the host is the login-window agent, the connection is
    /// the encrypted one of a device that was let in, and that device said it
    /// can send a login. A connection in the clear (approval off) never types
    /// a password.
    static func allowed(serving: Bool, phase: StreamLink.Phase, capabilities: StreamCapabilities?) -> Bool {
        serving && phase == .accepted && (capabilities?.contains(.loginCredentials) ?? false)
    }

    static func rateAllows(last: TimeInterval?, now: TimeInterval) -> Bool {
        guard let last else { return true }
        return now - last >= minInterval
    }
}
