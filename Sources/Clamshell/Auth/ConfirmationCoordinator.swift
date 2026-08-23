import Foundation

/// Live state for one pending confirmation, sitting between
/// `ConfirmationBridge` (the crypto) and the menu-bar UI (the panel and the
/// status-item icon).
///
/// The point of the split is that the UI never learns *who* asked. Today the
/// only caller is the "Test YubiKey Confirmation…" menu item, which drives
/// `runYubiKeyTest` against a real card. When the challenge/response finally
/// rides the WebSocket (PROTOCOL.md: "no message types are assigned yet"),
/// that handler calls `begin(action:clientId:)` to get a nonce to send and
/// `submit(signature:)` when the client answers — the same two calls the
/// test path makes — and the panel and icon react identically with no UI
/// change.
///
/// Main-thread only, like the rest of the AppKit layer: `begin`, `submit`
/// and `enroll` all touch the bridge and the timer, and `onChange` fires
/// where the UI can act on it directly. The card I/O in `runYubiKeyTest` is
/// the only part that leaves the main thread.
final class ConfirmationCoordinator {
    enum State: Equatable {
        /// Reading the key's public key off the card. No challenge yet, so
        /// no clock is running.
        case connecting
        /// Challenge issued, expiry clock running, waiting for a signature.
        case awaitingTouch
        /// Signature in hand, checking it against the enrolled public key.
        case verifying
        case approved
        case rejected(String)
        case expired
        case idle
    }

    private let bridge = ConfirmationBridge()
    private var actionId: UUID?
    private var expiryTimer: Timer?

    private(set) var state: State = .idle
    /// The action being confirmed, e.g. "test-confirmation". Kept after a
    /// terminal state so the panel can still name what was decided.
    private(set) var actionName: String?
    /// When the issued nonce dies. Nil until a challenge is actually issued.
    private(set) var deadline: Date?

    /// Fired on every state change (not on countdown ticks — the panel runs
    /// its own refresh timer for those, like DiagnosticsWindowController).
    var onChange: ((State) -> Void)?

    var isPending: Bool {
        switch state {
        case .connecting, .awaitingTouch, .verifying: return true
        case .idle, .approved, .rejected, .expired: return false
        }
    }

    var isTerminal: Bool {
        switch state {
        case .approved, .rejected, .expired: return true
        case .idle, .connecting, .awaitingTouch, .verifying: return false
        }
    }

    /// Seconds left on the current challenge, or nil before one is issued.
    var secondsRemaining: TimeInterval? {
        guard let deadline else { return nil }
        return max(0, deadline.timeIntervalSinceNow)
    }

    /// Enrolls a client's P-256 public key (raw 64-byte x||y). The wire path
    /// will call this once per paired client; the test path enrolls the
    /// plugged-in card each run.
    func enroll(clientId: String, publicKey: Data) {
        bridge.enroll(clientId: clientId, publicKey: publicKey)
    }

    /// Issues a challenge for `action` and starts the expiry clock. Returns
    /// the 32-byte nonce to hand to whoever is signing.
    @discardableResult
    func begin(action: String, clientId: String) -> Data {
        let id = UUID()
        actionId = id
        actionName = action
        // Recorded just *before* the bridge stamps its own expiry, so the
        // countdown can only ever be pessimistic — the UI never offers time
        // the bridge has already written off.
        let ownDeadline = Date().addingTimeInterval(ConfirmationBridge.nonceTTL)
        let nonce = bridge.requestConfirmation(actionId: id, clientId: clientId)
        deadline = ownDeadline
        clog("confirmation challenge issued for \"\(action)\" (client \(clientId))")
        setState(.awaitingTouch)
        startExpiryTimer()
        return nonce
    }

    /// Verifies a signature against the pending challenge and settles the
    /// state. Safe to call late — a signature that arrives after expiry is
    /// rejected by the bridge and reported as expired here.
    func submit(signature: Data) {
        guard let id = actionId, isPending else { return }
        setState(.verifying)
        if bridge.verifyConfirmation(actionId: id, signature: signature) {
            clog("confirmation approved for \"\(actionName ?? "?")\"")
            finish(.approved)
        } else {
            // The bridge returns a bare false for both "bad signature" and
            // "too late"; the deadline recorded above is what tells them
            // apart for the user.
            let expired = (secondsRemaining ?? 0) <= 0
            clog("confirmation \(expired ? "expired" : "rejected") for \"\(actionName ?? "?")\"")
            finish(expired ? .expired : .rejected("signature did not verify"))
        }
    }

    /// Abandons a pending confirmation (card error, user cancel).
    func fail(_ reason: String) {
        guard isPending else { return }
        clog("confirmation failed for \"\(actionName ?? "?")\": \(reason)")
        finish(.rejected(reason))
    }

    // MARK: - Local hardware test path

    /// Drives the whole loop against the real plugged-in YubiKey: read the
    /// slot-9a public key, enroll it, issue a challenge, sign it on the card
    /// (blocking on the touch), verify. No mock signer anywhere — a pass
    /// here means the crypto and the hardware both worked.
    ///
    /// This is the stand-in for a remote trigger until the wire path exists;
    /// everything after `begin` is identical to what that path will do.
    func runYubiKeyTest(action: String, clientId: String = "yubikey-local-test",
                        pin: @escaping () throws -> String) {
        guard !isPending else { return }
        reset()
        actionName = action
        setState(.connecting)

        Task { @MainActor [weak self] in
            do {
                // Nonisolated async, so the card I/O runs off the main
                // thread and the menu bar stays responsive while the user
                // is reaching for the key.
                let publicKey = try await YubiKeyConfirmation.publicKey()
                guard let self, self.state == .connecting else { return }
                self.enroll(clientId: clientId, publicKey: publicKey)
                let nonce = self.begin(action: action, clientId: clientId)
                // Blocks on the card until the slot's touch policy is
                // satisfied — this is the 30 s the countdown is measuring.
                let signature = try await YubiKeyConfirmation.signNonce(nonce, pin: pin)
                self.submit(signature: signature)
            } catch {
                self?.fail("\(error)")
            }
        }
    }

    // MARK: - Internals

    private func reset() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        actionId = nil
        actionName = nil
        deadline = nil
        state = .idle
    }

    private func setState(_ new: State) {
        guard state != new else { return }
        state = new
        onChange?(new)
    }

    private func finish(_ new: State) {
        expiryTimer?.invalidate()
        expiryTimer = nil
        setState(new)
    }

    /// Enforces the deadline even when the panel is closed, so a challenge
    /// nobody answers still clears the status-item icon on its own.
    private func startExpiryTimer() {
        expiryTimer?.invalidate()
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.isPending, (self.secondsRemaining ?? 0) <= 0 else { return }
            clog("confirmation expired for \"\(self.actionName ?? "?")\" (no signature within \(Int(ConfirmationBridge.nonceTTL))s)")
            self.finish(.expired)
        }
    }
}
