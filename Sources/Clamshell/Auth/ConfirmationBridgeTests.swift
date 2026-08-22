import Foundation
import XCTest
import Cryptography

final class ConfirmationBridgeTests: XCTestCase {
    func testConfirmationFlow() async {
        let bridge = ConfirmationBridge()
        let challenge = bridge.createChallenge()
        let signature = bridge.sign(challenge: challenge)
        
        // Test valid signature
        XCTAssertTrue(bridge.verify(signature: signature, for: challenge))

        // Test replay attack
        let newChallenge = bridge.createChallenge()
        XCTAssertFalse(bridge.verify(signature: signature, for: newChallenge))

        // Test expired nonce
        let expiredChallenge = UUID().uuidString + "|" + (Date().adding(minutes: -1).description)
        let expiredSignature = bridge.sign(challenge: expiredChallenge)
        XCTAssertFalse(bridge.verify(signature: expiredSignature, for: expiredChallenge))
    }
}
