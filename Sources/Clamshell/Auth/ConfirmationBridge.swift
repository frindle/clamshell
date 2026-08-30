import Foundation
import CryptoKit

public class ConfirmationBridge {
    /// How long an issued nonce stays valid. Public so a UI can count down
    /// against the same deadline the bridge enforces instead of duplicating
    /// the constant and drifting from it.
    public static let nonceTTL: TimeInterval = 30.0

    private var pendingActions: [UUID: PendingAction] = [:]
    private var enrolledPublicKeys: [String: Data] = [:]
    private let nonceTTL = ConfirmationBridge.nonceTTL

    public func enroll(clientId: String, publicKey: Data) {
        enrolledPublicKeys[clientId] = publicKey
    }

    public func requestConfirmation(actionId: UUID, clientId: String) -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let nonce = Data(bytes)
        let expiresAt = Date().addingTimeInterval(nonceTTL)
        pendingActions[actionId] = PendingAction(nonce: nonce, expiresAt: expiresAt, clientId: clientId)
        return nonce
    }

    public func verifyConfirmation(actionId: UUID, signature: Data) -> Bool {
        guard let pending = pendingActions[actionId], pending.expiresAt > Date() else {
            pendingActions[actionId] = nil
            return false
        }

        guard let publicKeyData = enrolledPublicKeys[pending.clientId],
              let publicKey = try? P256.Signing.PublicKey(rawRepresentation: publicKeyData) else {
            pendingActions[actionId] = nil
            return false
        }

        // Accept both signature encodings that occur in practice: 64-byte
        // raw r||s (CryptoKit's rawRepresentation, the original software
        // client) and ASN.1 DER — which is what a YubiKey PIV GENERAL
        // AUTHENTICATE emits, so hardware-backed confirmation needs it.
        let ecdsaSignature: P256.Signing.ECDSASignature
        if signature.count == 64, let raw = try? P256.Signing.ECDSASignature(rawRepresentation: signature) {
            ecdsaSignature = raw
        } else if let der = try? P256.Signing.ECDSASignature(derRepresentation: signature) {
            ecdsaSignature = der
        } else {
            return false
        }

        let valid = publicKey.isValidSignature(ecdsaSignature, for: pending.nonce)
        if valid {
            pendingActions[actionId] = nil
        }
        return valid
    }

    private struct PendingAction {
        let nonce: Data
        let expiresAt: Date
        let clientId: String
    }
}
