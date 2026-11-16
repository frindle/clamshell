import Foundation

// Peripheral core (PROTOCOL.md "Peripherals attached to the client"). Foundation
// only. A pure decision layer: payload codecs, and a registry for one
// connection that decides what the host answers and what a backend has to do.
// It builds no HID or MIDI device itself; a backend implements
// `PeripheralBackend` and runs the returned actions. The clock is passed in.

/// One message to put on the wire; `frame` adds the `[type][4-byte length]`
/// header before SECURE wraps it.
struct PeripheralMessage: Equatable {
    let type: UInt8
    let payload: Data

    var frame: Data {
        var d = Data(capacity: 5 + payload.count)
        d.append(type)
        d.appendBE(UInt32(payload.count))
        d.append(payload)
        return d
    }
}

/// A game controller's whole state (the 18-byte report without its id).
struct GamepadState: Equatable {
    var buttons: UInt32 = 0
    var leftTrigger: UInt8 = 0
    var rightTrigger: UInt8 = 0
    var leftX: Int16 = 0
    var leftY: Int16 = 0
    var rightX: Int16 = 0
    var rightY: Int16 = 0

    /// No buttons, triggers 0, sticks centred.
    static let rest = GamepadState()

    /// Bits 0-5 and 8-16 are assigned; bits 6, 7 and 17-31 are always 0.
    static let assignedButtons: UInt32 = 0x0001_FF3F

    init(buttons: UInt32 = 0, leftTrigger: UInt8 = 0, rightTrigger: UInt8 = 0,
         leftX: Int16 = 0, leftY: Int16 = 0, rightX: Int16 = 0, rightY: Int16 = 0) {
        self.buttons = buttons & Self.assignedButtons
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
        // -32768 is not used.
        self.leftX = max(leftX, -32767)
        self.leftY = max(leftY, -32767)
        self.rightX = max(rightX, -32767)
        self.rightY = max(rightY, -32767)
    }
}

enum PeripheralKind: String, Equatable {
    case gamepad, midi
}

/// What PERIPHERAL_ATTACH describes. `kind` is kept as the client sent it so
/// an unknown kind can be answered with status 2.
struct PeripheralAttach: Equatable {
    let id: UInt32
    let kind: String
    let name: String
    let rumble: Bool
    let sends: Bool
    let receives: Bool
}

enum PeripheralAttachParse: Equatable {
    case attach(PeripheralAttach)
    /// The id is usable but the description is not (no kind, a name that is
    /// not text, a MIDI instrument that neither sends nor receives): answered
    /// with status 2.
    case malformed(id: UInt32)
    /// No usable id: nothing to answer.
    case ignore
}

enum Peripheral {
    static let attachType: UInt8 = 0x50
    static let statusType: UInt8 = 0x51
    static let detachType: UInt8 = 0x52
    static let inputType: UInt8 = 0x53
    static let outputType: UInt8 = 0x54

    static let maxGamepads = 4
    static let maxPeripherals = 8
    static let restTimeout: TimeInterval = 3
    static let maxNameBytes = 64
    static let maxMIDIBytes = 64 * 1024
    static let gamepadReportBytes = 18
    /// Ids a connection may use up (every attach burns its id, whatever the
    /// answer). Beyond this attaches are ignored, so a client cannot make the
    /// host remember ids without end.
    static let maxAttachesPerConnection = 1024

    /// PERIPHERAL_STATUS values.
    enum Status {
        static let attached: UInt8 = 0
        static let keysAndPointer: UInt8 = 1
        static let unsupportedKind: UInt8 = 2
        static let tooMany: UInt8 = 3
        static let off: UInt8 = 4
        static let removed: UInt8 = 5
    }

    // MARK: encoders

    static func attach(id: UInt32, kind: String, name: String,
                       rumble: Bool? = nil, sends: Bool? = nil, receives: Bool? = nil) -> PeripheralMessage {
        var obj: [String: Any] = ["id": id, "kind": kind, "name": name]
        if let rumble { obj["rumble"] = rumble }
        if let sends { obj["sends"] = sends }
        if let receives { obj["receives"] = receives }
        let json = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return PeripheralMessage(type: attachType, payload: json)
    }

    static func status(id: UInt32, status: UInt8) -> PeripheralMessage {
        var p = Data(capacity: 5)
        p.appendBE(id)
        p.append(status)
        return PeripheralMessage(type: statusType, payload: p)
    }

    static func detach(id: UInt32) -> PeripheralMessage {
        var p = Data(capacity: 4)
        p.appendBE(id)
        return PeripheralMessage(type: detachType, payload: p)
    }

    static func gamepadInput(id: UInt32, state: GamepadState) -> PeripheralMessage {
        var p = Data(capacity: gamepadReportBytes)
        p.appendBE(id)
        p.appendBE(state.buttons)
        p.append(state.leftTrigger)
        p.append(state.rightTrigger)
        p.appendBE(UInt16(bitPattern: state.leftX))
        p.appendBE(UInt16(bitPattern: state.leftY))
        p.appendBE(UInt16(bitPattern: state.rightX))
        p.appendBE(UInt16(bitPattern: state.rightY))
        return PeripheralMessage(type: inputType, payload: p)
    }

    static func rumble(id: UInt32, strong: UInt8, weak: UInt8, durationMs: UInt16) -> PeripheralMessage {
        var p = Data(capacity: 8)
        p.appendBE(id)
        p.append(strong)
        p.append(weak)
        p.appendBE(durationMs)
        return PeripheralMessage(type: outputType, payload: p)
    }

    /// A MIDI report in either direction (PERIPHERAL_INPUT or _OUTPUT).
    static func midi(type: UInt8, id: UInt32, bytes: Data) -> PeripheralMessage {
        var p = Data(capacity: 4 + bytes.count)
        p.appendBE(id)
        p.append(bytes)
        return PeripheralMessage(type: type, payload: p)
    }

    // MARK: decoders

    private static func wholeNumber(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d == d.rounded(.towardZero) else { return nil }
        return d
    }

    private static func bool(_ v: Any?) -> Bool? {
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    /// Display names lose control and invisible formatting characters
    /// (bidirectional overrides among them) and are cut to 64 bytes of UTF-8
    /// without splitting a character.
    static func cleanName(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var bytes = 0
        for u in s.unicodeScalars {
            switch u.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned, .privateUse:
                continue
            default:
                break
            }
            let n = String(u).utf8.count
            if bytes + n > maxNameBytes { break }
            bytes += n
            out.append(u)
        }
        return String(out)
    }

    static func parseAttach(_ payload: Data) -> PeripheralAttachParse {
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let idValue = wholeNumber(obj["id"]),
              idValue >= 1, idValue <= Double(UInt32.max) else { return .ignore }
        let id = UInt32(idValue)
        guard let kind = obj["kind"] as? String else { return .malformed(id: id) }
        var name = ""
        if let raw = obj["name"] {
            guard let s = raw as? String else { return .malformed(id: id) }
            name = cleanName(s)
        }
        let rumble = bool(obj["rumble"]) ?? false
        let sends = bool(obj["sends"]) ?? false
        let receives = bool(obj["receives"]) ?? false
        if kind == PeripheralKind.midi.rawValue, !sends, !receives { return .malformed(id: id) }
        return .attach(PeripheralAttach(id: id, kind: kind, name: name, rumble: rumble, sends: sends, receives: receives))
    }

    static func decodeStatus(_ payload: Data) -> (id: UInt32, status: UInt8)? {
        guard payload.count >= 5 else { return nil }
        return (payload.beUInt32(at: 0), payload[payload.startIndex + 4])
    }

    static func decodeDetach(_ payload: Data) -> UInt32? {
        guard payload.count >= 4 else { return nil }
        return payload.beUInt32(at: 0)
    }

    /// The 18-byte report; longer is accepted, shorter is nil.
    static func decodeGamepad(_ payload: Data) -> (id: UInt32, state: GamepadState)? {
        guard payload.count >= gamepadReportBytes else { return nil }
        let s = payload.startIndex
        func i16(_ at: Int) -> Int16 { Int16(bitPattern: payload.beUInt16(at: at)) }
        return (payload.beUInt32(at: 0),
                GamepadState(buttons: payload.beUInt32(at: 4),
                             leftTrigger: payload[s + 8], rightTrigger: payload[s + 9],
                             leftX: i16(10), leftY: i16(12), rightX: i16(14), rightY: i16(16)))
    }

    static func decodeRumble(_ payload: Data) -> (id: UInt32, strong: UInt8, weak: UInt8, durationMs: UInt16)? {
        guard payload.count >= 8 else { return nil }
        let s = payload.startIndex
        return (payload.beUInt32(at: 0), payload[s + 4], payload[s + 5], payload.beUInt16(at: 6))
    }

    /// A MIDI report: the id and the MIDI bytes. Nil unless the bytes are
    /// whole messages (`midiMessages`).
    static func decodeMIDI(_ payload: Data) -> (id: UInt32, bytes: Data)? {
        guard payload.count > 4 else { return nil }
        let bytes = Data(payload.dropFirst(4))
        guard midiMessages(bytes) != nil else { return nil }
        return (payload.beUInt32(at: 0), bytes)
    }

    // MARK: MIDI

    /// Splits MIDI 1.0 bytes into whole messages, each with its own status
    /// byte (no running status). Nil when the report is empty, over 64 KB, or
    /// does not parse as whole messages; a System Exclusive message must be
    /// closed by F7 in the same report.
    static func midiMessages(_ bytes: Data) -> [Data]? {
        guard !bytes.isEmpty, bytes.count <= maxMIDIBytes else { return nil }
        let b = Array(bytes)
        var out: [Data] = []
        var i = 0
        while i < b.count {
            let status = b[i]
            guard status >= 0x80 else { return nil }
            let end: Int
            switch status {
            case 0x80...0xBF, 0xE0...0xEF, 0xF2: end = i + 3
            case 0xC0...0xDF, 0xF1, 0xF3: end = i + 2
            case 0xF6, 0xF8...0xFF: end = i + 1
            case 0xF0:
                var j = i + 1
                while j < b.count, b[j] != 0xF7 {
                    // Data bytes only; real-time bytes may be interleaved.
                    guard b[j] < 0x80 || b[j] >= 0xF8 else { return nil }
                    j += 1
                }
                guard j < b.count else { return nil }
                end = j + 1
            default: // F4, F5 undefined; F7 with no F7-less start
                return nil
            }
            guard end <= b.count else { return nil }
            if status != 0xF0 {
                for k in (i + 1)..<max(end, i + 1) where b[k] >= 0x80 { return nil }
            }
            out.append(Data(b[i..<end]))
            i = end
        }
        return out
    }
}

// MARK: - Registry

/// What a backend has to do. The registry never builds a device itself.
enum PeripheralAction: Equatable {
    /// Build the virtual device (or, for `.keysAndPointer`, the translator).
    case create(id: UInt32, kind: PeripheralKind, name: String, mode: PeripheralMode,
                rumble: Bool, sends: Bool, receives: Bool)
    /// Set a game controller to this whole state.
    case applyController(id: UInt32, state: GamepadState)
    /// Play these MIDI bytes (whole messages) from the virtual source.
    case deliverMIDI(id: UInt32, bytes: Data)
    /// Take the virtual device away.
    case remove(id: UInt32)
}

enum PeripheralMode: Equatable {
    /// The host presents a device of the peripheral's kind (status 0).
    case device
    /// A game controller turned into keys and pointer (status 1).
    case keysAndPointer
}

/// What this host can do for peripherals, fixed by the host.
struct PeripheralHostSupport: Equatable {
    enum Gamepad: Equatable { case virtualDevice, keysAndPointer, none }
    var gamepad: Gamepad = .none
    var midi: Bool = true

    /// HOST_INFO's `peripherals` array.
    var kinds: [String] {
        var k: [String] = []
        if gamepad != .none { k.append(PeripheralKind.gamepad.rawValue) }
        if midi { k.append(PeripheralKind.midi.rawValue) }
        return k
    }
}

/// The messages to send to the client and the actions for the backend.
struct PeripheralResult: Equatable {
    var messages: [PeripheralMessage] = []
    var actions: [PeripheralAction] = []

    static let none = PeripheralResult()

    mutating func append(_ other: PeripheralResult) {
        messages += other.messages
        actions += other.actions
    }
}

/// The side that makes real devices.
protocol PeripheralBackend: AnyObject {
    /// False: the device could not be created (the client gets status 5).
    func create(id: UInt32, kind: PeripheralKind, name: String, mode: PeripheralMode,
                rumble: Bool, sends: Bool, receives: Bool) -> Bool
    func apply(id: UInt32, state: GamepadState)
    func deliverMIDI(id: UInt32, bytes: Data)
    func remove(id: UInt32)
}

/// The peripherals of one connection. Feed it what the client sends and a
/// clock; send the messages it returns, run the actions it returns.
final class PeripheralRegistry {
    private struct Entry {
        let kind: PeripheralKind
        let mode: PeripheralMode
        let name: String
        let rumble: Bool
        let sends: Bool
        let receives: Bool
        var state = GamepadState.rest
        var lastReport: TimeInterval
        var midi = MIDISounding()
    }

    /// Notes and sustain a MIDI peripheral has left sounding.
    private struct MIDISounding {
        var notes = Set<UInt16>()   // channel << 8 | note
        var sustain = Set<UInt8>()  // channels with the pedal down

        mutating func track(_ message: Data) {
            guard let status = message.first else { return }
            let channel = status & 0x0F
            let d = Array(message)
            switch status & 0xF0 {
            case 0x90 where d.count == 3 && d[2] > 0:
                notes.insert(UInt16(channel) << 8 | UInt16(d[1]))
            case 0x90 where d.count == 3, 0x80 where d.count == 3:
                notes.remove(UInt16(channel) << 8 | UInt16(d[1]))
            case 0xB0 where d.count == 3:
                switch d[1] {
                case 64:
                    if d[2] >= 64 { sustain.insert(channel) } else { sustain.remove(channel) }
                case 120, 123:
                    notes = notes.filter { UInt8($0 >> 8) != channel }
                default: break
                }
            default: break
            }
        }

        /// Note-off for every sounding note, then the pedal up.
        func cleanup() -> Data? {
            var out = Data()
            for n in notes.sorted() { out.append(contentsOf: [0x80 | UInt8(n >> 8), UInt8(n & 0xFF), 0]) }
            for c in sustain.sorted() { out.append(contentsOf: [0xB0 | c, 64, 0]) }
            return out.isEmpty ? nil : out
        }
    }

    private var support: PeripheralHostSupport
    private var entries: [UInt32: Entry] = [:]
    private var usedIds = Set<UInt32>()

    /// False answers every attach with status 4 ("peripherals are turned off").
    private(set) var enabled: Bool

    init(support: PeripheralHostSupport, enabled: Bool = true) {
        self.support = support
        self.enabled = enabled
    }

    var count: Int { entries.count }
    var gamepadCount: Int { entries.values.filter { $0.kind == .gamepad }.count }
    var attachedIds: [UInt32] { entries.keys.sorted() }
    func isAttached(_ id: UInt32) -> Bool { entries[id] != nil }
    func gamepadState(of id: UInt32) -> GamepadState? { entries[id]?.state }

    /// Handle one message from the client.
    func receive(type: UInt8, payload: Data, now: TimeInterval) -> PeripheralResult {
        switch type {
        case Peripheral.attachType: return attach(payload, now: now)
        case Peripheral.inputType: return input(payload, now: now)
        case Peripheral.detachType:
            guard let id = Peripheral.decodeDetach(payload) else { return .none }
            return take(id, status: nil)
        default: return .none
        }
    }

    /// Put controllers that have sent nothing for 3 s at rest.
    func tick(now: TimeInterval) -> PeripheralResult {
        var result = PeripheralResult()
        for id in entries.keys.sorted() {
            guard var e = entries[id], e.kind == .gamepad, e.state != .rest,
                  now - e.lastReport >= Peripheral.restTimeout else { continue }
            e.state = .rest
            entries[id] = e
            result.actions.append(.applyController(id: id, state: .rest))
        }
        return result
    }

    /// The connection or session ended: every peripheral is put at rest and
    /// removed.
    func closeAll() -> PeripheralResult {
        var result = PeripheralResult()
        for id in entries.keys.sorted() { result.append(take(id, status: nil)) }
        return result
    }

    /// The user removed one on the host: status 5.
    func removeByHost(id: UInt32) -> PeripheralResult {
        take(id, status: Peripheral.Status.removed)
    }

    /// The backend could not create the device for an attach: status 5.
    func createFailed(id: UInt32) -> PeripheralResult {
        guard entries.removeValue(forKey: id) != nil else { return .none }
        return PeripheralResult(messages: [Peripheral.status(id: id, status: Peripheral.Status.removed)],
                                actions: [])
    }

    /// The user turned peripherals off (or on). Turning off removes every
    /// peripheral with status 4.
    func setEnabled(_ on: Bool) -> PeripheralResult {
        enabled = on
        guard !on else { return .none }
        var result = PeripheralResult()
        for id in entries.keys.sorted() { result.append(take(id, status: Peripheral.Status.off)) }
        return result
    }

    /// The host's abilities changed (a virtual controller became available).
    /// Existing peripherals keep the mode they were attached with.
    func updateSupport(_ s: PeripheralHostSupport) { support = s }

    // MARK: host to client

    /// Rumble for a controller that attached with `rumble: true`; nothing
    /// otherwise.
    func rumble(id: UInt32, strong: UInt8, weak: UInt8, durationMs: UInt16) -> [PeripheralMessage] {
        guard let e = entries[id], e.kind == .gamepad, e.rumble else { return [] }
        return [Peripheral.rumble(id: id, strong: strong, weak: weak, durationMs: durationMs)]
    }

    /// MIDI from the host to an instrument that attached with
    /// `receives: true`; nothing if it is not whole MIDI messages.
    func midiOutput(id: UInt32, bytes: Data) -> [PeripheralMessage] {
        guard let e = entries[id], e.kind == .midi, e.receives,
              Peripheral.midiMessages(bytes) != nil else { return [] }
        return [Peripheral.midi(type: Peripheral.outputType, id: id, bytes: bytes)]
    }

    /// Run a result on a backend: create failures come back as the status 5
    /// messages to send.
    func run(_ result: PeripheralResult, on backend: PeripheralBackend) -> [PeripheralMessage] {
        var extra: [PeripheralMessage] = []
        for action in result.actions {
            switch action {
            case let .create(id, kind, name, mode, rumble, sends, receives):
                if !backend.create(id: id, kind: kind, name: name, mode: mode,
                                   rumble: rumble, sends: sends, receives: receives) {
                    extra += createFailed(id: id).messages
                }
            case let .applyController(id, state): backend.apply(id: id, state: state)
            case let .deliverMIDI(id, bytes): backend.deliverMIDI(id: id, bytes: bytes)
            case let .remove(id): backend.remove(id: id)
            }
        }
        return result.messages + extra
    }

    // MARK: steps

    private func attach(_ payload: Data, now: TimeInterval) -> PeripheralResult {
        let id: UInt32
        let description: PeripheralAttach?
        switch Peripheral.parseAttach(payload) {
        case .ignore: return .none
        case let .malformed(i): id = i; description = nil
        case let .attach(a): id = a.id; description = a
        }
        // An id is never used twice on one connection.
        guard !usedIds.contains(id), usedIds.count < Peripheral.maxAttachesPerConnection else { return .none }
        usedIds.insert(id)

        func answer(_ status: UInt8) -> PeripheralResult {
            PeripheralResult(messages: [Peripheral.status(id: id, status: status)], actions: [])
        }
        guard enabled else { return answer(Peripheral.Status.off) }
        guard let a = description, let kind = PeripheralKind(rawValue: a.kind) else {
            return answer(Peripheral.Status.unsupportedKind)
        }
        let mode: PeripheralMode
        switch kind {
        case .gamepad:
            switch support.gamepad {
            case .none: return answer(Peripheral.Status.unsupportedKind)
            case .virtualDevice: mode = .device
            case .keysAndPointer: mode = .keysAndPointer
            }
        case .midi:
            guard support.midi else { return answer(Peripheral.Status.unsupportedKind) }
            mode = .device
        }
        let gamepads = entries.values.filter { $0.kind == .gamepad }.count
        if entries.count >= Peripheral.maxPeripherals || (kind == .gamepad && gamepads >= Peripheral.maxGamepads) {
            return answer(Peripheral.Status.tooMany)
        }
        entries[id] = Entry(kind: kind, mode: mode, name: a.name,
                            rumble: kind == .gamepad && a.rumble,
                            sends: kind == .midi && a.sends,
                            receives: kind == .midi && a.receives,
                            lastReport: now)
        var result = answer(mode == .device ? Peripheral.Status.attached : Peripheral.Status.keysAndPointer)
        result.actions.append(.create(id: id, kind: kind, name: a.name, mode: mode,
                                      rumble: kind == .gamepad && a.rumble,
                                      sends: kind == .midi && a.sends,
                                      receives: kind == .midi && a.receives))
        return result
    }

    private func input(_ payload: Data, now: TimeInterval) -> PeripheralResult {
        guard payload.count >= 4 else { return .none }
        let id = payload.beUInt32(at: 0)
        guard var e = entries[id] else { return .none }
        switch e.kind {
        case .gamepad:
            guard let (_, state) = Peripheral.decodeGamepad(payload) else { return .none }
            e.lastReport = now
            let changed = state != e.state
            e.state = state
            entries[id] = e
            return changed ? PeripheralResult(messages: [], actions: [.applyController(id: id, state: state)]) : .none
        case .midi:
            guard e.sends, let (_, bytes) = Peripheral.decodeMIDI(payload),
                  let messages = Peripheral.midiMessages(bytes) else { return .none }
            for m in messages { e.midi.track(m) }
            entries[id] = e
            return PeripheralResult(messages: [], actions: [.deliverMIDI(id: id, bytes: bytes)])
        }
    }

    /// Put a peripheral at rest and remove it. `status` is sent when the
    /// removal is the host's doing; a detach by the client needs no answer.
    private func take(_ id: UInt32, status: UInt8?) -> PeripheralResult {
        guard let e = entries.removeValue(forKey: id) else { return .none }
        var result = PeripheralResult()
        switch e.kind {
        case .gamepad:
            if e.state != .rest { result.actions.append(.applyController(id: id, state: .rest)) }
        case .midi:
            if let off = e.midi.cleanup() { result.actions.append(.deliverMIDI(id: id, bytes: off)) }
        }
        result.actions.append(.remove(id: id))
        if let status { result.messages.append(Peripheral.status(id: id, status: status)) }
        return result
    }
}
