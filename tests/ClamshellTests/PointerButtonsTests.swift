import XCTest
@testable import Clamshell

final class PointerButtonsTests: XCTestCase {
    func testLeftAndRightUnchanged() {
        for extra in [false, true] {
            XCTAssertEqual(PointerButtons.button(forMask: 0b1, extraButtons: extra), 0)
            XCTAssertEqual(PointerButtons.button(forMask: 0b10, extraButtons: extra), 1)
            XCTAssertEqual(PointerButtons.button(forMask: 0b11, extraButtons: extra), 1)
            XCTAssertEqual(PointerButtons.button(forMask: 0, extraButtons: extra), 0)
        }
    }

    func testExtraButtonsOnlyWithCapability() {
        XCTAssertEqual(PointerButtons.button(forMask: 1 << 2, extraButtons: true), 2)
        XCTAssertEqual(PointerButtons.button(forMask: 1 << 3, extraButtons: true), 3)
        XCTAssertEqual(PointerButtons.button(forMask: 1 << 4, extraButtons: true), 4)
        for bit in 2...4 {
            XCTAssertEqual(PointerButtons.button(forMask: 1 << bit, extraButtons: false), 0)
        }
        XCTAssertEqual(PointerButtons.button(forMask: 1 << 5, extraButtons: true), 0)
    }

    func testRelativeDelta() {
        let d = PointerButtons.relativeDelta(dx: 3, dy: 2)
        XCTAssertEqual(d?.dx, 3)
        XCTAssertEqual(d?.dy, -2)
        XCTAssertNil(PointerButtons.relativeDelta(dx: 0, dy: 0))
        XCTAssertNil(PointerButtons.relativeDelta(dx: .nan, dy: 1))
        XCTAssertNil(PointerButtons.relativeDelta(dx: 1, dy: .infinity))
    }
}
