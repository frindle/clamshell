import Foundation
import CryptoKit
import XCTest

public class ConfirmationBridgeSelfTest {
    private let bridge = ConfirmationBridge()
    private let testClientId = "test-client"
    private let testKeyPair = P256.KeyAgreement.KeyPair()

    public func runTests() {
        // Test 1: Valid signature
        let validResult = testValidSignature()
        print("Valid signature test: \(validResult ? "Passed" : "Failed")")

        // Test 2: Replayed signature
        let replayResult = testReplayedSignature()
        print("Replayed signature test: \(replayResult ? "Passed" : "Failed")")

        // Test 3: Expired nonce
        let expirationResult = testExpiredNonce()
        print("Expired nonce test: \(expirationResult ? "Passed" : "Failed")")
    }

    private func testValidSignature() -> Bool {
        // Enroll the test client with the public key
        bridge.enroll(clientId: testClientId, publicKey: testKeyPair.publicKey.rawRepresentation)

        // Request a nonce
        let actionId = UUID()
        let nonce = bridge.requestConfirmation(actionId: actionId, clientId: testClientId)

        // Sign the nonce with the private key
        guard let signature = try? testKeyPair.sign(nonce) else {
            return false
        }

        // Verify the signature
        return bridge.verifyConfirmation(actionId: actionId, signature: signature)
    }

    private func testReplayedSignature() -> Bool {
        // Enroll the test client
        bridge.enroll(clientId: testClientId, publicKey: testKeyPair.publicKey.rawRepresentation)

        // Request a nonce and sign it
        let actionId = UUID()
        let nonce = bridge.requestConfirmation(actionId: actionId, clientId: testClientId)
        guard let signature = try? testKeyPair.sign(nonce) else {
            return false
        }

        // Verify once (should succeed)
        let firstVerification = bridge.verifyConfirmation(actionId: actionId, signature: signature)
        if !firstVerification {
            return false
        }

        // Try to replay the same signature
        let secondVerification = bridge.verifyConfirmation(actionId: actionId, signature: signature)
        return !secondVerification
    }

    private func testExpiredNonce() -> Bool {
        // Enroll the test client
        bridge.enroll(clientId: testClientId, publicKey: testKeyPair.publicKey.rawRepresentation)

        // Request a nonce
        let actionId = UUID()
        let nonce = bridge.requestConfirmation(actionId: actionId, clientId: testClientId)

        // Wait for the nonce to expire
        Thread.sleep(forTimeInterval: bridge.nonceTTL + 1)

        // Sign the expired nonce
        guard let signature = try? testKeyPair.sign(nonce) else {
            return false
        }

        // Verify the signature after expiration
        return !bridge.verifyConfirmation(actionId: actionId, signature: signature)
    }
}

// Entry point for the test
let test = ConfirmationBridgeSelfTest()
test.runTests()
