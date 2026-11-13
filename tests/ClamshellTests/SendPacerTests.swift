import XCTest
@testable import Clamshell

final class SendPacerTests: XCTestCase {
    private func filled(_ pacer: inout SendPacer, to count: Int, at now: TimeInterval) {
        XCTAssertEqual(pacer.offer(keyframe: true, now: now), .send)
        while pacer.inFlight < count {
            XCTAssertEqual(pacer.offer(keyframe: false, now: now), .send)
        }
    }

    func testSendsFreelyBelowTheLimit() {
        var p = SendPacer(softLimit: 3, hardLimit: 5)
        XCTAssertEqual(p.offer(keyframe: true, now: 0), .send)
        XCTAssertEqual(p.offer(keyframe: false, now: 0.01), .send)
        p.completed(now: 0.02)
        p.completed(now: 0.03)
        XCTAssertEqual(p.inFlight, 0)
        XCTAssertEqual(p.offer(keyframe: false, now: 0.04), .send)
    }

    func testFullQueueDropsDeltaAndRequestsKeyframeOnce() {
        var p = SendPacer(softLimit: 3, hardLimit: 5)
        filled(&p, to: 3, at: 0)
        XCTAssertEqual(p.offer(keyframe: false, now: 0.1), .drop(requestKeyframe: true, congested: true))
        XCTAssertTrue(p.awaitingKeyframe)
        // Frames already inside the encoder must not each ask for another keyframe.
        XCTAssertEqual(p.offer(keyframe: false, now: 0.2), .drop(requestKeyframe: false, congested: true))
        XCTAssertEqual(p.inFlight, 3)
    }

    /// The regression this type exists for: once a delta is dropped, later
    /// deltas refer to a frame the client never got, even if the queue drained.
    func testDeltasStayDroppedUntilAKeyframeIsSent() {
        var p = SendPacer(softLimit: 3, hardLimit: 5)
        filled(&p, to: 3, at: 0)
        XCTAssertEqual(p.offer(keyframe: false, now: 0.1), .drop(requestKeyframe: true, congested: true))
        p.completed(now: 0.2); p.completed(now: 0.2); p.completed(now: 0.2)
        XCTAssertEqual(p.offer(keyframe: false, now: 0.3), .drop(requestKeyframe: false, congested: false))
        XCTAssertEqual(p.offer(keyframe: true, now: 0.4), .send)
        XCTAssertFalse(p.awaitingKeyframe)
        XCTAssertEqual(p.offer(keyframe: false, now: 0.5), .send)
    }

    func testKeyframeIsRequestedAgainIfItNeverArrives() {
        var p = SendPacer(softLimit: 2, hardLimit: 4, keyframeRetry: 1)
        filled(&p, to: 2, at: 0)
        XCTAssertEqual(p.offer(keyframe: false, now: 0.1), .drop(requestKeyframe: true, congested: true))
        p.completed(now: 0.2); p.completed(now: 0.2)
        XCTAssertEqual(p.offer(keyframe: false, now: 0.5), .drop(requestKeyframe: false, congested: false))
        XCTAssertEqual(p.offer(keyframe: false, now: 1.2), .drop(requestKeyframe: true, congested: false))
    }

    func testKeyframesPassTheSoftLimitButNotTheHardLimit() {
        var p = SendPacer(softLimit: 2, hardLimit: 4)
        filled(&p, to: 2, at: 0)
        XCTAssertEqual(p.offer(keyframe: true, now: 0.1), .send)
        XCTAssertEqual(p.offer(keyframe: true, now: 0.2), .send)
        XCTAssertEqual(p.inFlight, 4)
        XCTAssertEqual(p.offer(keyframe: true, now: 0.3), .drop(requestKeyframe: true, congested: true))
        XCTAssertEqual(p.inFlight, 4, "a stuck connection must not queue without bound")
        XCTAssertTrue(p.awaitingKeyframe)
    }

    func testStallIsReportedOnlyWhenNothingCompletes() {
        var p = SendPacer(softLimit: 2, hardLimit: 4, stallTimeout: 10)
        filled(&p, to: 2, at: 0)
        XCTAssertEqual(p.offer(keyframe: false, now: 9.9), .drop(requestKeyframe: true, congested: true))
        XCTAssertEqual(p.offer(keyframe: false, now: 10), .stalled)

        // Slow but moving: each completion restarts the clock.
        var q = SendPacer(softLimit: 2, hardLimit: 4, stallTimeout: 10)
        filled(&q, to: 2, at: 0)
        q.completed(now: 9)
        XCTAssertEqual(q.offer(keyframe: false, now: 18), .send)
    }

    /// A screen that doesn't change produces no frames; that is not a stall.
    func testIdleGapWithEmptyQueueIsNotAStall() {
        var p = SendPacer(stallTimeout: 10)
        XCTAssertEqual(p.offer(keyframe: true, now: 0), .send)
        p.completed(now: 0.1)
        XCTAssertEqual(p.offer(keyframe: false, now: 500), .send)
    }

    func testCompletionsNeverGoNegativeAndResetClears() {
        var p = SendPacer(softLimit: 1, hardLimit: 2)
        p.completed(now: 0)
        XCTAssertEqual(p.inFlight, 0)
        XCTAssertEqual(p.offer(keyframe: true, now: 0), .send)
        XCTAssertEqual(p.offer(keyframe: false, now: 0), .drop(requestKeyframe: true, congested: true))
        p.reset()
        XCTAssertEqual(p.inFlight, 0)
        XCTAssertFalse(p.awaitingKeyframe)
        XCTAssertEqual(p.offer(keyframe: false, now: 100), .send)
    }
}
