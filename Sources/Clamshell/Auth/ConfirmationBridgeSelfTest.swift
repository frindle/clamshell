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
