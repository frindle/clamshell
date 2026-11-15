import XCTest
@testable import Clamshell

final class ShortcutsTests: XCTestCase {
    func testPlainKeyIsDownUpWithNoFlags() {
        XCTAssertEqual(ShortcutKeys.strokes(key: 53, modifiers: []), [
            KeyStroke(code: 53, down: true, flags: 0),
            KeyStroke(code: 53, down: false, flags: 0),
        ])
    }

    func testCmdTabSequence() {
        XCTAssertEqual(ShortcutKeys.strokes(Shortcut.presets[1]), [
            KeyStroke(code: 55, down: true, flags: 0x10_0000),
            KeyStroke(code: 48, down: true, flags: 0x10_0000),
            KeyStroke(code: 48, down: false, flags: 0x10_0000),
            KeyStroke(code: 55, down: false, flags: 0),
        ])
    }

    func testCmdOptionEscFlagsAccumulateAndRelease() {
        let s = ShortcutKeys.strokes(key: 53, modifiers: [.command, .option])
        XCTAssertEqual(s, [
            KeyStroke(code: 55, down: true, flags: 0x10_0000),
            KeyStroke(code: 58, down: true, flags: 0x18_0000),
            KeyStroke(code: 53, down: true, flags: 0x18_0000),
            KeyStroke(code: 53, down: false, flags: 0x18_0000),
            KeyStroke(code: 58, down: false, flags: 0x10_0000),
            KeyStroke(code: 55, down: false, flags: 0),
        ])
    }

    func testEveryDownHasItsUp() {
        for p in Shortcut.presets {
            for extra in [ShortcutModifiers(), .shift, [.shift, .control, .command, .option]] {
                var held = Set<UInt16>()
                for k in ShortcutKeys.strokes(p, extra: extra) {
                    if k.down { held.insert(k.code) } else { XCTAssertNotNil(held.remove(k.code)) }
                }
                XCTAssertTrue(held.isEmpty, p.title)
            }
        }
    }

    func testStickyAppliesToNextShortcutOnly() {
        var sticky = StickyModifiers()
        sticky.toggle(.shift)
        sticky.toggle(.control)
        sticky.toggle(.control) // toggled off again
        let mods = sticky.consume()
        XCTAssertEqual(mods, .shift)
        XCTAssertEqual(sticky.consume(), [])
        let s = ShortcutKeys.strokes(Shortcut.presets[0], extra: mods)
        XCTAssertEqual(s.first, KeyStroke(code: 56, down: true, flags: 0x2_0000))
        XCTAssertEqual(s.last, KeyStroke(code: 56, down: false, flags: 0))
    }

    func testPresetsCoverTheCombosIPadOSKeeps() {
        let titles = Shortcut.presets.map(\.title)
        for t in ["Esc", "Cmd-Tab", "Cmd-Space", "Cmd-H", "Cmd-Q", "Cmd-Opt-Esc", "Ctrl-Left", "Ctrl-Right", "Ctrl-Up", "Ctrl-Down"] {
            XCTAssertTrue(titles.contains(t), t)
        }
    }
}
