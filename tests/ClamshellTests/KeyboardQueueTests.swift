import XCTest
import CoreGraphics
@testable import Clamshell

final class KeyboardQueueTests: XCTestCase {
    private let lock = NSLock()
    private var log: [InputEvent] = []

    private func record(_ e: InputEvent) { lock.lock(); log.append(e); lock.unlock() }
    private func snapshot() -> [InputEvent] { lock.lock(); defer { lock.unlock() }; return log }

    private func makeCore() -> InputCore {
        InputCore(boundsProvider: { CGRect(x: 0, y: 0, width: 100, height: 100) },
                  displaysProvider: { [CGRect(x: 0, y: 0, width: 100, height: 100)] },
                  cursorProvider: { .zero },
                  clock: { 0 },
                  doubleClickInterval: { 0.5 })
    }

    func testTextThenKeyKeepsOrder() {
        let q = KeyboardQueue(delayMicros: 0, sink: record)
        let core = makeCore()
        XCTAssertEqual(q.enqueueText(core.text(Data("hi".utf8)), byteCount: 2), .accepted)
        q.enqueueKey(core.key(macKeyCode: 0, down: true, flags: 0))
        q.enqueueKey(core.key(macKeyCode: 0, down: false, flags: 0))
        q.drain()
        XCTAssertEqual(snapshot(), [
            .text("hi"),
            .key(code: 0, down: true, flags: 0),
            .key(code: 0, down: false, flags: 0),
        ])
    }

    func testReleaseAllDuringLongTextLeavesNoDownWithoutUp() {
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        var blocked = false
        let q = KeyboardQueue(delayMicros: 0) { [self] e in
            record(e)
            if case .key(0x24, true, _) = e, !blocked {
                blocked = true
                entered.signal()
                proceed.wait()
            }
        }
        let core = makeCore()
        q.enqueueKey(core.key(macKeyCode: 0, down: true, flags: 0)) // held, never released by the client
        let text = String(repeating: "x", count: 20) + "\n" + String(repeating: "y", count: 20) + "\n" + "tail"
        XCTAssertEqual(q.enqueueText(core.text(Data(text.utf8)), byteCount: text.utf8.count), .accepted)
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        // Now inside the Return press pair, after its down and before its up.
        q.releaseAll(core.releaseAll())
        proceed.signal()
        q.drain()

        let events = snapshot()
        XCTAssertEqual(events.first, .key(code: 0, down: true, flags: 0))
        XCTAssertEqual(events.last, .key(code: 0, down: false, flags: 0))
        // Return's up still follows its down; nothing of the second line or tail typed.
        XCTAssertEqual(events, [
            .key(code: 0, down: true, flags: 0),
            .text(String(repeating: "x", count: 20)),
            .key(code: 0x24, down: true, flags: 0),
            .key(code: 0x24, down: false, flags: 0),
            .key(code: 0, down: false, flags: 0),
        ])
    }

    func testQueuedKeysAreNeverAbandoned() {
        let q = KeyboardQueue(delayMicros: 0, sink: record)
        let core = makeCore()
        q.enqueueKey(core.key(macKeyCode: 5, down: true, flags: 0))
        q.releaseAll(core.releaseAll())
        q.enqueueKey(core.key(macKeyCode: 6, down: true, flags: 0))
        q.drain()
        XCTAssertEqual(snapshot(), [
            .key(code: 5, down: true, flags: 0),
            .key(code: 5, down: false, flags: 0),
            .key(code: 6, down: true, flags: 0),
        ])
    }

    func testBacklogCapDropsAndReportsFirstOnly() {
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        var blocked = false
        let q = KeyboardQueue(delayMicros: 0) { [self] e in
            record(e)
            if !blocked { blocked = true; entered.signal(); proceed.wait() }
        }
        let big = [InputEvent.text("a")]
        XCTAssertEqual(q.enqueueText(big, byteCount: KeyboardQueue.maxBacklogBytes), .accepted)
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(q.enqueueText(big, byteCount: 1), .dropped(first: true))
        XCTAssertEqual(q.enqueueText(big, byteCount: 1), .dropped(first: false))
        proceed.signal()
        q.drain()
        // Backlog drained: text is accepted again.
        XCTAssertEqual(q.enqueueText(big, byteCount: 1), .accepted)
        q.drain()
        XCTAssertEqual(snapshot().count, 2)
    }

    func testKeyCodeAboveFFIsDropped() {
        let core = makeCore()
        XCTAssertEqual(core.key(macKeyCode: 0x100, down: true, flags: 0), [])
        XCTAssertEqual(core.heldKeyCount, 0)
        XCTAssertEqual(core.key(macKeyCode: 0xFF, down: true, flags: 0).count, 1)
    }
}
