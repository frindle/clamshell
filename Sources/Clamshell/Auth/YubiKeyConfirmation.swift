import Foundation
import CryptoKit
import ImmurokKit

/// Thin adapter between Clamshell's ConfirmationBridge and a YubiKey PIV
/// slot (via ImmurokKit, where the core and the PIV transport live and are
/// tested — see github.com/frindle/immurok-yk).
///
/// Clamshell's settled flow is unchanged: the host issues a 32-byte nonce
/// for a pending action over the authenticated WebSocket, the client signs
/// it with ECDSA P-256, the host verifies against the enrolled public key,
/// consumes the nonce, and expires it after 30 s. The only two things a
/// YubiKey changes:
///
///   - the client-side signature comes from PIV GENERAL AUTHENTICATE over
///     SHA256(nonce) — same bytes CryptoKit verifies, but the private key
///     never leaves the card and the slot's touch policy makes every
///     signature proof of a human hand at the key;
///   - the signature arrives DER-encoded (ConfirmationBridge accepts both
///     encodings as of this change).
enum YubiKeyConfirmation {
    /// Reads the public key off the plugged-in YubiKey's PIV slot 9a
    /// (attestation certificate preferred — proves on-device generation)
    /// and enrolls it into the bridge under `clientId`.
    static func enroll(into bridge: ConfirmationBridge, clientId: String) async throws {
        let card = try await PIVCard.connect()
        defer { card.end() }
        let x963 = try await card.publicKey()
        // Bridge stores raw 64-byte x||y; the card hands back X9.63 (04||x||y).
        let raw = try P256.Signing.PublicKey(x963Representation: x963).rawRepresentation
        bridge.enroll(clientId: clientId, publicKey: raw)
    }

    /// Signs a ConfirmationBridge nonce on the YubiKey. Blocks until the
    /// key is touched when the slot's touch policy demands it. Returns a
    /// DER-encoded ECDSA signature.
    static func signNonce(_ nonce: Data, pin: @escaping () throws -> String) async throws -> Data {
        try await PIVSigner(keyId: "clamshell-yubikey", pinProvider: pin).sign(message: nonce)
    }
}
