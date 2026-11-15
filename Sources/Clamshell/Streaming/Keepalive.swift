import Foundation

// Decides when a quiet client should send PING (PROTOCOL.md, type 0x07): after
// `idleInterval` of sending nothing. Pure and clock-free so it can be tested;
// the caller supplies timestamps and owns the timer and any locking.

struct KeepaliveGate {
    static let defaultIdleInterval: TimeInterval = 20

    let idleInterval: TimeInterval
    private var lastSent: TimeInterval

    init(now: TimeInterval, idleInterval: TimeInterval = KeepaliveGate.defaultIdleInterval) {
        self.idleInterval = idleInterval
        self.lastSent = now
    }

    /// Call for every message sent (a ping counts, so pings repeat at the interval).
    mutating func noteSent(at now: TimeInterval) { lastSent = now }

    /// True when nothing has been sent for at least the idle interval. A clock
    /// that went backwards never triggers a ping.
    func shouldPing(at now: TimeInterval) -> Bool {
        now - lastSent >= idleInterval
    }
}
