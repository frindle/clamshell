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
    /// `allowPrompt` lets the system ask the user (only for a retry the user
    /// started); otherwise it must fail instead of showing anything.
    func readKey(allowPrompt: Bool) throws -> Data?
    /// Removes the item. Only for the user-confirmed reset.
    func deleteKey() throws
    /// Stores `key` unless an item already exists. False means one did.
    func addKey(_ key: Data) throws -> Bool
}

struct KeychainStatusError: Error, CustomStringConvertible {
    let status: OSStatus
    var description: String { "keychain status \(status)" }
}

struct KeychainIntegrityKeyStore: IntegrityKeyStore {
    static let service = "com.frindle.clamshell.trust-integrity"
    /// One item per state directory, so a host run on a scratch directory (the
    /// interop test) never shares or replaces the key of the real one.
    let account: String
    /// The item this build made for itself, and the hand-off a previous build
    /// left for it (see `TrustBridge`). Nil for a build with no code hash.
    private let buildAccount: String?
    private let directory: URL
    private let cdhash: String?
    private let quietRead = BoundedRead()
    /// Longest a read that must not show anything may hold its caller.
    static let quietReadTimeout: TimeInterval = 2

    init(directory: URL, cdhash: String? = TrustBridge.ownCdhash) {
        let path = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8))
        let base = "mac-key-" + Hex.encode(Data(digest).prefix(8))
        account = base
        self.directory = directory
        self.cdhash = cdhash
        buildAccount = cdhash.map { base + "-" + String($0.prefix(16)) }
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account]
    }

    func readKey(allowPrompt: Bool) throws -> Data? {
        guard let buildAccount, let cdhash else { return try read(account, allowPrompt: allowPrompt) }
        return try IntegrityKeyResolver(
            readBuild: { try read(buildAccount, allowPrompt: allowPrompt) },
            takeBridge: {
                switch TrustBridge.take(directory: directory, ownCdhash: cdhash) {
                case .key(let k):
                    clog("INTEGRITY: took the integrity key handed over by the previous build")
                    return k
                case .rejected(let why):
                    clog("INTEGRITY: ignored the update hand-off (\(why))")
                    return nil
                case .none: return nil
                }
            },
            readLegacy: { try read(account, allowPrompt: allowPrompt) },
            storeBuild: { key in
                do { _ = try add(key, account: buildAccount) } catch { clog("INTEGRITY: cannot keep the key for this build (\(error))") }
            }).resolve()
    }

    private func read(_ account: String, allowPrompt: Bool) throws -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Never show a dialog from a background process: fail instead.
        if !allowPrompt { query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        func copy() throws -> Data? {
            var out: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &out)
            switch status {
            case errSecSuccess: return out as? Data
            case errSecItemNotFound: return nil
            default: throw KeychainStatusError(status: status)
            }
        }
        if allowPrompt { return try copy() }
        // The login keychain can still raise its dialog for a read marked
        // "fail instead", and the call then waits for an answer. A quiet read
        // is therefore bounded, so launch can never hang on it.
        return try quietRead.run(timeout: Self.quietReadTimeout, copy)
    }

    func deleteKey() throws {
        for name in [account, buildAccount].compactMap({ $0 }) {
            let status = SecItemDelete(query(name) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainStatusError(status: status)
            }
        }
    }

    func addKey(_ key: Data) throws -> Bool {
        try add(key, account: buildAccount ?? account)
    }

    private func add(_ key: Data, account: String) throws -> Bool {
        var query = query(account)
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

    /// After a read that could not be answered, further reads wait this long
    /// instead of holding every new connection for the quiet-read timeout. A
    /// Mac that needs its Keychain approved is answered at once, "host needs
    /// Keychain approval", until someone does.
    static let unavailableRetryInterval: TimeInterval = 30
    private let now: () -> Date
    private var unavailableSince: Date?
    private var loggedNeedsApproval = false

    init(keys: IntegrityKeyStore, now: @escaping () -> Date = Date.init) {
        self.keys = keys
        self.now = now
    }

    /// The host's real integrity, backed by the keychain.
    static func keychain(for directory: URL) -> TrustIntegrity {
        TrustIntegrity(keys: KeychainIntegrityKeyStore(directory: directory))
    }

    func lookup() -> Lookup {
        lock.lock()
        defer { lock.unlock() }
        return lookupLocked()
    }

    private func lookupLocked() -> Lookup {
        if let cached { return .key(cached) }
        if let since = unavailableSince, now().timeIntervalSince(since) < Self.unavailableRetryInterval,
           now() >= since {
            return .unavailable
        }
        do {
            guard let data = try keys.readKey(allowPrompt: false) else { unavailableSince = nil; return .missing }
            guard data.count == 32 else {
                clog("INTEGRITY: the keychain item has an unexpected size — treating it as unavailable")
                return .unavailable
            }
            let key = SymmetricKey(data: data)
            cached = key
            unavailableSince = nil
            loggedNeedsApproval = false
            return .key(key)
        } catch {
            unavailableSince = now()
            if !loggedNeedsApproval {
                loggedNeedsApproval = true
                clog("INTEGRITY: the host needs Keychain approval (cannot read the integrity key: \(error)); clients are told so until it is approved from the menu bar")
            }
            return .unavailable
        }
    }

    /// Makes the key. Only for callers that decided a new key is right.
    /// `opensMigration` is true only for the first-run path: a key made for a
    /// later change (or a reset) must never let an unsigned list be adopted.
    private func createLocked(opensMigration: Bool) -> SymmetricKey? {
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        do {
            if try keys.addKey(data) {
                cached = key
                if opensMigration { createdThisRun = true }
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
        case .missing: return createLocked(opensMigration: true)
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
            return createLocked(opensMigration: false)
        case .unavailable: return nil
        }
    }

    /// True when the keychain key exists but cannot be read without asking.
    var isUnavailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .unavailable = lookupLocked() { return true }
        return false
    }

    /// The user asked to try again: reads the key with the system allowed to
    /// ask for a password. True when the key could be read afterwards.
    func retryWithPrompt() -> Bool {
        lock.lock()
        let have = cached != nil
        lock.unlock()
        if have { return true }
        // Not under the lock: the dialog can stay up for as long as the user
        // likes, and everything else that needs the key must not wait on it.
        do {
            guard let data = try keys.readKey(allowPrompt: true), data.count == 32 else { return false }
            lock.lock()
            cached = SymmetricKey(data: data)
            unavailableSince = nil
            loggedNeedsApproval = false
            lock.unlock()
            return true
        } catch {
            clog("INTEGRITY: cannot read the integrity key (\(error))")
            return false
        }
    }

    /// Throws the old key away and makes a new one. Everything signed with the
    /// old key stops counting: devices have to be approved again, and a
    /// stored "approval is off" has to be set again. Does nothing unless
    /// `userConfirmed` (the caller got an explicit yes). Never reopens
    /// migration. True when a new key is in place.
    func resetKey(userConfirmed: Bool) -> Bool {
        guard userConfirmed else { return false }
        lock.lock()
        defer { lock.unlock() }
        cached = nil
        unavailableSince = nil
        do {
            try keys.deleteKey()
        } catch {
            clog("INTEGRITY: cannot remove the old integrity key (\(error))")
            return false
        }
        clog("INTEGRITY: the integrity key was reset at the user's request; devices have to be approved again")
        return createLocked(opensMigration: false) != nil
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
