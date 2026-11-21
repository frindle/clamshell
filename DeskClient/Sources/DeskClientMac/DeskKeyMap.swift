#if os(macOS)
import AppKit

/// Key translation for the Mac viewer. The iOS KeyMap maps HID usages to Mac virtual keys. A Mac event already
/// carries the virtual key, so only the modifier flags need mapping. The character table is copied from the
/// iOS KeyMap (the iOS project must not change) for typing text that has no key event.
public enum DeskKeyMap {
    /// NSEvent modifier flags to CGEventFlags raw bits, which is what INPUT_KEY carries.
    public static func cgFlags(from mods: NSEvent.ModifierFlags) -> UInt64 {
        var f: UInt64 = 0
        if mods.contains(.capsLock) { f |= 0x1_0000 }
        if mods.contains(.shift)    { f |= 0x2_0000 }
        if mods.contains(.control)  { f |= 0x4_0000 }
        if mods.contains(.option)   { f |= 0x8_0000 }
        if mods.contains(.command)  { f |= 0x10_0000 }
        return f
    }

    /// Character to (virtual key, needs shift). ANSI US layout, as the host's injector assumes.
    public static func macVK(for char: Character) -> (vk: UInt16, shift: Bool)? {
        if let lower = char.lowercased().first, let vk = charToVK[lower] {
            return (vk, char.isUppercase)
        }
        if let vk = charToVK[char] { return (vk, false) }
        if let base = shiftedToBase[char], let vk = charToVK[base] { return (vk, true) }
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

    private static let shiftedToBase: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
        "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";",
        "\"": "'", "~": "`", "<": ",", ">": ".", "?": "/",
    ]
}
#endif
