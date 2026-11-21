import Foundation
import CoreGraphics

/// Where an RFB client's keyboard and pointer go. The real one is the same
/// injector the stream uses; tests record the calls.
protocol RFBInputSink: AnyObject {
    /// Positions are 0...1 across the captured display, origin top left.
    func mouseMove(x: Float, y: Float)
    func mouseButton(button: UInt8, down: Bool, x: Float, y: Float)
    func scroll(dx: Float, dy: Float)
    func key(code: UInt16, down: Bool, flags: UInt64)
    func text(_ string: String)
    func releaseAll()
}

/// The injector the stream server uses, behind the RFB sink interface. It
/// posts through the same CGEvent path, which also types at the login window
/// when this process is the login-window agent.
final class InjectorInputSink: RFBInputSink {
    private let injector: InputInjector
    init(displayID: CGDirectDisplayID) { injector = InputInjector(displayID: displayID) }
    func mouseMove(x: Float, y: Float) { injector.mouseMove(x: x, y: y) }
    func mouseButton(button: UInt8, down: Bool, x: Float, y: Float) {
        injector.mouseButton(button: button, down: down, x: x, y: y)
    }
    func scroll(dx: Float, dy: Float) { injector.scroll(dx: dx, dy: dy) }
    func key(code: UInt16, down: Bool, flags: UInt64) { injector.key(macKeyCode: code, down: down, flags: flags) }
    func text(_ string: String) { injector.text(Data(string.utf8)) }
    func releaseAll() { injector.releaseAll() }
}

/// Turns X11 keysyms (what RFB sends) into Mac key events.
final class RFBKeyboard {
    static let shiftFlag: UInt64 = 0x20000
    static let controlFlag: UInt64 = 0x40000
    static let optionFlag: UInt64 = 0x80000
    static let commandFlag: UInt64 = 0x100000

    private static let modifiers: [UInt32: (code: UInt16, flag: UInt64)] = [
        0xFFE1: (0x38, shiftFlag), 0xFFE2: (0x3C, shiftFlag),
        0xFFE3: (0x3B, controlFlag), 0xFFE4: (0x3E, controlFlag),
        0xFFE9: (0x3A, optionFlag), 0xFFEA: (0x3D, optionFlag),
        0xFFE7: (0x37, commandFlag), 0xFFE8: (0x36, commandFlag),
        0xFFEB: (0x37, commandFlag), 0xFFEC: (0x36, commandFlag),
    ]

    private static let special: [UInt32: UInt16] = [
        0xFF08: 0x33, 0xFF09: 0x30, 0xFF0D: 0x24, 0xFF8D: 0x4C, 0xFF1B: 0x35, 0xFFFF: 0x75,
        0xFF50: 0x73, 0xFF51: 0x7B, 0xFF52: 0x7E, 0xFF53: 0x7C, 0xFF54: 0x7D,
        0xFF55: 0x74, 0xFF56: 0x79, 0xFF57: 0x77, 0xFF63: 0x72,
        0xFFBE: 0x7A, 0xFFBF: 0x78, 0xFFC0: 0x63, 0xFFC1: 0x76, 0xFFC2: 0x60, 0xFFC3: 0x61,
        0xFFC4: 0x62, 0xFFC5: 0x64, 0xFFC6: 0x65, 0xFFC7: 0x6D, 0xFFC8: 0x67, 0xFFC9: 0x6F,
    ]

    /// US-layout key codes, for shortcuts (a letter with Command or Control held).
    private static let ansi: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
        "m": 46, ".": 47, " ": 49, "`": 50,
    ]

    private let sink: RFBInputSink
    private(set) var flags: UInt64 = 0
    /// Keysyms that went down as typed text: their release posts nothing.
    private var typed = Set<UInt32>()
    /// Keysyms that went down as key codes, with the code, so the release matches.
    private var coded: [UInt32: UInt16] = [:]

    init(sink: RFBInputSink) { self.sink = sink }

    static func character(forKeysym k: UInt32) -> Character? {
        if k >= 0x20 && k <= 0x7E { return Character(UnicodeScalar(k)!) }
        if k >= 0xA0 && k <= 0xFF { return Character(UnicodeScalar(k)!) }
        if k >= 0x0100_0000, let s = UnicodeScalar(k - 0x0100_0000) { return Character(s) }
        return nil
    }

    func key(keysym: UInt32, down: Bool) {
        if let m = Self.modifiers[keysym] {
            if down { flags |= m.flag } else { flags &= ~m.flag }
            sink.key(code: m.code, down: down, flags: flags)
            return
        }
        if let code = Self.special[keysym] {
            if down { coded[keysym] = code; sink.key(code: code, down: true, flags: flags) }
            else if let c = coded.removeValue(forKey: keysym) { sink.key(code: c, down: false, flags: flags) }
            return
        }
        guard let ch = Self.character(forKeysym: keysym) else { return }
        let shortcut = flags & (Self.commandFlag | Self.controlFlag) != 0
        if shortcut, let code = Self.ansi[Character(ch.lowercased())] {
            if down { coded[keysym] = code; sink.key(code: code, down: true, flags: flags) }
            else if let c = coded.removeValue(forKey: keysym) { sink.key(code: c, down: false, flags: flags) }
            return
        }
        if down {
            // The key as the client's layout produced it, typed as text: the
            // host layout does not matter. Held keys do not repeat from here.
            if typed.insert(keysym).inserted { sink.text(String(ch)) }
        } else {
            typed.remove(keysym)
        }
    }

    /// The client went away: let go of everything.
    func releaseAll() {
        flags = 0
        typed.removeAll()
        coded.removeAll()
        sink.releaseAll()
    }
}

/// Turns RFB pointer events (a button mask and a pixel position) into
/// presses, moves and wheel steps.
final class RFBPointer {
    private let sink: RFBInputSink
    private var buttons: UInt8 = 0
    private var width = 1.0, height = 1.0

    /// RFB button bit to the injector's button number: left 0, right 1, middle 2.
    private static let map: [(bit: UInt8, button: UInt8)] = [(1, 0), (2, 2), (4, 1)]
    static let wheelStep: Float = 40

    init(sink: RFBInputSink, width: Int, height: Int) {
        self.sink = sink
        self.width = Double(max(width, 1))
        self.height = Double(max(height, 1))
    }

    func resize(width: Int, height: Int) {
        self.width = Double(max(width, 1))
        self.height = Double(max(height, 1))
    }

    func event(mask: UInt8, x: Int, y: Int) {
        let nx = Float(min(max(Double(x) / width, 0), 1))
        let ny = Float(min(max(Double(y) / height, 0), 1))
        var moved = false
        for m in Self.map where (mask & m.bit) != (buttons & m.bit) {
            sink.mouseButton(button: m.button, down: mask & m.bit != 0, x: nx, y: ny)
            moved = true
        }
        // Wheel: bits 3 to 6 are up, down, left, right; a step per press.
        let wheel = mask & ~buttons
        if wheel & 8 != 0 { sink.scroll(dx: 0, dy: Self.wheelStep) }
        if wheel & 16 != 0 { sink.scroll(dx: 0, dy: -Self.wheelStep) }
        if wheel & 32 != 0 { sink.scroll(dx: Self.wheelStep, dy: 0) }
        if wheel & 64 != 0 { sink.scroll(dx: -Self.wheelStep, dy: 0) }
        if !moved { sink.mouseMove(x: nx, y: ny) }
        buttons = mask
    }
}
