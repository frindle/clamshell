import Foundation
import Security

// Saved RDP targets: everything except the password follows MachineStore's
// pattern exactly (Codable list in UserDefaults). The password is the first
// secret this app has ever needed to persist, so it goes in the Keychain —
// there's no prior in-app convention for that, so this follows the standard
// iOS idiom (kSecClassGenericPassword, one item per profile, keyed by the
// profile's UUID) rather than inventing something bespoke.

struct RDPProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var host: String
    var port: UInt16 = 3389
    var username: String
    var domain: String?
}

final class RDPProfileStore: ObservableObject {
    @Published private(set) var profiles: [RDPProfile] = []
    @Published private(set) var lastUsedID: UUID?
    private let key = "savedRDPProfiles"
    private let lastUsedKey = "lastUsedRDPProfileID"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([RDPProfile].self, from: data) {
            profiles = list
        }
        if let idString = UserDefaults.standard.string(forKey: lastUsedKey) {
            lastUsedID = UUID(uuidString: idString)
        }
    }

    var lastUsed: RDPProfile? {
        guard let id = lastUsedID else { return nil }
        return profiles.first { $0.id == id }
    }

    func markUsed(_ profile: RDPProfile) {
        lastUsedID = profile.id
        UserDefaults.standard.set(profile.id.uuidString, forKey: lastUsedKey)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Adds or updates by (host, port, username) — reconnecting to the same
    /// target with the same login refreshes it rather than piling up
    /// duplicates, matching MachineStore's upsert-by-host behavior.
    @discardableResult
    func upsert(_ profile: RDPProfile, password: String?) -> RDPProfile {
        var saved = profile
        if let idx = profiles.firstIndex(where: {
            $0.host == profile.host && $0.port == profile.port && $0.username == profile.username
        }) {
            saved.id = profiles[idx].id
            profiles[idx] = saved
        } else {
            profiles.append(saved)
        }
        persist()
        if let password, !password.isEmpty {
            RDPKeychain.save(password: password, for: saved.id)
        }
        return saved
    }

    func delete(_ profile: RDPProfile) {
        profiles.removeAll { $0.id == profile.id }
        persist()
        RDPKeychain.delete(for: profile.id)
    }

    func password(for profile: RDPProfile) -> String? {
        RDPKeychain.load(for: profile.id)
    }
}

/// Thin wrapper around the Keychain Services C API — SecItem calls have no
/// Swift-friendly shape of their own, same reason RDPBridge exists for
/// FreeRDP. One generic-password item per saved RDP profile.
enum RDPKeychain {
    private static let service = "com.frindle.clamshell.viewer.rdp"

    private static func query(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    static func save(password: String, for id: UUID) {
        guard let data = password.data(using: .utf8) else { return }
        var q = query(for: id)
        SecItemDelete(q as CFDictionary) // replace-if-exists
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }

    static func load(for id: UUID) -> String? {
        var q = query(for: id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for id: UUID) {
        SecItemDelete(query(for: id) as CFDictionary)
    }
}
