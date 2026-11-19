import Foundation
import CryptoKit
import Security

// The one P-256 signing key that says which device this installed copy of the
// app is. On a real device it lives in the Secure Enclave, so the private key
// cannot be read out, not even by this app; in the simulator, which has no
// Secure Enclave, it is a software key. The private key never leaves this
// file: it is not logged, not exported, not kept in UserDefaults or a file,
// and never synced. The public key and its fingerprint may be shown and logged.

/// What the rest of the app gets: the public key, and a way to sign.
struct DeviceKey {
    /// 65-byte X9.63 public key.
    let publicKey: Data
    /// 64-byte raw r||s ECDSA over SHA-256 of the input, the same as
    /// `AuthSignature.signer` gives for a software key. CryptoKit hashes, so
    /// nothing is hashed first.
    let sign: AuthSigner
    /// True when the key is in the Secure Enclave.
    let inSecureEnclave: Bool

    var fingerprint: String { DeviceIdentity.fingerprint(ofPublicKey: publicKey) }
}

enum DeviceKeyError: Error, LocalizedError {
    /// The Keychain could not be read or written (for example the device is
    /// locked). No key was created.
    case keychain(OSStatus)
    /// A key is stored but cannot be used. No key was created.
    case unusable

    var errorDescription: String? {
        switch self {
        case let .keychain(status):
            return "This device's key could not be read (Keychain error \(status)). If the device is locked, unlock it and try again. Nothing was sent."
        case .unusable:
            return "This device's key is stored but cannot be used. Nothing was sent."
        }
    }
}

enum DeviceKeyStore {
    private static let service = "clamshell.device-key"
    private static let hardwareAccount = "secure-enclave-v1"
    private static let softwareAccount = "software-v1"

    private static let lock = NSLock()
    private static var cached: DeviceKey?

    /// The device key, created on first use. A key is created only when the
    /// Keychain says there is none. Any other read error throws and creates
    /// nothing: a fresh key would be a new device the Mac has never approved.
    static func load() throws -> DeviceKey {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let key = SecureEnclave.isAvailable ? try loadHardware() : try loadSoftware()
        cached = key
        return key
    }

    // MARK: Secure Enclave

    private static func loadHardware() throws -> DeviceKey {
        switch read(account: hardwareAccount) {
        case let .found(blob):
            guard let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob) else {
                throw DeviceKeyError.unusable
            }
            return wrap(key)
        case let .failed(status):
            throw DeviceKeyError.keychain(status)
        case .missing:
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .privateKeyUsage, &error) else {
                throw DeviceKeyError.unusable
            }
            guard let key = try? SecureEnclave.P256.Signing.PrivateKey(accessControl: access) else {
                throw DeviceKeyError.unusable
            }
            let status = add(account: hardwareAccount, data: key.dataRepresentation)
            guard status == errSecSuccess else { throw DeviceKeyError.keychain(status) }
            return wrap(key)
        }
    }

    private static func wrap(_ key: SecureEnclave.P256.Signing.PrivateKey) -> DeviceKey {
        DeviceKey(publicKey: key.publicKey.x963Representation,
                  sign: { input in try key.signature(for: input).rawRepresentation },
                  inSecureEnclave: true)
    }

    // MARK: Software (simulator)

    private static func loadSoftware() throws -> DeviceKey {
        switch read(account: softwareAccount) {
        case let .found(raw):
            guard let key = try? P256.Signing.PrivateKey(rawRepresentation: raw) else {
                throw DeviceKeyError.unusable
            }
            return wrap(key)
        case let .failed(status):
            throw DeviceKeyError.keychain(status)
        case .missing:
            let key = P256.Signing.PrivateKey()
            let status = add(account: softwareAccount, data: key.rawRepresentation)
            guard status == errSecSuccess else { throw DeviceKeyError.keychain(status) }
            return wrap(key)
        }
    }

    private static func wrap(_ key: P256.Signing.PrivateKey) -> DeviceKey {
        DeviceKey(publicKey: key.publicKey.x963Representation,
                  sign: AuthSignature.signer(key),
                  inSecureEnclave: false)
    }

    // MARK: Keychain

    private enum ReadResult {
        case found(Data)
        case missing
        case failed(OSStatus)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
    }

    private static func read(account: String) -> ReadResult {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            if let data = out as? Data { return .found(data) }
            return .failed(errSecDecode)
        case errSecItemNotFound:
            return .missing
        default:
            return .failed(status)
        }
    }

    private static func add(account: String, data: Data) -> OSStatus {
        var item = baseQuery(account: account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil)
    }
}
