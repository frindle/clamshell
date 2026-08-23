import Foundation

/// Hardware self-test: the full confirmation loop with a real YubiKey as
/// the signer. `clamshell confirmation-yubikey-selftest`.
///
/// Requirements (see immurok-yk's README for the full walkthrough):
///   - a YubiKey 5 plugged in, with an ECCP256 key in PIV slot 9a
///     (`ykman piv keys generate --algorithm ECCP256 --pin-policy once
///     --touch-policy always 9a /tmp/piv-9a.pem`)
///   - the clamshell binary signed with the com.apple.security.smartcard
///     entitlement (immurok-yk's scripts/sign-smartcard.sh does this)
///   - the PIV PIN in $CLAMSHELL_PIV_PIN, or entered at the prompt
///
/// Without hardware this fails fast with the reason — it never fakes a pass.
enum YubiKeyConfirmationSelfTest {
    static func run() async -> Int32 {
        let bridge = ConfirmationBridge()
        let clientId = "yubikey-selftest"
        var passed = true

        do {
            try await YubiKeyConfirmation.enroll(into: bridge, clientId: clientId)
            print("enrolled public key from YubiKey PIV slot 9a")

            let pin: () throws -> String = {
                if let env = ProcessInfo.processInfo.environment["CLAMSHELL_PIV_PIN"], !env.isEmpty {
                    return env
                }
                guard let raw = getpass("PIV PIN: ") else {
                    throw NSError(domain: "YubiKeyConfirmationSelfTest", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "could not read PIN"])
                }
                return String(cString: raw)
            }

            let actionId = UUID()
            let nonce = bridge.requestConfirmation(actionId: actionId, clientId: clientId)
            print("challenge issued — touch the YubiKey when it blinks...")
            let signature = try await YubiKeyConfirmation.signNonce(nonce, pin: pin)

            if bridge.verifyConfirmation(actionId: actionId, signature: signature) {
                print("PASS: YubiKey signature verifies (hardware presence confirmed)")
            } else {
                print("FAILED: YubiKey signature did not verify")
                passed = false
            }

            if bridge.verifyConfirmation(actionId: actionId, signature: signature) {
                print("FAILED: replayed YubiKey signature verified again")
                passed = false
            } else {
                print("PASS: replayed YubiKey signature rejected")
            }
        } catch {
            print("FAILED: \(error)")
            print("(needs: YubiKey plugged in, ECCP256 key in slot 9a, smartcard-entitled binary)")
            return 1
        }

        return passed ? 0 : 1
    }
}
