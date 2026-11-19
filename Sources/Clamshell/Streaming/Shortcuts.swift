import Foundation

// Key combinations that iPadOS keeps for itself (Cmd-Tab, Cmd-Space, Cmd-H, ...)
// and so never reach the app. The on-screen shortcut bar sends them to the host
// as ordinary INPUT_KEY events. Pure Foundation so tests can run headless.

struct ShortcutModifiers: OptionSet, Hashable {
    let rawValue: Int
    static let command = ShortcutModifiers(rawValue: 1)
    static let shift   = ShortcutModifiers(rawValue: 2)
    static let option  = ShortcutModifiers(rawValue: 4)
    static let control = ShortcutModifiers(rawValue: 8)

    /// Press order: Command, Shift, Option, Control. Each has the Mac virtual
    /// key code and the CGEventFlags bit that is set while it is held.
    static let ordered: [(mod: ShortcutModifiers, vk: UInt16, flag: UInt64)] = [
        (.command, 55, 0x10_0000),
        (.shift,   56, 0x2_0000),
        (.option,  58, 0x8_0000),
        (.control, 59, 0x4_0000),
    ]
}

struct KeyStroke: Equatable {
    let code: UInt16
    let down: Bool
    let flags: UInt64
}

struct Shortcut: Equatable {
    let title: String
    let key: UInt16
    let modifiers: ShortcutModifiers

    static let escape = UInt16(53), tab = UInt16(48), space = UInt16(49)
    static let h = UInt16(4), q = UInt16(12)
    static let left = UInt16(123), right = UInt16(124), down = UInt16(125), up = UInt16(126)

    /// The combos worth a button. Plain keys such as Esc are here too: iPadOS
    /// can swallow those as well.
    static let presets: [Shortcut] = [
        Shortcut(title: "Esc", key: escape, modifiers: []),
        Shortcut(title: "Cmd-Tab", key: tab, modifiers: .command),
        Shortcut(title: "Cmd-Space", key: space, modifiers: .command),
        Shortcut(title: "Cmd-H", key: h, modifiers: .command),
        Shortcut(title: "Cmd-Q", key: q, modifiers: .command),
        Shortcut(title: "Cmd-Opt-Esc", key: escape, modifiers: [.command, .option]),
        Shortcut(title: "Ctrl-Left", key: left, modifiers: .control),
        Shortcut(title: "Ctrl-Right", key: right, modifiers: .control),
        Shortcut(title: "Ctrl-Up", key: up, modifiers: .control),
        Shortcut(title: "Ctrl-Down", key: down, modifiers: .control),
    ]
}

enum ShortcutKeys {
    /// Modifier downs (in press order, flags accumulating), the key down and
    /// up with every modifier flag set, then modifier ups in reverse order.
    static func strokes(key: UInt16, modifiers: ShortcutModifiers) -> [KeyStroke] {
        let held = ShortcutModifiers.ordered.filter { modifiers.contains($0.mod) }
        var out: [KeyStroke] = []
        var flags: UInt64 = 0
        for m in held {
            flags |= m.flag
            out.append(KeyStroke(code: m.vk, down: true, flags: flags))
        }
        out.append(KeyStroke(code: key, down: true, flags: flags))
        out.append(KeyStroke(code: key, down: false, flags: flags))
        for m in held.reversed() {
            flags &= ~m.flag
            out.append(KeyStroke(code: m.vk, down: false, flags: flags))
        }
        return out
    }

    static func strokes(_ shortcut: Shortcut, extra: ShortcutModifiers = []) -> [KeyStroke] {
        strokes(key: shortcut.key, modifiers: shortcut.modifiers.union(extra))
    }
}

/// Modifier toggles on the bar. A toggle applies to the next shortcut sent
/// and then clears (sticky for one use).
struct StickyModifiers: Equatable {
    private(set) var active: ShortcutModifiers = []

    mutating func toggle(_ m: ShortcutModifiers) {
        if active.contains(m) { active.remove(m) } else { active.insert(m) }
    }

    /// The modifiers to add to the next shortcut; clears them.
    mutating func consume() -> ShortcutModifiers {
        defer { active = [] }
        return active
    }
}
