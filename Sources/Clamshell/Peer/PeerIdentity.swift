import Foundation
import CryptoKit

// Who this machine is to its peers, and which peers it trusts.
//
// Identity: one long-lived P-256 signing key per install, generated on first
// use and kept in Application Support with 0600 permissions (the same place
// the log lives, not the Keychain — this must work from the bare CLI binary
// and inside the .app identically, and Keychain ACLs differ per binary).
// Peer ID = SHA-256 of the X9.63 public key, hex — what the trust store and
// the Bonjour TXT record carry.
//
// Pairing: a 6-digit PIN shown on the machine being paired *to*, typed on
// the one initiating. Both sides prove knowledge of it with an HMAC over the
// other side's nonce and their own public key, so a PIN never crosses the
// wire, a proof can't be replayed (fresh nonce per connection), and each
// side ends up trusting exactly the key it saw the proof for. After that a
// reconnect is a plain ECDSA challenge/response against the stored key.
//
// The same shapes are implemented in WindowsServer/PeerIdentity.cs; the
// selftest pins the exact byte layout so the two can't drift.

struct PeerInfo: Codable, Equatable {
    let id: String          // SHA-256(publicKey) hex
    var name: String
    let publicKey: Data     // 65-byte X9.63
    var pairedAt: Date
}

final class PeerIdentity {
    let privateKey: P256.Signing.PrivateKey
    var publicKey: Data { privateKey.publicKey.x963Representation }
    var id: String { Self.peerId(for: publicKey) }

    /// Loads or creates the key at `url`. Injectable so the selftest can use
    /// a scratch directory (and so two identities can coexist in one process).
    init(fileURL: URL) throws {
        let fm = FileManager.default
        if let raw = try? Data(contentsOf: fileURL), let key = try? P256.Signing.PrivateKey(rawRepresentation: raw) {
            privateKey = key
            return
        }
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        privateKey = P256.Signing.PrivateKey()
        try privateKey.rawRepresentation.write(to: fileURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// In-memory only (selftests).
    init() { privateKey = P256.Signing.PrivateKey() }

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Clamshell", isDirectory: true)
    }

    static func peerId(for publicKey: Data) -> String {
        SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
    }

    /// Raw r||s, 64 bytes — the layout ConfirmationBridge already accepts
    /// and .NET's default ECDSA signature format.
    func sign(nonce: Data) -> Data {
        (try? privateKey.signature(for: nonce + publicKey).rawRepresentation) ?? Data()
    }

    static func verify(signature: Data, nonce: Data, publicKey: Data) -> Bool {
        guard let key = try? P256.Signing.PublicKey(x963Representation: publicKey),
              let sig = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
        return key.isValidSignature(sig, for: nonce + publicKey)
    }

    // MARK: - PIN proofs

    static func pinKey(_ pin: String) -> SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: Data("clamshell-pair:\(pin)".utf8)))
    }

    static func pinProof(pin: String, nonce: Data, publicKey: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: nonce + publicKey, using: pinKey(pin)))
    }

    static func verifyPinProof(_ proof: Data, pin: String, nonce: Data, publicKey: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: nonce + publicKey, using: pinKey(pin))
    }

    static func randomNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: PeerLimits.nonceSize)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    /// Six digits, uniformly random (SystemRandomNumberGenerator is CSPRNG-backed).
    static func randomPIN() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }
}

/// Persisted list of paired peers. Main-queue confined like the rest of the
/// app state; the file is rewritten whole on every change (tiny).
final class PeerTrustStore {
    private(set) var peers: [PeerInfo] = []
    private let fileURL: URL?

    init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([PeerInfo].self, from: data) {
            peers = list
        }
    }

    func peer(id: String) -> PeerInfo? { peers.first { $0.id == id } }
    func isTrusted(publicKey: Data) -> Bool {
        peers.contains { $0.publicKey == publicKey }
    }

    func trust(publicKey: Data, name: String) {
        let id = PeerIdentity.peerId(for: publicKey)
        if let i = peers.firstIndex(where: { $0.id == id }) {
            peers[i].name = name
        } else {
            peers.append(PeerInfo(id: id, name: name, publicKey: publicKey, pairedAt: Date()))
        }
        save()
    }

    func forget(id: String) {
        peers.removeAll { $0.id == id }
        save()
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(peers).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            clog("PEER: could not save trust store: \(error)")
        }
    }
}
