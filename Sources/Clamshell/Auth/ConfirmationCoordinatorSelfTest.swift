import Foundation
import CryptoKit

/// Exercises the state machine the confirmation panel and the status-item
/// icon read from — `clamshell confirmation-coordinator-selftest`.
///
/// Scope, deliberately: this covers the *transitions and timing*, using a
/// software key for the one case that needs a valid signature, because the
/// question here is "does the UI get told the right thing at the right
/// time". It says nothing about whether a YubiKey works — that is
/// `confirmation-yubikey-selftest` and the "Test YubiKey Confirmation…"
/// menu item, both of which refuse to fake a pass without real hardware.
enum ConfirmationCoordinatorSelfTest {
    static func run() -> Int32 {
        var passed = true
        func check(_ ok: Bool, _ what: String) {
            print(ok ? "PASS: \(what)" : "FAILED: \(what)")
            if !ok { passed = false }
        }

        let clientId = "coordinator-selftest"
        let key = P256.Signing.PrivateKey()

        // --- A challenge goes live and starts a clock the panel can show ---
        let coordinator = ConfirmationCoordinator()
        var transitions: [ConfirmationCoordinator.State] = []
        coordinator.onChange = { transitions.append($0) }
        coordinator.enroll(clientId: clientId, publicKey: key.publicKey.rawRepresentation)

        check(!coordinator.isPending, "idle coordinator reports nothing pending")

        let nonce = coordinator.begin(action: "test-confirmation", clientId: clientId)
        check(nonce.count == 32, "begin() returns a 32-byte nonce")
        check(coordinator.state == .awaitingTouch, "begin() moves to awaitingTouch")
        check(coordinator.isPending, "a live challenge reports pending (drives the icon)")
        check(coordinator.actionName == "test-confirmation", "action name is exposed for the panel")
        let remaining = coordinator.secondsRemaining ?? 0
        check(remaining > 29 && remaining <= ConfirmationBridge.nonceTTL,
              "countdown starts just under the bridge's own TTL (\(String(format: "%.1f", remaining))s)")

        // --- A good signature approves, via a visible verifying state ---
        guard let good = try? key.signature(for: nonce).derRepresentation else {
            print("FAILED: could not produce a test signature")
            return 1
        }
        coordinator.submit(signature: good)
        check(coordinator.state == .approved, "a valid signature approves")
        check(coordinator.isTerminal && !coordinator.isPending,
              "approved is terminal and clears pending (icon reverts)")
        check(transitions.contains(.verifying),
              "the panel is told about verifying before the result lands")

        // --- A bad signature rejects rather than hanging ---
        let rejecting = ConfirmationCoordinator()
        rejecting.enroll(clientId: clientId, publicKey: key.publicKey.rawRepresentation)
        _ = rejecting.begin(action: "test-confirmation", clientId: clientId)
        rejecting.submit(signature: Data([0xDE, 0xAD, 0xBE, 0xEF]))
        if case .rejected = rejecting.state {
            check(true, "a malformed signature rejects")
        } else {
            check(false, "a malformed signature rejects (got \(rejecting.state))")
        }
        check(!rejecting.isPending, "rejected clears pending")

        // --- A card/transport error surfaces as a rejection, not a hang ---
        let failing = ConfirmationCoordinator()
        failing.enroll(clientId: clientId, publicKey: key.publicKey.rawRepresentation)
        _ = failing.begin(action: "test-confirmation", clientId: clientId)
        failing.fail("no smart-card reader/slot found")
        if case .rejected(let why) = failing.state, why.contains("smart-card") {
            check(true, "a card error is surfaced verbatim to the panel")
        } else {
            check(false, "a card error is surfaced verbatim to the panel (got \(failing.state))")
        }

        // --- Nobody touches the key: the challenge expires on its own ---
        // The real TTL, on the real timer, spinning the real run loop — the
        // point is that the icon clears with no panel open and nothing
        // driving it.
        let expiring = ConfirmationCoordinator()
        expiring.enroll(clientId: clientId, publicKey: key.publicKey.rawRepresentation)
        _ = expiring.begin(action: "test-confirmation", clientId: clientId)
        print("Waiting \(Int(ConfirmationBridge.nonceTTL) + 1)s for the challenge to expire on its own...")
        RunLoop.current.run(until: Date().addingTimeInterval(ConfirmationBridge.nonceTTL + 1))
        check(expiring.state == .expired, "an unanswered challenge expires by itself")
        check(!expiring.isPending, "expired clears pending (icon reverts with no panel open)")
        check((expiring.secondsRemaining ?? -1) == 0, "countdown floors at zero rather than going negative")

        print("")
        print("Note: state machine only. The hardware leg is "
              + "confirmation-yubikey-selftest / the Test YubiKey Confirmation… menu item.")
        return passed ? 0 : 1
    }
}
