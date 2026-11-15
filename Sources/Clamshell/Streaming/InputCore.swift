import Foundation
import CoreGraphics

// Pure decision layer for injected input. Everything here comes from the
// network, so the rules (what is dropped, clamped, counted or split) live in
// value types that tests can drive headless. `InputInjector` turns the
// resulting `InputEvent`s into CGEvents and posts them.

enum MouseAction: Equatable {
    case move, down, up, drag
}

enum InputEvent: Equatable {
    /// `button` is 0 left, 1 right, 2 middle, 3 back, 4 forward. `delta` is
    /// set for relative moves. `clickCount` is meaningful on down/up.
    case mouse(MouseAction, button: Int, point: CGPoint, clickCount: Int, delta: CGVector?)
    case key(code: UInt16, down: Bool, flags: UInt64)
    /// At most 20 UTF-16 units, never splitting a surrogate pair.
    case text(String)
}

final class InputCore {
    static let maxButton = 4
    static let maxTextBytes = 16 * 1024
    static let textChunkUnits = 20
    static let maxRelativeDelta: Double = 10_000
    static let clickRadius: CGFloat = 4
    static let returnKeyCode: UInt16 = 0x24
    static let tabKeyCode: UInt16 = 0x30

    private let boundsProvider: () -> CGRect
    private let displaysProvider: () -> [CGRect]
    private let cursorProvider: () -> CGPoint
    private let clock: () -> TimeInterval
    private let doubleClickInterval: () -> TimeInterval

    private var heldButtons: [Int] = []          // press order
    private var heldClickCount: [Int: Int] = [:]
    private var heldKeys: [UInt16] = []
    private var lastPoint = CGPoint.zero
    private var lastPress: (button: Int, time: TimeInterval, point: CGPoint, count: Int)?

    init(boundsProvider: @escaping () -> CGRect,
         displaysProvider: @escaping () -> [CGRect],
         cursorProvider: @escaping () -> CGPoint,
         clock: @escaping () -> TimeInterval,
         doubleClickInterval: @escaping () -> TimeInterval) {
        self.boundsProvider = boundsProvider
        self.displaysProvider = displaysProvider
        self.cursorProvider = cursorProvider
        self.clock = clock
        self.doubleClickInterval = doubleClickInterval
    }

    var heldButtonCount: Int { heldButtons.count }
    var heldKeyCount: Int { heldKeys.count }

    // MARK: mapping

    private func map(_ x: Float32, _ y: Float32) -> CGPoint {
        let bounds = boundsProvider()
        // A zeroed rect (window closed mid-lookup) would land at (0,0), the
        // Apple menu: reuse the last known-good point instead.
        guard bounds.width > 0, bounds.height > 0 else { return lastPoint }
        let p = CGPoint(
            x: bounds.origin.x + CGFloat(min(max(x, 0), 1)) * bounds.width,
            y: bounds.origin.y + CGFloat(min(max(y, 0), 1)) * bounds.height)
        lastPoint = p
        return p
    }

    /// Drag type follows the most recently pressed button still held.
    private var dragButton: Int? { heldButtons.last }

    // MARK: pointer

    func mouseMove(x: Float32, y: Float32) -> [InputEvent] {
        guard x.isFinite, y.isFinite else { return [] }
        let point = map(x, y)
        if let b = dragButton {
            return [.mouse(.drag, button: b, point: point, clickCount: heldClickCount[b] ?? 1, delta: nil)]
        }
        return [.mouse(.move, button: 0, point: point, clickCount: 0, delta: nil)]
    }

    func mouseButton(button: UInt8, down: Bool, x: Float32, y: Float32) -> [InputEvent] {
        guard x.isFinite, y.isFinite, Int(button) <= Self.maxButton else { return [] }
        let b = Int(button)
        let point = map(x, y)
        if down {
            let now = clock()
            var count = 1
            if let last = lastPress, last.button == b,
               now - last.time <= doubleClickInterval(),
               hypot(point.x - last.point.x, point.y - last.point.y) <= Self.clickRadius {
                count = last.count + 1
            }
            lastPress = (b, now, point, count)
            heldButtons.removeAll { $0 == b }
            heldButtons.append(b)
            heldClickCount[b] = count
            return [.mouse(.down, button: b, point: point, clickCount: count, delta: nil)]
        }
        let count = heldClickCount[b] ?? 1
        heldButtons.removeAll { $0 == b }
        heldClickCount[b] = nil
        return [.mouse(.up, button: b, point: point, clickCount: count, delta: nil)]
    }

    func mouseRelative(dx: Float32, dy: Float32) -> [InputEvent] {
        guard dx.isFinite, dy.isFinite else { return [] }
        let limit = Self.maxRelativeDelta
        let ddx = min(max(Double(dx), -limit), limit)
        let ddy = min(max(Double(dy), -limit), limit)
        let cursor = cursorProvider()
        var p = CGPoint(x: cursor.x + CGFloat(ddx), y: cursor.y + CGFloat(ddy))
        let displays = displaysProvider().filter { $0.width > 0 && $0.height > 0 }
        if !displays.contains(where: { Self.contains($0, p) }) {
            let home = displays.first(where: { Self.contains($0, cursor) }) ?? displays.first ?? boundsProvider()
            if home.width > 0, home.height > 0 {
                // Stay strictly inside (the max edge is exclusive).
                p.x = min(max(p.x, home.minX), home.maxX - 1)
                p.y = min(max(p.y, home.minY), home.maxY - 1)
            } else {
                p = cursor
            }
        }
        lastPoint = p
        let delta = CGVector(dx: ddx, dy: ddy)
        if let b = dragButton {
            return [.mouse(.drag, button: b, point: p, clickCount: heldClickCount[b] ?? 1, delta: delta)]
        }
        return [.mouse(.move, button: 0, point: p, clickCount: 0, delta: delta)]
    }

    private static func contains(_ r: CGRect, _ p: CGPoint) -> Bool {
        p.x >= r.minX && p.x < r.maxX && p.y >= r.minY && p.y < r.maxY
    }

    // MARK: keyboard

    func key(macKeyCode: UInt16, down: Bool, flags: UInt64) -> [InputEvent] {
        if down {
            if !heldKeys.contains(macKeyCode) { heldKeys.append(macKeyCode) }
        } else {
            heldKeys.removeAll { $0 == macKeyCode }
        }
        return [.key(code: macKeyCode, down: down, flags: flags)]
    }

    /// Unicode text -> typing events. Returns [] for oversize or invalid UTF-8.
    /// LF and CR LF (and a lone CR) become Return, tab becomes Tab, other
    /// control characters are dropped.
    func text(_ payload: Data) -> [InputEvent] {
        guard payload.count <= Self.maxTextBytes,
              let s = String(data: payload, encoding: .utf8) else { return [] }
        var events: [InputEvent] = []
        var pending = ""
        var pendingUnits = 0
        func flush() {
            if !pending.isEmpty { events.append(.text(pending)) }
            pending = ""; pendingUnits = 0
        }
        func press(_ code: UInt16) {
            flush()
            events.append(.key(code: code, down: true, flags: 0))
            events.append(.key(code: code, down: false, flags: 0))
        }
        let scalars = Array(s.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let u = scalars[i]
            i += 1
            switch u.value {
            case 0x0D:
                if i < scalars.count, scalars[i].value == 0x0A { i += 1 }
                press(Self.returnKeyCode)
            case 0x0A: press(Self.returnKeyCode)
            case 0x09: press(Self.tabKeyCode)
            case 0x00..<0x20, 0x7F, 0x80..<0xA0: continue
            default:
                let units = u.value > 0xFFFF ? 2 : 1
                if pendingUnits + units > Self.textChunkUnits { flush() }
                pending.unicodeScalars.append(u)
                pendingUnits += units
            }
        }
        flush()
        return events
    }

    // MARK: release

    /// Up events for everything still held (keys with flags 0); clears state.
    func releaseAll() -> [InputEvent] {
        var events: [InputEvent] = []
        let here = heldButtons.isEmpty ? lastPoint : cursorProvider()
        for b in heldButtons.reversed() {
            events.append(.mouse(.up, button: b, point: here, clickCount: heldClickCount[b] ?? 1, delta: nil))
        }
        for k in heldKeys.reversed() {
            events.append(.key(code: k, down: false, flags: 0))
        }
        heldButtons = []
        heldClickCount = [:]
        heldKeys = []
        return events
    }
}
