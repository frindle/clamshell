import UIKit

// Physical keyboard passthrough uses the existing INPUT_KEY message, which
// already carries a macOS virtual keycode + CGEventFlags — no protocol change
// needed. The client is responsible for translation (per PROTOCOL.md), so this
// maps UIKit's USB-HID usage codes to macOS virtual keycodes here.

enum KeyMap {
    /// USB HID usage (UIKeyboardHIDUsage raw) -> macOS virtual keycode (kVK_*).
    /// Covers the ANSI keyboard: letters, digits, punctuation, whitespace,
    /// modifiers, arrows, nav cluster, and function keys. Unmapped keys are
    /// dropped rather than sent as a wrong keycode.
    static let hidToMacVK: [Int: UInt16] = [
        // Letters (HID a=0x04 … z=0x1D)
        0x04: 0,  0x05: 11, 0x06: 8,  0x07: 2,  0x08: 14, 0x09: 3,  0x0A: 5,
        0x0B: 4,  0x0C: 34, 0x0D: 38, 0x0E: 40, 0x0F: 37, 0x10: 46, 0x11: 45,
        0x12: 31, 0x13: 35, 0x14: 12, 0x15: 15, 0x16: 1,  0x17: 17, 0x18: 32,
        0x19: 9,  0x1A: 13, 0x1B: 7,  0x1C: 16, 0x1D: 6,
        // Digits 1-9,0 (HID 0x1E…0x27)
        0x1E: 18, 0x1F: 19, 0x20: 20, 0x21: 21, 0x22: 23, 0x23: 22,
        0x24: 26, 0x25: 28, 0x26: 25, 0x27: 29,
        // Whitespace / editing
        0x28: 36, 0x29: 53, 0x2A: 51, 0x2B: 48, 0x2C: 49,
        // Punctuation
        0x2D: 27, 0x2E: 24, 0x2F: 33, 0x30: 30, 0x31: 42,
        0x33: 41, 0x34: 39, 0x35: 50, 0x36: 43, 0x37: 47, 0x38: 44, 0x39: 57,
        // Function keys F1–F12
        0x3A: 122, 0x3B: 120, 0x3C: 99,  0x3D: 118, 0x3E: 96,  0x3F: 97,
        0x40: 98,  0x41: 100, 0x42: 101, 0x43: 109, 0x44: 103, 0x45: 111,
        // Nav cluster
        0x49: 114, 0x4A: 115, 0x4B: 116, 0x4C: 117, 0x4D: 119, 0x4E: 121,
        // Arrows
        0x4F: 124, 0x50: 123, 0x51: 125, 0x52: 126,
        // Modifiers
        0xE0: 59, 0xE1: 56, 0xE2: 58, 0xE3: 55, 0xE4: 62, 0xE5: 60, 0xE6: 61, 0xE7: 54,
    ]

    /// UIKeyModifierFlags -> CGEventFlags raw bits.
    static func cgFlags(from mods: UIKeyModifierFlags) -> UInt64 {
        var f: UInt64 = 0
        if mods.contains(.alphaShift) { f |= 0x1_0000 }   // caps lock
        if mods.contains(.shift)      { f |= 0x2_0000 }
        if mods.contains(.control)    { f |= 0x4_0000 }
        if mods.contains(.alternate)  { f |= 0x8_0000 }
        if mods.contains(.command)    { f |= 0x10_0000 }
        return f
    }

    /// Forwards mappable hardware key presses as INPUT_KEY messages.
    /// Returns true if at least one press was sent (caller skips super).
    static func forward(_ presses: Set<UIPress>, down: Bool, to client: StreamClient?) -> Bool {
        var handled = false
        for press in presses {
            guard let key = press.key,
                  let macVK = hidToMacVK[key.keyCode.rawValue] else { continue }
            client?.sendKey(macKeyCode: macVK, down: down, flags: cgFlags(from: key.modifierFlags))
            handled = true
        }
        return handled
    }

    /// Character -> (macOS virtual keycode, needs shift), for software-keyboard
    /// typing on the iPhone control surface (UIKeyInput gives characters, not
    /// HID codes). ANSI US layout, matching the InputInjector's assumption.
    static func macVK(for char: Character) -> (vk: UInt16, shift: Bool)? {
        if let lower = char.lowercased().first, let vk = charToVK[lower] {
            return (vk, char.isUppercase)
        }
        if let vk = charToVK[char] { return (vk, false) }
        if let (base, _) = shiftedToBase[char], let vk = charToVK[base] { return (vk, true) }
        return nil
    }

    private static let charToVK: [Character: UInt16] = [
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4,
        "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35,
        "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7,
        "y": 16, "z": 6,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26,
        "8": 28, "9": 25, "0": 29,
        "\n": 36, "\t": 48, " ": 49,
        "-": 27, "=": 24, "[": 33, "]": 30, "\\": 42, ";": 41, "'": 39,
        "`": 50, ",": 43, ".": 47, "/": 44,
    ]

    /// Shifted ANSI symbols -> their unshifted base key.
    private static let shiftedToBase: [Character: (Character, Bool)] = [
        "!": ("1", true), "@": ("2", true), "#": ("3", true), "$": ("4", true),
        "%": ("5", true), "^": ("6", true), "&": ("7", true), "*": ("8", true),
        "(": ("9", true), ")": ("0", true), "_": ("-", true), "+": ("=", true),
        "{": ("[", true), "}": ("]", true), "|": ("\\", true), ":": (";", true),
        "\"": ("'", true), "~": ("`", true), "<": (",", true), ">": (".", true),
        "?": ("/", true),
    ]
}
