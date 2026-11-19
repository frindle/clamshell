import XCTest
@testable import Clamshell

final class AudioStartGateTests: XCTestCase {
    func testFirstPacketTriesToStartThenRuns() {
        var g = AudioStartGate()
        XCTAssertEqual(g.decide(now: 0), .tryStart)
        g.recordStarted()
        XCTAssertEqual(g.decide(now: 0.02), .running)
    }

    func testFailedStartBacksOffInsteadOfRetryingPerPacket() {
        var g = AudioStartGate()
        XCTAssertEqual(g.decide(now: 100), .tryStart)
        _ = g.recordFailure(now: 100)
        // 47 packets a second for the next 0.4 s: none may try again.
        for i in 1...19 { XCTAssertEqual(g.decide(now: 100 + Double(i) * 0.021), .skip) }
        XCTAssertEqual(g.decide(now: 100.5), .tryStart)
    }

    func testBackoffDoublesAndIsCapped() {
        var g = AudioStartGate()
        var t = 0.0
        var waits: [Double] = []
        for _ in 0..<8 {
            XCTAssertEqual(g.decide(now: t), .tryStart)
            _ = g.recordFailure(now: t)
            var quarters = 0.0 // 0.25 is exact in binary, so no rounding drift
            while g.decide(now: t + quarters * 0.25) == .skip { quarters += 1 }
            waits.append(quarters * 0.25)
            t += quarters * 0.25
        }
        XCTAssertEqual(Array(waits.prefix(5)), [0.5, 1.0, 2.0, 4.0, 5.0])
        XCTAssertEqual(waits.last, 5.0)
    }

    func testFailureIsLoggedOncePerWindow() {
        var g = AudioStartGate()
        var logged = 0
        var lastHeld = -1
        // A failed start every 0.5 s .. 5 s apart for 25 s, as the back-off allows.
        var t = 0.0
        while t < 25 {
            if g.decide(now: t) == .tryStart, let held = g.recordFailure(now: t) { logged += 1; lastHeld = held }
            t += 0.05
        }
        XCTAssertLessThanOrEqual(logged, 3, "one line per 10 s window")
        XCTAssertGreaterThanOrEqual(logged, 2)
        XCTAssertGreaterThan(lastHeld, 0, "the line says how many were held back")
    }

    func testSuccessClearsTheBackoff() {
        var g = AudioStartGate()
        _ = g.recordFailure(now: 0)
        XCTAssertEqual(g.decide(now: 1), .tryStart)
        g.recordStarted()
        g.recordEngineStopped() // interruption
        XCTAssertEqual(g.decide(now: 1.01), .tryStart, "no leftover back-off after a success")
    }

    func testLatePacketAfterCloseCannotStartAudio() {
        var g = AudioStartGate()
        g.recordStarted()
        XCTAssertTrue(g.close(), "was started, so the engine needs stopping")
        XCTAssertEqual(g.decide(now: 10), .skip)
        XCTAssertEqual(g.decide(now: 1000), .skip, "still shut however long it waits")
        XCTAssertFalse(g.started)
    }

    func testOpenForTheNextSessionAllowsStartAgain() {
        var g = AudioStartGate()
        _ = g.recordFailure(now: 0)
        g.close()
        g.open()
        XCTAssertEqual(g.decide(now: 0.01), .tryStart, "a new session starts clean")
    }

    func testCloseWithoutStartReportsNothingToStop() {
        var g = AudioStartGate()
        XCTAssertFalse(g.close())
    }

    // Many threads hammering one gate under a lock, as AudioPlayer does: after close, no
    // thread is ever told to start.
    func testNoStartDecisionAfterCloseUnderContention() {
        var g = AudioStartGate()
        let lock = NSLock()
        var closed = false
        var startAfterClose = false
        let group = DispatchGroup()
        for _ in 0..<4 {
            DispatchQueue.global().async(group: group) {
                for i in 0..<2000 {
                    lock.lock()
                    if g.decide(now: Double(i)) == .tryStart {
                        if closed { startAfterClose = true }
                        g.recordStarted()
                    }
                    lock.unlock()
                }
            }
        }
        DispatchQueue.global().async(group: group) {
            lock.lock(); g.close(); closed = true; lock.unlock()
        }
        group.wait()
        XCTAssertFalse(startAfterClose)
    }
}
