import Foundation

// A game controller on the iPad, turned into keys and the pointer on the Mac
// (PROTOCOL.md "Game controllers": status 1, "attached as keys and pointer").
// The unpaid developer team has no virtual-HID entitlement, so this is all
// the host does with a controller. Pure logic: it drives a `GamepadOutput`,
// which the real injector (the same path INPUT_* messages take) conforms to.

/// What the mapper drives. `InputInjector` is the real one.
protocol GamepadOutput: AnyObject {
    func mouseRelative(dx: Float32, dy: Float32)
    func mouseButtonAtCursor(button: UInt8, down: Bool)
    func scroll(dx: Float32, dy: Float32)
    func key(macKeyCode: UInt16, down: Bool, flags: UInt64)
}

extension InputInjector: GamepadOutput {}

/// The table: which controller button does what, and how the sticks feel.
/// Kept in the host's settings (the app's preferences, key `gamepadMapping`
/// as JSON); a missing or unreadable value means the default.
struct GamepadMapping: Codable, Equatable {
    struct Entry: Codable, Equatable {
        /// Bit number in the PERIPHERAL_INPUT button field (PROTOCOL.md).
        var bit: Int
        /// Exactly one of these is set.
        var mouseButton: UInt8?
        var macKeyCode: UInt16?
    }

    var buttons: [Entry]
    /// Stick travel below this (0...1) does nothing.
    var deadZone: Double
    /// Points per second at full tilt of the left stick.
    var pointerSpeed: Double
    /// Pixels per second at full tilt of the right stick.
    var scrollSpeed: Double

    // Bit numbers from PROTOCOL.md: 0 A, 1 B, 8 left centre (View/Share/
    // Select), 9 right centre (Menu/Options/Start), 12 up, 13 down, 14 left,
    // 15 right.
    static let standard = GamepadMapping(
        buttons: [
            Entry(bit: 0, mouseButton: 0, macKeyCode: nil),   // A: click
            Entry(bit: 1, mouseButton: 1, macKeyCode: nil),   // B: right-click
            Entry(bit: 12, mouseButton: nil, macKeyCode: 0x7E), // up arrow
            Entry(bit: 13, mouseButton: nil, macKeyCode: 0x7D), // down arrow
            Entry(bit: 14, mouseButton: nil, macKeyCode: 0x7B), // left arrow
            Entry(bit: 15, mouseButton: nil, macKeyCode: 0x7C), // right arrow
            Entry(bit: 9, mouseButton: nil, macKeyCode: 0x24),  // Menu: Return
            Entry(bit: 8, mouseButton: nil, macKeyCode: 0x35),  // View/Options: Escape
        ],
        deadZone: 0.15, pointerSpeed: 900, scrollSpeed: 700)

    static let defaultsKey = "gamepadMapping"

    static func load(from defaults: UserDefaults = .standard) -> GamepadMapping {
        guard let data = defaults.data(forKey: defaultsKey),
              let m = try? JSONDecoder().decode(GamepadMapping.self, from: data),
              m.isUsable else { return .standard }
        return m
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    /// A table a user could have edited by hand: refuse nonsense.
    var isUsable: Bool {
        deadZone >= 0 && deadZone < 1 && pointerSpeed.isFinite && scrollSpeed.isFinite
            && pointerSpeed >= 0 && scrollSpeed >= 0
            && buttons.allSatisfy { e in
                (0...16).contains(e.bit) && ((e.mouseButton != nil) != (e.macKeyCode != nil))
                    && (e.mouseButton.map { $0 <= 4 } ?? true) && (e.macKeyCode.map { $0 <= 0xFF } ?? true)
            }
    }
}

/// Turns controller states into events. Not thread safe: use it on one queue.
final class GamepadMapper {
    private enum Held: Hashable { case mouse(UInt8), key(UInt16) }

    private let output: GamepadOutput
    private var mapping: GamepadMapping
    private var states: [UInt32: GamepadState] = [:]
    /// What each controller holds down.
    private var held: [UInt32: Set<Held>] = [:]
    /// How many controllers hold each output, so two controllers on the same
    /// key press it once and release it when the last lets go.
    private var counts: [Held: Int] = [:]

    init(output: GamepadOutput, mapping: GamepadMapping = .standard) {
        self.output = output
        self.mapping = mapping
    }

    func setMapping(_ m: GamepadMapping) {
        mapping = m
        // A held button the new table no longer maps is let go on the next report.
    }

    var heldCount: Int { counts.count }

    /// A controller's whole state. Buttons act at once; sticks act in `tick`.
    func apply(id: UInt32, state: GamepadState) {
        states[id] = state
        var want = Set<Held>()
        for e in mapping.buttons where state.buttons & (1 << UInt32(e.bit)) != 0 {
            if let b = e.mouseButton { want.insert(.mouse(b)) }
            if let k = e.macKeyCode { want.insert(.key(k)) }
        }
        let had = held[id] ?? []
        // Let go first, then press, each in a fixed order (mouse buttons
        // before keys, lowest first), so the events do not depend on how a
        // Set happens to be ordered.
        for h in Self.ordered(had.subtracting(want)) { release(h) }
        for h in Self.ordered(want.subtracting(had)) { press(h) }
        held[id] = want
    }

    private static func ordered(_ s: Set<Held>) -> [Held] {
        func rank(_ h: Held) -> Int {
            switch h {
            case let .mouse(b): return Int(b)
            case let .key(k): return 1000 + Int(k)
            }
        }
        return s.sorted { rank($0) < rank($1) }
    }

    /// Moves the pointer and scrolls for `dt` seconds of stick travel.
    func tick(dt: TimeInterval) {
        guard dt > 0, dt < 1 else { return }
        for id in states.keys.sorted() {
            guard let s = states[id] else { continue }
            let lx = axis(s.leftX), ly = axis(s.leftY)
            if lx != 0 || ly != 0 {
                let k = mapping.pointerSpeed * dt
                output.mouseRelative(dx: Float32(lx * k), dy: Float32(ly * k))
            }
            let rx = axis(s.rightX), ry = axis(s.rightY)
            if rx != 0 || ry != 0 {
                let k = mapping.scrollSpeed * dt
                // Stick Y is positive down; a wheel delta is positive up.
                output.scroll(dx: Float32(rx * k), dy: Float32(-ry * k))
            }
        }
    }

    /// The controller is gone: everything it held is released.
    func remove(id: UInt32) {
        for h in Self.ordered(held.removeValue(forKey: id) ?? []) { release(h) }
        states.removeValue(forKey: id)
    }

    /// The session ended: every controller is removed.
    func releaseAll() {
        for id in Array(states.keys) { remove(id: id) }
        for id in Array(held.keys) { remove(id: id) }
    }

    // MARK: steps

    /// A stick value as -1...1 with the dead zone cut out and the rest
    /// stretched, squared for fine control near the centre.
    private func axis(_ raw: Int16) -> Double {
        let v = max(-1, min(1, Double(raw) / 32767))
        let m = abs(v)
        guard m > mapping.deadZone else { return 0 }
        let t = (m - mapping.deadZone) / (1 - mapping.deadZone)
        return (v < 0 ? -1 : 1) * t * t
    }

    private func press(_ h: Held) {
        counts[h, default: 0] += 1
        guard counts[h] == 1 else { return }
        send(h, down: true)
    }

    private func release(_ h: Held) {
        guard let n = counts[h] else { return }
        if n > 1 { counts[h] = n - 1; return }
        counts.removeValue(forKey: h)
        send(h, down: false)
    }

    private func send(_ h: Held, down: Bool) {
        switch h {
        case let .mouse(b): output.mouseButtonAtCursor(button: b, down: down)
        case let .key(k): output.key(macKeyCode: k, down: down, flags: 0)
        }
    }
}
