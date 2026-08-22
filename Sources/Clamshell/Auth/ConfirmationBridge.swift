import Foundation
import Cryptography

@main
struct ConfirmationBridge {
    private var privateKey: P256.Signing.PrivateKey
    private var publicKey: P256.Signing.PublicKey

    init() {
        let keyPair = try! P256.Signing.KeyPair.generate()
        privateKey = keyPair.privateKey
        publicKey = keyPair.publicKey
    }

    func createChallenge() -> String {
        let nonce = UUID().uuidString
        let expiry = Date().adding(minutes: 5)
        return nonce + "|" + expiry.description
    }

    func sign(challenge: String) -> String {
        let data = challenge.data(using: .utf8)!
        let signature = try! privateKey.sign(data)
        return Data(signature).base64EncodedString()
    }

    func verify(signature: String, for challenge: String) -> Bool {
        let data = challenge.data(using: .utf8)!
        let signatureData = Data(base64Encoded: signature)!
        return publicKey.verify(signature: signatureData, of: data)
    }
}
