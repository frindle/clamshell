import UIKit

// Physical/software keyboard -> RDP input, mirroring KeyMap.swift's shape
// (same HID-usage-code left side) but targeting PC/AT "Set 1" scancodes —
// what RDP actually transmits on the wire (freerdp_input_send_keyboard_event)
// — instead of macOS virtual keycodes. Covers the ANSI keyboard; unmapped
// keys are dropped rather than sent as a wrong scancode, same convention as
// KeyMap.swift.

enum RDPKeyMap {
    /// USB HID usage (UIKeyboardHIDUsage raw) -> (PC/AT Set-1 scancode,
    /// extended). "Extended" keys are the E0-prefixed ones (arrows, nav
    /// cluster, right-side Ctrl/Alt/Cmd) — RDPBridgeSession ORs in
    /// KBD_FLAGS_EXTENDED for those.
    static let hidToScancode: [Int: (code: UInt16, extended: Bool)] = [
        // Letters (HID a=0x04 … z=0x1D) — QWERTY physical positions, not the
        // letters' alphabetic order, matching Set 1's layout.
        0x04: (0x1E, false), 0x05: (0x30, false), 0x06: (0x2E, false), 0x07: (0x20, false),
        0x08: (0x12, false), 0x09: (0x21, false), 0x0A: (0x22, false), 0x0B: (0x23, false),
        0x0C: (0x17, false), 0x0D: (0x24, false), 0x0E: (0x25, false), 0x0F: (0x26, false),
        0x10: (0x32, false), 0x11: (0x31, false), 0x12: (0x18, false), 0x13: (0x19, false),
        0x14: (0x10, false), 0x15: (0x13, false), 0x16: (0x1F, false), 0x17: (0x14, false),
        0x18: (0x16, false), 0x19: (0x2F, false), 0x1A: (0x11, false), 0x1B: (0x2D, false),
        0x1C: (0x15, false), 0x1D: (0x2C, false),
        // Digits 1-9,0 (HID 0x1E…0x27)
        0x1E: (0x02, false), 0x1F: (0x03, false), 0x20: (0x04, false), 0x21: (0x05, false),
        0x22: (0x06, false), 0x23: (0x07, false), 0x24: (0x08, false), 0x25: (0x09, false),
        0x26: (0x0A, false), 0x27: (0x0B, false),
        // Whitespace / editing
        0x28: (0x1C, false), // Return
        0x29: (0x01, false), // Escape
        0x2A: (0x0E, false), // Backspace
        0x2B: (0x0F, false), // Tab
        0x2C: (0x39, false), // Space
        // Punctuation
        0x2D: (0x0C, false), // -
        0x2E: (0x0D, false), // =
        0x2F: (0x1A, false), // [
        0x30: (0x1B, false), // ]
        0x31: (0x2B, false), // backslash
        0x33: (0x27, false), // ;
        0x34: (0x28, false), // '
        0x35: (0x29, false), // `
        0x36: (0x33, false), // ,
        0x37: (0x34, false), // .
        0x38: (0x35, false), // /
        0x39: (0x3A, false), // Caps Lock
        // Function keys F1–F12
        0x3A: (0x3B, false), 0x3B: (0x3C, false), 0x3C: (0x3D, false), 0x3D: (0x3E, false),
        0x3E: (0x3F, false), 0x3F: (0x40, false), 0x40: (0x41, false), 0x41: (0x42, false),
        0x42: (0x43, false), 0x43: (0x44, false), 0x44: (0x57, false), 0x45: (0x58, false),
        // Nav cluster (extended)
        0x49: (0x52, true),  // Insert
        0x4A: (0x47, true),  // Home
        0x4B: (0x49, true),  // Page Up
        0x4C: (0x53, true),  // Delete
        0x4D: (0x4F, true),  // End
        0x4E: (0x51, true),  // Page Down
        // Arrows (extended)
        0x4F: (0x4D, true), 0x50: (0x4B, true), 0x51: (0x50, true), 0x52: (0x48, true),
        // Modifiers: left non-extended, right extended (matches Set 1)
        0xE0: (0x1D, false), // Left Ctrl
        0xE1: (0x2A, false), // Left Shift
        0xE2: (0x38, false), // Left Alt/Option
        0xE3: (0x5B, true),  // Left Cmd/GUI
        0xE4: (0x1D, true),  // Right Ctrl
        0xE5: (0x36, false), // Right Shift
        0xE6: (0x38, true),  // Right Alt/Option
        0xE7: (0x5C, true),  // Right Cmd/GUI
    ]

    /// Forwards mappable hardware key presses as RDP scancode events.
    /// Returns true if at least one press was sent (caller skips super).
    static func forward(_ presses: Set<UIPress>, down: Bool, to session: RDPSession?) -> Bool {
        var handled = false
        for press in presses {
            guard let key = press.key,
                  let mapped = hidToScancode[key.keyCode.rawValue] else { continue }
            session?.sendScancode(mapped.code, extended: mapped.extended, down: down)
            handled = true
        }
        return handled
    }
}
