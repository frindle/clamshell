import Foundation
import IOKit.pwr_mgt

/// The few power-assertion calls Clamshell makes, behind a seam so the
/// ownership rules in `DisplayAwakeGuard` can be tested without IOKit.
protocol PowerAssertionBackend {
    /// A "keep the display from idle-sleeping" assertion. nil on failure.
    func createDisplaySleepAssertion(reason: String) -> UInt32?
    /// Declares user activity (wakes a sleeping display). Passing the id from
    /// an earlier call reuses that assertion instead of making another.
    func declareUserActivity(reason: String, reusing id: UInt32) -> UInt32?
    func release(_ id: UInt32)
}

struct IOKitPowerAssertions: PowerAssertionBackend {
    func createDisplaySleepAssertion(reason: String) -> UInt32? {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        return result == kIOReturnSuccess ? id : nil
    }

    func declareUserActivity(reason: String, reusing id: UInt32) -> UInt32? {
        var assertionID: IOPMAssertionID = id
        let result = IOPMAssertionDeclareUserActivity(
            reason as CFString, kIOPMUserActiveLocal, &assertionID)
        return result == kIOReturnSuccess ? assertionID : nil
    }

    func release(_ id: UInt32) {
        IOPMAssertionRelease(id)
    }
}

/// The only owner of Clamshell's display-related power assertions: the one
/// that holds the display awake for a remote session, and the one-off
/// "user is active" declaration used to wake a sleeping display before
/// mirroring. Every release is safe to repeat, so each end-of-session path
/// can call `releaseAll()` without checking first.
///
/// Main thread only, like the coordinator that drives it. The kernel drops a
/// process's assertions when it exits, so nothing can outlive a crash or a
/// relaunch; there is nothing to clean up at launch.
final class DisplayAwakeGuard {
    private let backend: PowerAssertionBackend
    private var holdID: UInt32?
    private var wakeID: UInt32?

    init(backend: PowerAssertionBackend = IOKitPowerAssertions()) {
        self.backend = backend
    }

    var isHolding: Bool { holdID != nil }
    var isWakeDeclared: Bool { wakeID != nil }

    /// Keep the display awake. Returns whether the hold is in place; a second
    /// call while held creates nothing new.
    @discardableResult
    func hold(reason: String) -> Bool {
        if holdID != nil { return true }
        holdID = backend.createDisplaySleepAssertion(reason: reason)
        return holdID != nil
    }

    /// Wake a sleeping display. Repeated calls reuse one assertion.
    func wake(reason: String) {
        if let id = backend.declareUserActivity(reason: reason, reusing: wakeID ?? 0) {
            wakeID = id
        }
    }

    /// Returns true if something was actually released.
    @discardableResult
    func releaseHold() -> Bool {
        guard let id = holdID else { return false }
        holdID = nil
        backend.release(id)
        return true
    }

    @discardableResult
    func releaseWake() -> Bool {
        guard let id = wakeID else { return false }
        wakeID = nil
        backend.release(id)
        return true
    }

    /// Returns true if either assertion was released.
    @discardableResult
    func releaseAll() -> Bool {
        let hold = releaseHold()
        let wake = releaseWake()
        return hold || wake
    }
}
