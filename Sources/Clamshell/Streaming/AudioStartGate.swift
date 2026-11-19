import Foundation

// The decisions behind starting the iPad's audio engine, kept free of AVFoundation
// so they can be tested. The owner (AudioPlayer) holds one lock around every use of
// this value and around every engine start and stop, so nothing here locks itself.
//
// Two things it settles:
//  * A failing engine start (a phone call holding the audio session) must not be
//    retried, or logged, on every AUDIO_FRAME (about 47 a second). Retries back off
//    (0.5 s, doubling to 5 s) and the failure is logged once per window.
//  * A packet that was already being handled when the connection closed must not
//    start the engine again. `close()` shuts the gate; only `open()` (the next
//    session's HELLO_ACK) reopens it.

struct AudioStartGate {
    enum Decision: Equatable {
        case skip          // closed, or backing off after a failure
        case running       // already started; nothing to do
        case tryStart      // call engine.start() now, then report the outcome
    }

    static let firstBackoff: TimeInterval = 0.5
    static let maxBackoff: TimeInterval = 5
    /// At most one failure log line per window.
    static let logWindow: TimeInterval = 10

    private(set) var isOpen = true
    private(set) var started = false
    private(set) var failures = 0
    private var retryAt: TimeInterval = 0
    private var lastLogAt: TimeInterval?
    private var suppressed = 0

    /// A new session begins: audio may start again.
    mutating func open() {
        isOpen = true
        failures = 0
        retryAt = 0
        lastLogAt = nil
        suppressed = 0
    }

    /// The session ended. Returns whether the engine was started and so needs stopping.
    @discardableResult
    mutating func close() -> Bool {
        let wasStarted = started
        isOpen = false
        started = false
        return wasStarted
    }

    /// Asked once per packet.
    mutating func decide(now: TimeInterval) -> Decision {
        guard isOpen else { return .skip }
        if started { return .running }
        return now >= retryAt ? .tryStart : .skip
    }

    mutating func recordStarted() {
        started = true
        failures = 0
        retryAt = 0
    }

    /// The engine stopped under us (interruption, route change); the next packet restarts it.
    mutating func recordEngineStopped() { started = false }

    /// A start failed. Returns the number of failures held back since the last log line
    /// when this one should be logged (0 for the first), or nil when it should stay quiet.
    mutating func recordFailure(now: TimeInterval) -> Int? {
        started = false
        failures += 1
        let wait = min(Self.firstBackoff * pow(2, Double(failures - 1)), Self.maxBackoff)
        retryAt = now + wait
        if let last = lastLogAt, now - last < Self.logWindow {
            suppressed += 1
            return nil
        }
        lastLogAt = now
        let held = suppressed
        suppressed = 0
        return held
    }
}
