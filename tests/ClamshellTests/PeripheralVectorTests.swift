import XCTest
@testable import Clamshell

/// Records what a registry asks of its backend.
final class RecordingBackend: PeripheralBackend {
    var refuseCreate = false
    private(set) var log: [String] = []
    func create(id: UInt32, kind: PeripheralKind, name: String, mode: PeripheralMode,
                rumble: Bool, sends: Bool, receives: Bool) -> Bool {
        log.append("create \(id) \(kind.rawValue)")
        return !refuseCreate
    }
    func apply(id: UInt32, state: GamepadState) { log.append("apply \(id)") }
    func deliverMIDI(id: UInt32, bytes: Data) { log.append("midi \(id)") }
    func remove(id: UInt32) { log.append("remove \(id)") }
}

/// Checks the peripheral core against tests/vectors/peripheral-v1.json
/// (PROTOCOL.md "Peripherals attached to the client"), plus the registry.
final class PeripheralVectorTests: XCTestCase {
    private typealias Dict = [String: Any]

    private lazy var root: Dict = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("vectors/peripheral-v1.json")
        let data = try! Data(contentsOf: url)
        return try! JSONSerialization.jsonObject(with: data) as! Dict
    }()

    private func list(_ key: String) -> [Dict] { root[key] as! [Dict] }
    private func hex(_ s: String) -> Data {
        var d = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            d.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return d
    }
    private func n(_ v: Any?) -> Int { (v as! NSNumber).intValue }
    private func u32(_ v: Any?) -> UInt32 { UInt32(truncating: v as! NSNumber) }

    private func state(_ v: Dict) -> GamepadState {
        GamepadState(buttons: UInt32(n(v["buttonBits"])),
                     leftTrigger: UInt8(n(v["leftTrigger"])), rightTrigger: UInt8(n(v["rightTrigger"])),
                     leftX: Int16(n(v["leftX"])), leftY: Int16(n(v["leftY"])),
                     rightX: Int16(n(v["rightX"])), rightY: Int16(n(v["rightY"])))
    }

    // MARK: vectors

    func testConstants() {
        let types = root["messageTypes"] as! [String: Int]
        XCTAssertEqual(types["PERIPHERAL_ATTACH"], Int(Peripheral.attachType))
        XCTAssertEqual(types["PERIPHERAL_STATUS"], Int(Peripheral.statusType))
        XCTAssertEqual(types["PERIPHERAL_DETACH"], Int(Peripheral.detachType))
        XCTAssertEqual(types["PERIPHERAL_INPUT"], Int(Peripheral.inputType))
        XCTAssertEqual(types["PERIPHERAL_OUTPUT"], Int(Peripheral.outputType))
    }

    func testAttachExample() {
        let ex = root["attachExample"] as! Dict
        let frame = hex(ex["frame"] as! String)
        XCTAssertEqual(frame[0], Peripheral.attachType)
        let expected = PeripheralAttach(id: 1, kind: "gamepad", name: "DualSense Wireless Controller",
                                        rumble: true, sends: false, receives: false)
        XCTAssertEqual(Peripheral.parseAttach(frame.subdata(in: 5 ..< frame.count)), .attach(expected))
        let built = Peripheral.attach(id: 1, kind: "gamepad", name: "DualSense Wireless Controller", rumble: true)
        XCTAssertEqual(built.type, Peripheral.attachType)
        XCTAssertEqual(Peripheral.parseAttach(built.payload), .attach(expected))
    }

    func testDetach() {
        let v = root["detach"] as! Dict
        let m = Peripheral.detach(id: u32(v["id"]))
        XCTAssertEqual(m.payload, hex(v["payload"] as! String))
        XCTAssertEqual(m.frame, hex(v["frame"] as! String))
        XCTAssertEqual(Peripheral.decodeDetach(m.payload), u32(v["id"]))
        XCTAssertNil(Peripheral.decodeDetach(Data([0, 0, 1])))
    }

    func testStatus() {
        for v in list("status") {
            let m = Peripheral.status(id: u32(v["id"]), status: UInt8(n(v["status"])))
            XCTAssertEqual(m.payload, hex(v["payload"] as! String))
            XCTAssertEqual(m.frame, hex(v["frame"] as! String))
            let d = Peripheral.decodeStatus(m.payload)
            XCTAssertEqual(d?.id, u32(v["id"]))
            XCTAssertEqual(d?.status, UInt8(n(v["status"])))
        }
    }

    func testGamepad() {
        for v in list("gamepad") {
            let name = v["name"] as! String
            let bits = (v["buttons"] as! [Int]).reduce(UInt32(0)) { $0 | (1 << UInt32($1)) }
            XCTAssertEqual(bits, UInt32(n(v["buttonBits"])), "\(name): button list vs bits")
            let s = state(v)
            let m = Peripheral.gamepadInput(id: u32(v["id"]), state: s)
            XCTAssertEqual(m.payload, hex(v["payload"] as! String), name)
            XCTAssertEqual(m.frame, hex(v["frame"] as! String), name)
            XCTAssertEqual(m.payload.count, 18, name)
            let d = Peripheral.decodeGamepad(hex(v["payload"] as! String))
            XCTAssertEqual(d?.id, u32(v["id"]), name)
            XCTAssertEqual(d?.state, s, name)
        }
    }

    func testGamepadDecodeOnly() {
        let examples = list("gamepad")
        for v in list("gamepadDecodeOnly") {
            let name = v["name"] as! String
            let d = Peripheral.decodeGamepad(hex(v["payload"] as! String))
            if (v["valid"] as? Bool) == false {
                XCTAssertNil(d, name)
            } else {
                let target = examples.first { ($0["name"] as! String) == (v["decodesAs"] as! String) }!
                XCTAssertEqual(d?.id, u32(target["id"]), name)
                XCTAssertEqual(d?.state, state(target), name)
            }
        }
    }

    func testStickMinimumIsNotUsed() {
        let p = Peripheral.gamepadInput(id: 1, state: GamepadState(leftX: .min, rightY: .min)).payload
        XCTAssertEqual(Peripheral.decodeGamepad(p)?.state.leftX, -32767)
        XCTAssertEqual(Peripheral.decodeGamepad(p)?.state.rightY, -32767)
        // Reserved button bits are dropped.
        var raw = Peripheral.gamepadInput(id: 1, state: .rest).payload
        raw.replaceSubrange(raw.startIndex + 4 ..< raw.startIndex + 8, with: [0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertEqual(Peripheral.decodeGamepad(raw)?.state.buttons, 0x1FF3F)
    }

    func testRumble() {
        for v in list("rumble") {
            let name = v["name"] as! String
            let m = Peripheral.rumble(id: u32(v["id"]), strong: UInt8(n(v["strong"])), weak: UInt8(n(v["weak"])),
                                      durationMs: UInt16(n(v["durationMs"])))
            XCTAssertEqual(m.payload, hex(v["payload"] as! String), name)
            XCTAssertEqual(m.frame, hex(v["frame"] as! String), name)
            let d = Peripheral.decodeRumble(m.payload)
            XCTAssertEqual(d?.id, u32(v["id"]), name)
            XCTAssertEqual(d?.strong, UInt8(n(v["strong"])), name)
            XCTAssertEqual(d?.weak, UInt8(n(v["weak"])), name)
            XCTAssertEqual(d?.durationMs, UInt16(n(v["durationMs"])), name)
        }
        XCTAssertNil(Peripheral.decodeRumble(Data(count: 7)))
    }

    func testMIDI() {
        for v in list("midi") {
            let name = v["name"] as! String
            let midi = hex(v["midi"] as! String)
            let payload = hex(v["payload"] as! String)
            XCTAssertEqual(payload, Peripheral.midi(type: Peripheral.inputType, id: u32(v["id"]), bytes: midi).payload, name)
            let d = Peripheral.decodeMIDI(payload)
            if (v["valid"] as! Bool) {
                XCTAssertEqual(d?.id, u32(v["id"]), name)
                XCTAssertEqual(d?.bytes, midi, name)
                XCTAssertEqual(hex(v["frame"] as! String),
                               Peripheral.midi(type: Peripheral.inputType, id: u32(v["id"]), bytes: midi).frame, name)
            } else {
                XCTAssertNil(d, name)
                // And a registry drops it.
                let r = PeripheralRegistry(support: PeripheralHostSupport(gamepad: .none, midi: true))
                let a = Peripheral.attach(id: u32(v["id"]), kind: "midi", name: "k", sends: true)
                _ = r.receive(type: a.type, payload: a.payload, now: 0)
                XCTAssertEqual(r.receive(type: Peripheral.inputType, payload: payload, now: 1), .none, name)
            }
        }
    }

    func testMIDILimits() {
        XCTAssertNotNil(Peripheral.midiMessages(Data(repeating: 0xF8, count: 65_536)))
        XCTAssertNil(Peripheral.midiMessages(Data(repeating: 0xF8, count: 65_537)))
        XCTAssertEqual(Peripheral.midiMessages(Data([0x90, 60, 100, 0xC0, 5, 0xF8]))?.count, 3)
        XCTAssertNil(Peripheral.midiMessages(Data([0x90, 60, 0x90, 100])))   // data byte with high bit
        XCTAssertNil(Peripheral.midiMessages(Data([0xF7])))                  // stray end of system exclusive
        XCTAssertNil(Peripheral.midiMessages(Data([0xF4, 0])))               // undefined
        XCTAssertNil(Peripheral.midiMessages(Data([0xF0, 1, 0x90, 60, 64, 0xF7]))) // status inside sysex
        XCTAssertNotNil(Peripheral.midiMessages(Data([0xF0, 1, 0xF8, 2, 0xF7])))   // real-time inside sysex
    }

    func testNamesAreCleaned() {
        XCTAssertEqual(Peripheral.cleanName("Pad\u{202E}\u{0007}\n 1"), "Pad 1")
        let long = String(repeating: "é", count: 40) // 80 bytes
        XCTAssertEqual(Peripheral.cleanName(long).utf8.count, 64)
        XCTAssertEqual(Peripheral.cleanName(long), String(repeating: "é", count: 32))
    }

    // MARK: registry

    private func attach(_ r: PeripheralRegistry, _ id: UInt32, kind: String = "gamepad", now: TimeInterval = 0,
                        rumble: Bool? = nil, sends: Bool? = nil, receives: Bool? = nil) -> PeripheralResult {
        let m = Peripheral.attach(id: id, kind: kind, name: "n\(id)", rumble: rumble, sends: sends, receives: receives)
        return r.receive(type: m.type, payload: m.payload, now: now)
    }

    private func report(_ r: PeripheralRegistry, _ id: UInt32, _ s: GamepadState, now: TimeInterval) -> PeripheralResult {
        let m = Peripheral.gamepadInput(id: id, state: s)
        return r.receive(type: m.type, payload: m.payload, now: now)
    }

    private func statusOf(_ result: PeripheralResult) -> [UInt8] {
        result.messages.compactMap { $0.type == Peripheral.statusType ? $0.payload.last : nil }
    }

    private func gamepadHost(_ g: PeripheralHostSupport.Gamepad = .virtualDevice) -> PeripheralRegistry {
        PeripheralRegistry(support: PeripheralHostSupport(gamepad: g, midi: true))
    }

    func testStatusAnswers() {
        XCTAssertEqual(statusOf(attach(gamepadHost(.virtualDevice), 1)), [0])
        XCTAssertEqual(statusOf(attach(gamepadHost(.keysAndPointer), 1)), [1])
        XCTAssertEqual(statusOf(attach(gamepadHost(.none), 1)), [2])
        XCTAssertEqual(statusOf(attach(gamepadHost(), 1, kind: "camera")), [2])
        XCTAssertEqual(statusOf(attach(PeripheralRegistry(support: PeripheralHostSupport(gamepad: .none, midi: false)), 1, kind: "midi", sends: true)), [2])
        XCTAssertEqual(statusOf(attach(PeripheralRegistry(support: PeripheralHostSupport(gamepad: .virtualDevice, midi: true), enabled: false), 1)), [4])
        // MIDI that neither sends nor receives, and a description with no kind.
        XCTAssertEqual(statusOf(attach(gamepadHost(), 1, kind: "midi")), [2])
        let noKind = receive(gamepadHost(), Peripheral.attachType, Data(#"{"id":4}"#.utf8))
        XCTAssertEqual(statusOf(noKind), [2])
        // No usable id: nothing to answer.
        XCTAssertEqual(receive(gamepadHost(), Peripheral.attachType, Data(#"{"id":0,"kind":"gamepad"}"#.utf8)), .none)
        XCTAssertEqual(receive(gamepadHost(), Peripheral.attachType, Data("nope".utf8)), .none)
    }

    private func receive(_ r: PeripheralRegistry, _ type: UInt8, _ payload: Data, now: TimeInterval = 0) -> PeripheralResult {
        r.receive(type: type, payload: payload, now: now)
    }

    func testAttachCreatesWithTheDescribedFields() {
        let r = gamepadHost()
        let result = attach(r, 3, rumble: true)
        XCTAssertEqual(result.actions, [.create(id: 3, kind: .gamepad, name: "n3", mode: .device,
                                                rumble: true, sends: false, receives: false)])
        XCTAssertTrue(r.isAttached(3))
    }

    func testAtMostFourGamepadsAndEightPeripherals() {
        let r = gamepadHost()
        for id in 1...4 { XCTAssertEqual(statusOf(attach(r, UInt32(id))), [0]) }
        XCTAssertEqual(statusOf(attach(r, 5)), [3])
        // MIDI still fits, up to 8 in all.
        for id in 6...9 { XCTAssertEqual(statusOf(attach(r, UInt32(id), kind: "midi", sends: true)), [0], "\(id)") }
        XCTAssertEqual(r.count, 8)
        XCTAssertEqual(statusOf(attach(r, 10, kind: "midi", sends: true)), [3])
        XCTAssertEqual(r.count, 8)
        // A slot freed by a detach is usable, with a new id.
        _ = receive(r, Peripheral.detachType, Peripheral.detach(id: 2).payload)
        XCTAssertEqual(statusOf(attach(r, 11)), [0])
        XCTAssertEqual(r.gamepadCount, 4)
    }

    func testIdsAreNeverReused() {
        let r = gamepadHost()
        XCTAssertEqual(statusOf(attach(r, 1)), [0])
        _ = receive(r, Peripheral.detachType, Peripheral.detach(id: 1).payload)
        XCTAssertFalse(r.isAttached(1))
        XCTAssertEqual(attach(r, 1), .none, "reuse after detach is ignored")
        XCTAssertFalse(r.isAttached(1))
        // Also an id that was refused, and one that is still attached.
        _ = attach(r, 2, kind: "camera")
        XCTAssertEqual(attach(r, 2), .none)
        _ = attach(r, 3)
        XCTAssertEqual(attach(r, 3), .none)
        // A late report for the old id does nothing.
        XCTAssertEqual(report(r, 1, GamepadState(buttons: 1), now: 5), .none)
    }

    func testInputOnlyForAttachedIds() {
        let r = gamepadHost()
        XCTAssertEqual(report(r, 1, GamepadState(buttons: 1), now: 0), .none)
        _ = attach(r, 1)
        XCTAssertEqual(report(r, 1, GamepadState(buttons: 1), now: 0).actions,
                       [.applyController(id: 1, state: GamepadState(buttons: 1))])
        // Short report ignored, state stays.
        let short = Peripheral.gamepadInput(id: 1, state: GamepadState(buttons: 2)).payload.dropLast()
        XCTAssertEqual(receive(r, Peripheral.inputType, Data(short)), .none)
        XCTAssertEqual(r.gamepadState(of: 1), GamepadState(buttons: 1))
        // Refused ids never take input.
        _ = attach(r, 2, kind: "camera")
        XCTAssertEqual(report(r, 2, GamepadState(buttons: 1), now: 0), .none)
    }

    func testRestAfterThreeSeconds() {
        let r = gamepadHost()
        _ = attach(r, 1, now: 10)
        let held = GamepadState(buttons: 1, rightTrigger: 255, leftX: 32767)
        XCTAssertEqual(report(r, 1, held, now: 10).actions.count, 1)
        XCTAssertEqual(r.tick(now: 12.5), .none)
        // A report (even an unchanged one) restarts the 3 s.
        XCTAssertEqual(report(r, 1, held, now: 12.5), .none)
        XCTAssertEqual(r.tick(now: 15.25), .none)
        XCTAssertEqual(r.tick(now: 15.5).actions, [.applyController(id: 1, state: .rest)])
        XCTAssertEqual(r.gamepadState(of: 1), .rest)
        // Already at rest: nothing more.
        XCTAssertEqual(r.tick(now: 30), .none)
        // The next report applies again.
        XCTAssertEqual(report(r, 1, held, now: 31).actions, [.applyController(id: 1, state: held)])
    }

    func testDetachAndCloseAllPutAtRestAndRemove() {
        let r = gamepadHost()
        _ = attach(r, 1)
        _ = attach(r, 2)
        _ = attach(r, 3)
        _ = report(r, 1, GamepadState(buttons: 1), now: 0)
        _ = report(r, 2, .rest, now: 0)
        XCTAssertEqual(receive(r, Peripheral.detachType, Peripheral.detach(id: 1).payload).actions,
                       [.applyController(id: 1, state: .rest), .remove(id: 1)])
        XCTAssertEqual(receive(r, Peripheral.detachType, Peripheral.detach(id: 1).payload), .none)
        _ = report(r, 3, GamepadState(leftY: 5), now: 0)
        let closed = r.closeAll()
        XCTAssertEqual(closed.actions, [.remove(id: 2), .applyController(id: 3, state: .rest), .remove(id: 3)])
        XCTAssertEqual(r.count, 0)
        XCTAssertEqual(r.closeAll(), .none)
        XCTAssertEqual(report(r, 3, GamepadState(buttons: 1), now: 1), .none)
    }

    func testHostRemovalAndTurnOff() {
        let r = gamepadHost()
        _ = attach(r, 1)
        _ = attach(r, 2)
        let removed = r.removeByHost(id: 1)
        XCTAssertEqual(statusOf(removed), [5])
        XCTAssertEqual(removed.actions, [.remove(id: 1)])
        let off = r.setEnabled(false)
        XCTAssertEqual(statusOf(off), [4])
        XCTAssertEqual(off.actions, [.remove(id: 2)])
        XCTAssertEqual(statusOf(attach(r, 3)), [4])
    }

    func testCreateFailureIsStatusFive() {
        let r = gamepadHost()
        let backend = RecordingBackend()
        backend.refuseCreate = true
        let messages = r.run(attach(r, 1), on: backend)
        XCTAssertEqual(messages.compactMap { $0.payload.last }, [0, 5])
        XCTAssertFalse(r.isAttached(1))
        XCTAssertEqual(report(r, 1, GamepadState(buttons: 1), now: 1), .none)
        XCTAssertEqual(backend.log, ["create 1 gamepad"])

        backend.refuseCreate = false
        let ok = r.run(attach(r, 2), on: backend)
        XCTAssertEqual(ok.compactMap { $0.payload.last }, [0])
        _ = r.run(report(r, 2, GamepadState(buttons: 1), now: 1), on: backend)
        _ = r.run(r.closeAll(), on: backend)
        XCTAssertEqual(backend.log, ["create 1 gamepad", "create 2 gamepad", "apply 2", "apply 2", "remove 2"])
    }

    func testRumbleOnlyWhenAttachedWithIt() {
        let r = gamepadHost()
        _ = attach(r, 1, rumble: true)
        _ = attach(r, 2)
        XCTAssertEqual(r.rumble(id: 1, strong: 255, weak: 64, durationMs: 250),
                       [Peripheral.rumble(id: 1, strong: 255, weak: 64, durationMs: 250)])
        XCTAssertEqual(r.rumble(id: 2, strong: 255, weak: 64, durationMs: 250), [])
        XCTAssertEqual(r.rumble(id: 9, strong: 255, weak: 64, durationMs: 250), [])
    }

    func testMIDIDirections() {
        let r = gamepadHost()
        _ = attach(r, 1, kind: "midi", sends: false, receives: true)
        _ = attach(r, 2, kind: "midi", sends: true, receives: false)
        let note = Data([0x90, 60, 100])
        // Id 1 does not send, so its input is dropped; id 2 does.
        XCTAssertEqual(receive(r, Peripheral.inputType, Peripheral.midi(type: Peripheral.inputType, id: 1, bytes: note).payload), .none)
        XCTAssertEqual(receive(r, Peripheral.inputType, Peripheral.midi(type: Peripheral.inputType, id: 2, bytes: note).payload).actions,
                       [.deliverMIDI(id: 2, bytes: note)])
        // Output only to an instrument that receives, and only whole messages.
        XCTAssertEqual(r.midiOutput(id: 1, bytes: note).count, 1)
        XCTAssertEqual(r.midiOutput(id: 2, bytes: note), [])
        XCTAssertEqual(r.midiOutput(id: 1, bytes: Data([0x90, 60])), [])
    }

    func testMIDIPeripheralThatLeavesEndsSoundingNotesAndSustain() {
        func send(_ r: PeripheralRegistry, _ id: UInt32, _ bytes: [UInt8]) {
            _ = receive(r, Peripheral.inputType, Peripheral.midi(type: Peripheral.inputType, id: id, bytes: Data(bytes)).payload)
        }
        let r = gamepadHost()
        _ = attach(r, 1, kind: "midi", sends: true)
        send(r, 1, [0x90, 60, 100, 0x90, 64, 100, 0x91, 67, 90])   // three notes
        send(r, 1, [0x80, 64, 0])                                    // one off
        send(r, 1, [0x90, 60, 0])                                    // note-on velocity 0 is an off too
        send(r, 1, [0xB0, 64, 127])                                  // sustain down on channel 1
        let left = receive(r, Peripheral.detachType, Peripheral.detach(id: 1).payload)
        XCTAssertEqual(left.actions, [
            .deliverMIDI(id: 1, bytes: Data([0x81, 67, 0, 0xB0, 64, 0])),
            .remove(id: 1),
        ])

        // Nothing left sounding: just the removal. Also for close-all.
        _ = attach(r, 2, kind: "midi", sends: true)
        send(r, 2, [0x90, 60, 100, 0x80, 60, 0, 0xB0, 64, 127, 0xB0, 64, 0])
        XCTAssertEqual(r.closeAll().actions, [.remove(id: 2)])

        _ = attach(r, 3, kind: "midi", sends: true)
        send(r, 3, [0x92, 50, 80, 0xB2, 123, 0])                     // all notes off
        XCTAssertEqual(r.closeAll().actions, [.remove(id: 3)])

        _ = attach(r, 4, kind: "midi", sends: true)
        send(r, 4, [0x90, 61, 80])
        XCTAssertEqual(r.removeByHost(id: 4).actions, [.deliverMIDI(id: 4, bytes: Data([0x80, 61, 0])), .remove(id: 4)])
    }

    func testHostSupportKinds() {
        XCTAssertEqual(PeripheralHostSupport(gamepad: .virtualDevice, midi: true).kinds, ["gamepad", "midi"])
        XCTAssertEqual(PeripheralHostSupport(gamepad: .none, midi: true).kinds, ["midi"])
        XCTAssertEqual(PeripheralHostSupport(gamepad: .keysAndPointer, midi: false).kinds, ["gamepad"])
    }
}
