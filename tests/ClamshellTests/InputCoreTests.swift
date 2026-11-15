import XCTest
import CoreGraphics
@testable import Clamshell

final class InputCoreTests: XCTestCase {
    private var now: TimeInterval = 100
    private var cursor = CGPoint(x: 500, y: 400)
    private var displays = [CGRect(x: 0, y: 0, width: 1000, height: 800),
                            CGRect(x: 1000, y: 0, width: 500, height: 800)]
    private var bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)

    private func makeCore() -> InputCore {
        InputCore(boundsProvider: { self.bounds },
                  displaysProvider: { self.displays },
                  cursorProvider: { self.cursor },
                  clock: { self.now },
                  doubleClickInterval: { 0.5 })
    }

    private func texts(_ events: [InputEvent]) -> [String] {
        events.compactMap { if case let .text(s) = $0 { return s } else { return nil } }
    }

    func testNonFiniteDropped() {
        let c = makeCore()
        XCTAssertTrue(c.mouseMove(x: .nan, y: 0.5).isEmpty)
        XCTAssertTrue(c.mouseMove(x: 0.5, y: .infinity).isEmpty)
        XCTAssertTrue(c.mouseButton(button: 0, down: true, x: .nan, y: 0).isEmpty)
        XCTAssertTrue(c.mouseRelative(dx: .nan, dy: 1).isEmpty)
        XCTAssertTrue(c.mouseRelative(dx: 1, dy: -.infinity).isEmpty)
        XCTAssertEqual(c.heldButtonCount, 0)
    }

    func testMoveMapsAndClampsIntoBounds() {
        let c = makeCore()
        XCTAssertEqual(c.mouseMove(x: 0.5, y: 0.25),
                       [.mouse(.move, button: 0, point: CGPoint(x: 500, y: 200), clickCount: 0, delta: nil)])
        XCTAssertEqual(c.mouseMove(x: 3, y: -1),
                       [.mouse(.move, button: 0, point: CGPoint(x: 1000, y: 0), clickCount: 0, delta: nil)])
    }

    func testEveryButtonAndDropAboveFour() {
        let c = makeCore()
        for b in 0...4 {
            let down = c.mouseButton(button: UInt8(b), down: true, x: 0.5, y: 0.5)
            guard case let .mouse(.down, button, _, _, _) = down.first else { return XCTFail("button \(b)") }
            XCTAssertEqual(button, b)
            _ = c.mouseButton(button: UInt8(b), down: false, x: 0.5, y: 0.5)
        }
        XCTAssertTrue(c.mouseButton(button: 5, down: true, x: 0.5, y: 0.5).isEmpty)
        XCTAssertTrue(c.mouseButton(button: 255, down: true, x: 0.5, y: 0.5).isEmpty)
        XCTAssertEqual(c.heldButtonCount, 0)
    }

    func testDragWhileHeld() {
        let c = makeCore()
        _ = c.mouseButton(button: 1, down: true, x: 0.1, y: 0.1)
        guard case let .mouse(action, button, _, _, _) = c.mouseMove(x: 0.2, y: 0.2).first else { return XCTFail() }
        XCTAssertEqual(action, .drag)
        XCTAssertEqual(button, 1)
        _ = c.mouseButton(button: 1, down: false, x: 0.2, y: 0.2)
        guard case let .mouse(after, _, _, _, _) = c.mouseMove(x: 0.3, y: 0.3).first else { return XCTFail() }
        XCTAssertEqual(after, .move)
    }

    private func clickCount(_ events: [InputEvent]) -> Int? {
        if case let .mouse(_, _, _, n, _) = events.first { return n }
        return nil
    }

    func testClickCounting() {
        let c = makeCore()
        XCTAssertEqual(clickCount(c.mouseButton(button: 0, down: true, x: 0.5, y: 0.5)), 1)
        XCTAssertEqual(clickCount(c.mouseButton(button: 0, down: false, x: 0.5, y: 0.5)), 1)
        now += 0.3
        XCTAssertEqual(clickCount(c.mouseButton(button: 0, down: true, x: 0.5, y: 0.5)), 2)
        XCTAssertEqual(clickCount(c.mouseButton(button: 0, down: false, x: 0.5, y: 0.5)), 2)
        now += 0.3
        XCTAssertEqual(clickCount(c.mouseButton(button: 0, down: true, x: 0.5, y: 0.5)), 3)
        _ = c.mouseButton(button: 0, down: false, x: 0.5, y: 0.5)
        now += 0.6 // too slow
        XCTAssertEqual(clickCount(c.mouseButton(button: 0, down: true, x: 0.5, y: 0.5)), 1)
        _ = c.mouseButton(button: 0, down: false, x: 0.5, y: 0.5)
        now += 0.1 // different button
        XCTAssertEqual(clickCount(c.mouseButton(button: 1, down: true, x: 0.5, y: 0.5)), 1)
        _ = c.mouseButton(button: 1, down: false, x: 0.5, y: 0.5)
        now += 0.1 // too far (0.5 -> 0.6 of 1000 = 100 points)
        XCTAssertEqual(clickCount(c.mouseButton(button: 1, down: true, x: 0.6, y: 0.5)), 1)
        _ = c.mouseButton(button: 1, down: false, x: 0.6, y: 0.5)
        now += 0.1 // within 4 points (0.002 * 1000 = 2)
        XCTAssertEqual(clickCount(c.mouseButton(button: 1, down: true, x: 0.602, y: 0.5)), 2)
    }

    func testRelativeMoveAndClamp() {
        let c = makeCore()
        XCTAssertEqual(c.mouseRelative(dx: 10, dy: -20),
                       [.mouse(.move, button: 0, point: CGPoint(x: 510, y: 380), clickCount: 0,
                               delta: CGVector(dx: 10, dy: -20))])
        // Huge delta is clamped to 10000 then to the cursor's display.
        cursor = CGPoint(x: 900, y: 400)
        XCTAssertEqual(c.mouseRelative(dx: 1e9, dy: 0),
                       [.mouse(.move, button: 0, point: CGPoint(x: 999, y: 400), clickCount: 0,
                               delta: CGVector(dx: 10_000, dy: 0))])
        // Crossing into a neighbouring display is allowed.
        cursor = CGPoint(x: 990, y: 400)
        guard case let .mouse(_, _, p, _, _) = c.mouseRelative(dx: 50, dy: 0).first else { return XCTFail() }
        XCTAssertEqual(p, CGPoint(x: 1040, y: 400))
        // Off the top of the second display clamps to the second display.
        cursor = CGPoint(x: 1200, y: 5)
        guard case let .mouse(_, _, q, _, _) = c.mouseRelative(dx: 0, dy: -500).first else { return XCTFail() }
        XCTAssertEqual(q, CGPoint(x: 1200, y: 0))
    }

    func testRelativeDragWhileHeld() {
        let c = makeCore()
        _ = c.mouseButton(button: 0, down: true, x: 0.5, y: 0.5)
        guard case let .mouse(action, _, _, _, delta) = c.mouseRelative(dx: 1, dy: 2).first else { return XCTFail() }
        XCTAssertEqual(action, .drag)
        XCTAssertEqual(delta, CGVector(dx: 1, dy: 2))
    }

    func testTextChunking() {
        let c = makeCore()
        let long = String(repeating: "a", count: 45)
        XCTAssertEqual(texts(c.text(Data(long.utf8))).map { $0.utf16.count }, [20, 20, 5])
    }

    func testTextNeverSplitsSurrogatePair() {
        let c = makeCore()
        // 19 ASCII units then an emoji (2 units) would straddle the 20 limit.
        let s = String(repeating: "a", count: 19) + "😀" + "b"
        let chunks = texts(c.text(Data(s.utf8)))
        XCTAssertEqual(chunks, [String(repeating: "a", count: 19), "😀b"])
        XCTAssertTrue(chunks.allSatisfy { $0.utf16.count <= 20 })
        XCTAssertEqual(chunks.joined(), s)
    }

    func testTextControlCharacters() {
        let c = makeCore()
        let ret = [InputEvent.key(code: 0x24, down: true, flags: 0), .key(code: 0x24, down: false, flags: 0)]
        let tab = [InputEvent.key(code: 0x30, down: true, flags: 0), .key(code: 0x30, down: false, flags: 0)]
        XCTAssertEqual(c.text(Data("a\r\nb".utf8)), [.text("a")] + ret + [.text("b")])
        XCTAssertEqual(c.text(Data("a\nb".utf8)), [.text("a")] + ret + [.text("b")])
        XCTAssertEqual(c.text(Data("a\n\nb".utf8)).filter { $0 == ret[0] }.count, 2)
        XCTAssertEqual(c.text(Data("x\ty".utf8)), [.text("x")] + tab + [.text("y")])
        XCTAssertEqual(c.text(Data("a\u{1}b\u{7F}c\u{0}".utf8)), [.text("abc")])
    }

    func testTextOversizeAndInvalid() {
        let c = makeCore()
        XCTAssertTrue(c.text(Data(repeating: 0x61, count: 16 * 1024 + 1)).isEmpty)
        XCTAssertFalse(c.text(Data(repeating: 0x61, count: 16 * 1024)).isEmpty)
        XCTAssertTrue(c.text(Data([0x61, 0xFF, 0xFE])).isEmpty)
        XCTAssertTrue(c.text(Data()).isEmpty)
    }

    func testReleaseAll() {
        let c = makeCore()
        _ = c.mouseButton(button: 0, down: true, x: 0.5, y: 0.5)
        _ = c.mouseButton(button: 3, down: true, x: 0.5, y: 0.5)
        _ = c.key(macKeyCode: 55, down: true, flags: 0x100000)
        _ = c.key(macKeyCode: 8, down: true, flags: 0x100000)
        _ = c.key(macKeyCode: 8, down: false, flags: 0x100000)
        _ = c.mouseButton(button: 0, down: false, x: 0.5, y: 0.5)
        let rel = c.releaseAll()
        XCTAssertEqual(rel.count, 2)
        XCTAssertTrue(rel.contains(.key(code: 55, down: false, flags: 0)))
        XCTAssertTrue(rel.contains { if case .mouse(.up, 3, _, _, _) = $0 { return true } else { return false } })
        XCTAssertEqual(c.heldButtonCount, 0)
        XCTAssertEqual(c.heldKeyCount, 0)
        XCTAssertTrue(c.releaseAll().isEmpty)
    }
}
