import XCTest
import CoreGraphics
@testable import Clamshell

final class InputQueueTests: XCTestCase {
    private let lock = NSLock()
    private var log: [InputEvent] = []
    private var drops = 0
    private let entered = DispatchSemaphore(value: 0)
    private let proceed = DispatchSemaphore(value: 0)
    private var blockOn: ((InputEvent) -> Bool)?
    private var didBlock = false

    private let here = CGPoint(x: 7, y: 9)

    private func makeQueue() -> InputQueue {
        InputQueue(delayMicros: 0, cursor: { self.here }, onFirstDrop: { self.drops += 1 }) { [self] e in
            lock.lock(); log.append(e); lock.unlock()
            if !didBlock, let match = blockOn, match(e) {
                didBlock = true
                entered.signal()
                proceed.wait()
            }
        }
    }

    private func snapshot() -> [InputEvent] { lock.lock(); defer { lock.unlock() }; return log }

    private func down(_ b: Int) -> InputEvent { .mouse(.down, button: b, point: .zero, clickCount: 1, delta: nil) }
    private func up(_ b: Int) -> InputEvent { .mouse(.up, button: b, point: .zero, clickCount: 1, delta: nil) }
    private func move() -> InputEvent { .mouse(.move, button: 0, point: .zero, clickCount: 0, delta: nil) }
    private func kd(_ c: UInt16) -> InputEvent { .key(code: c, down: true, flags: 0) }
    private func ku(_ c: UInt16) -> InputEvent { .key(code: c, down: false, flags: 0) }

    func testKeyThenMouseKeepOrder() {
        let q = makeQueue()
        q.enqueue([kd(55)])
        q.enqueue([down(0)])
        q.enqueue([up(0)])
        q.enqueue([ku(55)])
        InputQueue.drain()
        XCTAssertEqual(snapshot(), [kd(55), down(0), up(0), ku(55)])
    }

    func testClickAfterTextPostsAfterAllOfIt() {
        let q = makeQueue()
        q.enqueue([.text("a"), kd(0x24), ku(0x24), .text("b")], textBytes: 3)
        q.enqueue([down(0)])
        InputQueue.drain()
        XCTAssertEqual(snapshot(), [.text("a"), kd(0x24), ku(0x24), .text("b"), down(0)])
    }

    func testBacklogBoundDropsNewButAcceptsReleases() {
        blockOn = { _ in true }
        let q = makeQueue()
        XCTAssertTrue(q.enqueue(Array(repeating: move(), count: InputQueue.maxBacklogEvents)))
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)

        XCTAssertFalse(q.hasRoom())
        XCTAssertEqual(drops, 1)
        XCTAssertFalse(q.hasRoom())
        XCTAssertEqual(drops, 1) // logged once
        XCTAssertFalse(q.enqueue([down(0)]))
        XCTAssertFalse(q.enqueue([move()]))
        XCTAssertFalse(q.enqueue([.scroll(dx: 1, dy: 1)]))
        XCTAssertFalse(q.enqueue([.text("x")], textBytes: 1))
        XCTAssertFalse(q.enqueue([kd(1)]))
        XCTAssertTrue(q.enqueue([up(0)]))
        XCTAssertTrue(q.enqueue([ku(1)]))

        proceed.signal()
        InputQueue.drain()
        XCTAssertEqual(snapshot().count, InputQueue.maxBacklogEvents + 2)
        XCTAssertTrue(q.hasRoom()) // drained
    }

    func testTextByteBound() {
        blockOn = { _ in true }
        let q = makeQueue()
        XCTAssertTrue(q.enqueue([.text("a")], textBytes: InputQueue.maxBacklogTextBytes))
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        XCTAssertFalse(q.hasRoom(textBytes: 1))
        XCTAssertFalse(q.enqueue([.text("b")], textBytes: 1))
        XCTAssertTrue(q.hasRoom()) // non-text events still fit
        proceed.signal()
        InputQueue.drain()
        XCTAssertTrue(q.hasRoom(textBytes: 1))
    }

    func testReleaseAllDuringLongTextWithQueuedClicks() {
        blockOn = { if case .key(0x24, true, _) = $0 { return true } else { return false } }
        let q = makeQueue()
        q.enqueue([kd(0)])
        q.enqueue([down(0)])
        q.enqueue([.text("xxxx"), kd(0x24), ku(0x24), .text("tail")], textBytes: 12)
        q.enqueue([down(1)])
        q.enqueue([up(1)])
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        // Mid-text, right after Return's down was posted.
        q.releaseAll()
        proceed.signal()
        InputQueue.drain()

        let events = snapshot()
        XCTAssertEqual(events, [
            kd(0), down(0), .text("xxxx"), kd(0x24),
            // release job: mouse ups at the cursor, then key ups
            .mouse(.up, button: 0, point: here, clickCount: 1, delta: nil), ku(0x24), ku(0),
        ])

        // Nothing is posted afterwards.
        XCTAssertFalse(q.enqueue([down(0)]))
        XCTAssertFalse(q.enqueue([ku(0)]))
        XCTAssertFalse(q.hasRoom())
        InputQueue.drain()
        XCTAssertEqual(snapshot(), events)
    }

    func testAbandonedDownGetsNoUp() {
        blockOn = { if case .mouse(.move, _, _, _, _) = $0 { return true } else { return false } }
        let q = makeQueue()
        q.enqueue([move()])
        q.enqueue([kd(11)])
        q.enqueue([down(2)])
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        q.releaseAll()
        proceed.signal()
        InputQueue.drain()
        XCTAssertEqual(snapshot(), [move()]) // no B down, no click, no ups for them
    }

    func testReleaseAllTwiceIsHarmless() {
        let q = makeQueue()
        q.enqueue([kd(5)])
        q.releaseAll()
        q.releaseAll()
        InputQueue.drain()
        XCTAssertEqual(snapshot(), [kd(5), ku(5)])
    }
}
