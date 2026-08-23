import Foundation
import CryptoKit

enum ConfirmationBridgeSelfTest {
    static func run() -> Int32 {
        let clientId = "test-client"
        let privateKey = P256.Signing.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation

        let bridge = ConfirmationBridge()
        bridge.enroll(clientId: clientId, publicKey: publicKey)

        var passed = true

        let actionId = UUID()
        let nonce = bridge.requestConfirmation(actionId: actionId, clientId: clientId)
        guard let signature = try? privateKey.signature(for: nonce) else {
            print("FAILED: signing failed")
            return 1
        }
        let signatureData = signature.rawRepresentation

        if bridge.verifyConfirmation(actionId: actionId, signature: signatureData) {
            print("PASS: correct signature verifies")
        } else {
            print("FAILED: correct signature did not verify")
            passed = false
        }

        if bridge.verifyConfirmation(actionId: actionId, signature: signatureData) {
            print("FAILED: replayed signature verified again")
            passed = false
        } else {
            print("PASS: replay protection rejected the second verify")
        }

        // DER-encoded signature (what a YubiKey PIV slot emits) must verify
        // just like the raw encoding above.
        let derActionId = UUID()
        let derNonce = bridge.requestConfirmation(actionId: derActionId, clientId: clientId)
        if let derSignature = try? privateKey.signature(for: derNonce).derRepresentation,
           bridge.verifyConfirmation(actionId: derActionId, signature: derSignature) {
            print("PASS: DER-encoded signature verifies")
        } else {
            print("FAILED: DER-encoded signature did not verify")
            passed = false
        }

        // A signature that is perfectly valid for pending action A must not
        // confirm pending action B (each action has its own nonce).
        let actionA = UUID()
        let actionB = UUID()
        let nonceA = bridge.requestConfirmation(actionId: actionA, clientId: clientId)
        _ = bridge.requestConfirmation(actionId: actionB, clientId: clientId)
        if let signatureA = try? privateKey.signature(for: nonceA),
           bridge.verifyConfirmation(actionId: actionB, signature: signatureA.rawRepresentation) {
            print("FAILED: signature for a different pending action verified")
            passed = false
        } else {
            print("PASS: signature for a different pending action rejected")
        }

        // Wrong key: valid signature over the right nonce, unenrolled key.
        let strangerActionId = UUID()
        let strangerNonce = bridge.requestConfirmation(actionId: strangerActionId, clientId: clientId)
        if let strangerSignature = try? P256.Signing.PrivateKey().signature(for: strangerNonce),
           bridge.verifyConfirmation(actionId: strangerActionId, signature: strangerSignature.rawRepresentation) {
            print("FAILED: signature from an unenrolled key verified")
            passed = false
        } else {
            print("PASS: signature from an unenrolled key rejected")
        }

        // Malformed signature bytes.
        let malformedActionId = UUID()
        _ = bridge.requestConfirmation(actionId: malformedActionId, clientId: clientId)
        if bridge.verifyConfirmation(actionId: malformedActionId, signature: Data([0xDE, 0xAD])) {
            print("FAILED: malformed signature verified")
            passed = false
        } else {
            print("PASS: malformed signature rejected")
        }

        let expiredActionId = UUID()
        let expiredNonce = bridge.requestConfirmation(actionId: expiredActionId, clientId: clientId)
        guard let expiredSignature = try? privateKey.signature(for: expiredNonce) else {
            print("FAILED: signing failed (expiry test)")
            return 1
        }
        print("Waiting 31s for the nonce to actually expire...")
        Thread.sleep(forTimeInterval: 31.0)
        if bridge.verifyConfirmation(actionId: expiredActionId, signature: expiredSignature.rawRepresentation) {
            print("FAILED: expired nonce verified")
            passed = false
        } else {
            print("PASS: expired nonce correctly rejected")
        }

        return passed ? 0 : 1
    }
}
