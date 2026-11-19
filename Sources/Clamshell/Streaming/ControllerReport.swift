import Foundation

// The client's side of sending game controllers (PROTOCOL.md "Peripherals" and
// "Game controllers"). No GameController framework and no clock here: the iOS
// app reads the controllers and writes to the socket; this turns a controller's
// state into the 18-byte report and decides when to send. Shared by the iOS app
// (compiled into it) and the tests.

/// What a controller reads, with the sign convention of GameController: sticks
/// from -1 to 1 with up and right positive, triggers from 0 to 1.
struct ControllerSnapshot: Equatable {
    var a = false, b = false, x = false, y = false
    var leftShoulder = false, rightShoulder = false
    /// View / Share / Select, and Menu / Options / Start.
    var view = false, menu = false
    var leftStickButton = false, rightStickButton = false
    var up = false, down = false, left = false, right = false
    var home = false
    var leftTrigger: Float = 0, rightTrigger: Float = 0
    var leftX: Float = 0, leftY: Float = 0, rightX: Float = 0, rightY: Float = 0

    /// The report. Y is negated: the wire counts down as positive.
    var state: GamepadState {
        var bits: UInt32 = 0
        func set(_ on: Bool, _ bit: Int) { if on { bits |= 1 << UInt32(bit) } }
        set(a, 0); set(b, 1); set(x, 2); set(y, 3)
        set(leftShoulder, 4); set(rightShoulder, 5)
        set(view, 8); set(menu, 9)
        set(leftStickButton, 10); set(rightStickButton, 11)
        set(up, 12); set(down, 13); set(left, 14); set(right, 15)
        set(home, 16)
        return GamepadState(buttons: bits,
                            leftTrigger: Self.trigger(leftTrigger), rightTrigger: Self.trigger(rightTrigger),
                            leftX: Self.axis(leftX), leftY: Self.axis(-leftY),
                            rightX: Self.axis(rightX), rightY: Self.axis(-rightY))
    }

    /// -1...1 to -32767...32767; anything not a number is the centre.
    static func axis(_ v: Float) -> Int16 {
        guard v.isFinite else { return 0 }
        return Int16((max(-1, min(1, v)) * 32767).rounded())
    }

    /// 0...1 to 0...255.
    static func trigger(_ v: Float) -> UInt8 {
        guard v.isFinite else { return 0 }
        return UInt8((max(0, min(1, v)) * 255).rounded())
    }
}

/// One controller the app has attached, as the session screen shows it.
struct ControllerRow: Equatable {
    let id: UInt32
    let name: String
    /// Nil until the host answers.
    let status: UInt8?

    var statusText: String { ControllerClient.statusText(status) }
}

/// Which controllers the connection has attached and what to send for them.
/// Ids count up from 1 and are not reused on one connection.
final class ControllerClient {
    /// A report for one controller goes out at most this often (250 a second).
    static let minInterval: TimeInterval = 0.004
    /// A report goes out at least this often while nothing changes.
    static let repeatInterval: TimeInterval = 1

    private struct Entry {
        var id: UInt32
        var name: String
        var rumble: Bool
        var status: UInt8?
        var latest = GamepadState.rest
        var lastSent: TimeInterval = -.infinity
        var dirty = false
    }

    private var entries: [Entry] = []
    private var nextId: UInt32 = 1

    var rows: [ControllerRow] { entries.map { ControllerRow(id: $0.id, name: $0.name, status: $0.status) } }
    var isEmpty: Bool { entries.isEmpty }

    static func statusText(_ status: UInt8?) -> String {
        switch status {
        case nil: return "waiting for the Mac"
        case Peripheral.Status.attached?, Peripheral.Status.keysAndPointer?: return "moves the pointer and sends keys"
        case Peripheral.Status.unsupportedKind?: return "not supported by the Mac"
        case Peripheral.Status.tooMany?: return "the Mac has as many as it takes"
        case Peripheral.Status.off?: return "turned off on the Mac"
        case Peripheral.Status.removed?: return "removed on the Mac"
        default: return "not accepted by the Mac"
        }
    }

    /// A controller was connected. Returns its id and PERIPHERAL_ATTACH.
    func connect(name: String, rumble: Bool = false) -> (id: UInt32, message: PeripheralMessage) {
        let id = nextId
        nextId &+= 1
        let clean = Peripheral.cleanName(name)
        entries.append(Entry(id: id, name: clean.isEmpty ? "Game controller" : clean, rumble: rumble))
        return (id, Peripheral.attach(id: id, kind: "gamepad", name: clean.isEmpty ? "Game controller" : clean,
                                      rumble: rumble ? true : nil))
    }

    /// A controller went away: PERIPHERAL_DETACH. Nil if it was not attached.
    func disconnect(id: UInt32) -> PeripheralMessage? {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return nil }
        entries.remove(at: i)
        return Peripheral.detach(id: id)
    }

    /// The controller's state changed. Returns the report to send now, or nil
    /// when it came sooner than `minInterval` after the last one (it goes out
    /// from `tick`, so the last state always arrives) or nothing changed.
    func input(id: UInt32, _ snapshot: ControllerSnapshot, now: TimeInterval) -> PeripheralMessage? {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return nil }
        let state = snapshot.state
        guard state != entries[i].latest || entries[i].lastSent == -.infinity else { return nil }
        entries[i].latest = state
        guard Self.sends(entries[i].status) else { return nil }
        if now - entries[i].lastSent < Self.minInterval {
            entries[i].dirty = true
            return nil
        }
        return emit(i, now)
    }

    /// Reports held back, and the once-a-second repeat. Call every 10 to
    /// 20 ms.
    func tick(now: TimeInterval) -> [PeripheralMessage] {
        var out: [PeripheralMessage] = []
        for i in entries.indices where Self.sends(entries[i].status) {
            let due = entries[i].dirty && now - entries[i].lastSent >= Self.minInterval
            let repeating = now - entries[i].lastSent >= Self.repeatInterval
            if due || repeating { out.append(emit(i, now)) }
        }
        return out
    }

    /// Every controller at rest, once: before the app stops reading them.
    func restReports(now: TimeInterval) -> [PeripheralMessage] {
        var out: [PeripheralMessage] = []
        for i in entries.indices where Self.sends(entries[i].status) {
            entries[i].latest = .rest
            out.append(emit(i, now))
        }
        return out
    }

    /// PERIPHERAL_STATUS from the host.
    func receiveStatus(_ payload: Data) {
        guard let (id, status) = Peripheral.decodeStatus(payload),
              let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].status = status
    }

    /// A new connection: nothing is attached on it. Attaches every controller
    /// again, under the same ids, with their status forgotten.
    func reconnect() -> [PeripheralMessage] {
        for i in entries.indices {
            entries[i].status = nil
            entries[i].lastSent = -.infinity
            entries[i].dirty = false
        }
        return entries.map {
            Peripheral.attach(id: $0.id, kind: "gamepad", name: $0.name, rumble: $0.rumble ? true : nil)
        }
    }

    /// The host answered with a status after which no reports are wanted
    /// (2, 3, 4, 5); anything else, or no answer yet, is sent to.
    private static func sends(_ status: UInt8?) -> Bool {
        guard let status else { return true }
        return status == Peripheral.Status.attached || status == Peripheral.Status.keysAndPointer
    }

    private func emit(_ i: Int, _ now: TimeInterval) -> PeripheralMessage {
        entries[i].lastSent = now
        entries[i].dirty = false
        return Peripheral.gamepadInput(id: entries[i].id, state: entries[i].latest)
    }
}
