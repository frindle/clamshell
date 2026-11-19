import Foundation
import CryptoKit
import Security

// Integrity for what decides who may connect: the device list and the
// "device approval is required" setting. Both live where another program
// running as the same user can write them, so each carries an HMAC-SHA256
// made with a key that is kept in the keychain (a generic password item the
// host creates; its default access list lets only the host's own code
// signature read it without asking). A list or setting whose MAC is missing
// or wrong is not trusted.
//
// The keychain sits behind `IntegrityKeyStore` so tests use an in-memory one
// and never touch the real keychain.

protocol IntegrityKeyStore {
    /// The key, or nil when there is none. Throws when the keychain cannot be
    /// asked right now (locked, access refused, no user interaction possible).
    func readKey() throws -> Data?
    /// Stores `key` unless an item already exists. False means one did.
    func addKey(_ key: Data) throws -> Bool
}

struct KeychainStatusError: Error, CustomStringConvertible {
    let status: OSStatus
    var description: String { "keychain status \(status)" }
}

struct KeychainIntegrityKeyStore: IntegrityKeyStore {
    static let service = "com.frindle.clamshell.trust-integrity"
    static let account = "mac-key"

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account]
    }

    func readKey() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Never show a dialog from a background process: fail instead.
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess: return out as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainStatusError(status: status)
        }
    }

    func addKey(_ key: Data) throws -> Bool {
        var query = baseQuery
        query[kSecValueData as String] = key
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        query[kSecAttrLabel as String] = "Clamshell trust store integrity key"
        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess: return true
        case errSecDuplicateItem: return false
        default: throw KeychainStatusError(status: status)
        }
    }
}

final class TrustIntegrity {
    enum Lookup {
        case key(SymmetricKey)
        case missing
        /// The keychain could not be asked; nothing is trusted meanwhile.
        case unavailable
    }

    static let devicesDomain = "clamshell.devices.v1\n"
    static let approvalDomain = "clamshell.requireDeviceApproval.v1\n"

    private let keys: IntegrityKeyStore
    private let lock = NSLock()
    private var cached: SymmetricKey?
    /// True once this process made the key. Only then may a list or setting
    /// that has no MAC yet be adopted: that is the one-time move from a build
    /// that did not have MACs.
    private(set) var createdThisRun = false

    init(keys: IntegrityKeyStore) {
        self.keys = keys
    }

    /// The host's real integrity, backed by the keychain.
    static func keychain() -> TrustIntegrity {
        TrustIntegrity(keys: KeychainIntegrityKeyStore())
    }

    func lookup() -> Lookup {
        lock.lock()
        defer { lock.unlock() }
        return lookupLocked()
    }

    private func lookupLocked() -> Lookup {
        if let cached { return .key(cached) }
        do {
            guard let data = try keys.readKey() else { return .missing }
            guard data.count == 32 else {
                clog("INTEGRITY: the keychain item has an unexpected size — treating it as unavailable")
                return .unavailable
            }
            let key = SymmetricKey(data: data)
            cached = key
            return .key(key)
        } catch {
            clog("INTEGRITY: cannot read the integrity key (\(error))")
            return .unavailable
        }
    }

    /// Makes the key. Only for callers that decided a new key is right.
    private func createLocked() -> SymmetricKey? {
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        do {
            if try keys.addKey(data) {
                cached = key
                createdThisRun = true
                clog("INTEGRITY: created the integrity key in the keychain")
                return key
            }
            // Another process made it first: use theirs.
            if case .key(let theirs) = lookupLocked() { return theirs }
        } catch {
            clog("INTEGRITY: cannot create the integrity key (\(error))")
        }
        return nil
    }

    /// For something that has no MAC yet. Returns the key when it may be
    /// adopted now: the key is missing (and is made here) or this process made
    /// it. A key that already existed means the MAC went missing, which is
    /// not trusted.
    func beginMigration() -> SymmetricKey? {
        lock.lock()
        defer { lock.unlock() }
        switch lookupLocked() {
        case .missing: return createLocked()
        case .key(let k): return createdThisRun ? k : nil
        case .unavailable: return nil
        }
    }

    /// The key to sign a change with. A missing key is made here: a change is
    /// something the user did, so what was there before is no longer relied on.
    func keyForWrite() -> SymmetricKey? {
        lock.lock()
        defer { lock.unlock() }
        switch lookupLocked() {
        case .key(let k): return k
        case .missing:
            clog("INTEGRITY: the integrity key is missing — making a new one; devices have to be approved again")
            return createLocked()
        case .unavailable: return nil
        }
    }

    // MARK: MACs

    static func mac(_ key: SymmetricKey, domain: String, _ data: Data) -> String {
        var input = Data(domain.utf8)
        input.append(data)
        return Hex.encode(Data(HMAC<SHA256>.authenticationCode(for: input, using: key)))
    }

    static func verify(_ key: SymmetricKey, domain: String, _ data: Data, mac: String) -> Bool {
        guard let given = Hex.decode(mac), given.count == 32 else { return false }
        var input = Data(domain.utf8)
        input.append(data)
        return HMAC<SHA256>.isValidAuthenticationCode(given, authenticating: input, using: key)
    }

    static func approvalBytes(_ on: Bool) -> Data { Data((on ? "true" : "false").utf8) }
}
