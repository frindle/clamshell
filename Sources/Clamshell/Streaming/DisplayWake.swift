import Foundation
import IOKit.pwr_mgt

/// A remote session has to find the screen awake. With Screen Sharing gone,
/// nothing else wakes a Mac whose display went to sleep, so Clamshell does:
/// - when a trusted device connects, it declares user activity (wakes the
///   display);
/// - while any device is connected, it holds a "no display sleep" assertion,
///   and drops it when the last one leaves;
/// - when capture finds no display (it is still waking), it wakes it again
///   and retries a few times before giving up (`DisplayWakeRetry`).
protocol PowerAssertions {
    /// Wakes the display now. True when the system accepted it.
    func declareUserActivity(_ reason: String) -> Bool
    /// Starts holding the display awake. Returns an id for `release`, or nil.
    func holdDisplayAwake(_ reason: String) -> UInt32?
    func release(_ id: UInt32)
}

struct SystemPowerAssertions: PowerAssertions {
    func declareUserActivity(_ reason: String) -> Bool {
        var id: IOPMAssertionID = 0
        // Local activity is what wakes a sleeping display; the id is reused by
        // the system for repeated declarations with the same name.
        return IOPMAssertionDeclareUserActivity(reason as CFString, kIOPMUserActiveLocal, &id) == kIOReturnSuccess
    }

    func holdDisplayAwake(_ reason: String) -> UInt32? {
        var id: IOPMAssertionID = 0
        let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        return r == kIOReturnSuccess ? id : nil
    }

    func release(_ id: UInt32) { IOPMAssertionRelease(id) }
}

final class DisplayWake {
    static let shared = DisplayWake()

    private let power: PowerAssertions
    private let lock = NSLock()
    private var holders = Set<ObjectIdentifier>()
    private var assertion: UInt32?

    init(power: PowerAssertions = SystemPowerAssertions()) {
        self.power = power
    }

    var isHolding: Bool { lock.lock(); defer { lock.unlock() }; return assertion != nil }
    var holderCount: Int { lock.lock(); defer { lock.unlock() }; return holders.count }

    /// A trusted device connected: wake the display and keep it awake.
    func connected(_ who: AnyObject) {
        wake("Clamshell trusted device connected")
        lock.lock()
        defer { lock.unlock() }
        guard holders.insert(ObjectIdentifier(who)).inserted else { return }
        if assertion == nil {
            assertion = power.holdDisplayAwake("Clamshell remote session connected")
            clog("display-wake: holding the display awake for the connected device")
        }
    }

    /// The device left (or never finished joining). Safe to call twice.
    func disconnected(_ who: AnyObject) {
        lock.lock()
        defer { lock.unlock() }
        guard holders.remove(ObjectIdentifier(who)) != nil else { return }
        if holders.isEmpty, let id = assertion {
            power.release(id)
            assertion = nil
            clog("display-wake: released the display-awake hold")
        }
    }

    @discardableResult
    func wake(_ reason: String) -> Bool {
        let ok = power.declareUserActivity(reason)
        if !ok { clog("display-wake: could not declare user activity (\(reason))") }
        return ok
    }
}

enum DisplayWakeRetry {
    /// Waits between tries, after each of which the display is woken again.
    /// Roughly 7.5 seconds in all: a display normally comes back in 1 to 3.
    static let delays: [TimeInterval] = [0.5, 1, 2, 4]

    /// Runs `attempt`; when it finds nothing (nil), wakes the display, waits
    /// and tries again, once per entry of `delays`. Errors are not retried.
    static func run<T>(delays: [TimeInterval] = DisplayWakeRetry.delays,
                       wake: () -> Void,
                       sleep: (TimeInterval) async -> Void,
                       attempt: () async throws -> T?) async throws -> T? {
        if let found = try await attempt() { return found }
        for delay in delays {
            wake()
            await sleep(delay)
            if let found = try await attempt() { return found }
        }
        return nil
    }
}
