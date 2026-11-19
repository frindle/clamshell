import XCTest
@testable import Clamshell

/// Records the events a controller produces, in order.
final class RecordingOutput: GamepadOutput {
    private(set) var events: [String] = []
    private(set) var moved: (dx: Float32, dy: Float32) = (0, 0)
    private(set) var scrolled: (dx: Float32, dy: Float32) = (0, 0)

    func mouseRelative(dx: Float32, dy: Float32) {
        moved = (moved.dx + dx, moved.dy + dy)
        events.append("move")
    }
    func mouseButtonAtCursor(button: UInt8, down: Bool) { events.append("button \(button) \(down ? "down" : "up")") }
    func scroll(dx: Float32, dy: Float32) {
        scrolled = (scrolled.dx + dx, scrolled.dy + dy)
        events.append("scroll")
    }
    func key(macKeyCode: UInt16, down: Bool, flags: UInt64) {
        events.append("key \(String(macKeyCode, radix: 16)) \(down ? "down" : "up")")
    }
    func reset() { events = []; moved = (0, 0); scrolled = (0, 0) }
    /// Button and key events only.
    var presses: [String] { events.filter { $0.hasPrefix("button") || $0.hasPrefix("key") } }
}

/// The Mac host's peripheral session and the controller mapping, driven with
/// the payloads in tests/vectors/peripheral-v1.json.
final class HostPeripheralSessionTests: XCTestCase {
    private typealias Dict = [String: Any]

    private lazy var root: Dict = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("vectors/peripheral-v1.json")
        return try! JSONSerialization.jsonObject(with: try! Data(contentsOf: url)) as! Dict
    }()

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

    /// The payload of the named gamepad vector (id 1 unless it says otherwise).
    private func vector(_ name: String) -> Data {
        let v = (root["gamepad"] as! [Dict]).first { $0["name"] as? String == name }!
        return hex(v["payload"] as! String)
    }

    private var hub: PeripheralHub!
    private var out: RecordingOutput!
    private var on = true

    override func setUp() {
        hub = PeripheralHub()
        out = RecordingOutput()
        on = true
    }

    private func makeSession() -> HostPeripheralSession {
        HostPeripheralSession(device: "Example Phone", output: out, mapping: .standard,
                              hub: hub, enabled: { self.on })
    }

    private func attach(_ s: HostPeripheralSession, id: UInt32, kind: String = "gamepad",
                        name: String = "Example Pad", now: TimeInterval = 0) -> [(UInt32, UInt8)] {
        let m = Peripheral.attach(id: id, kind: kind, name: name, rumble: false)
        return statuses(s.receive(type: m.type, payload: m.payload, now: now))
    }

    private func statuses(_ frames: [Data]) -> [(UInt32, UInt8)] {
        frames.compactMap { f in
            guard f[0] == Peripheral.statusType else { return nil }
            return Peripheral.decodeStatus(f.dropFirst(5)).map { ($0.id, $0.status) }
        }
    }

    private func input(_ s: HostPeripheralSession, _ payload: Data, now: TimeInterval = 0) {
        _ = s.receive(type: Peripheral.inputType, payload: payload, now: now)
    }

    // MARK: who may attach

    func testOnlyAnAcceptedDeviceWithBit6MayAttach() {
        XCTAssertTrue(HostPeripheralSession.allowed(phase: .accepted, capabilities: [.peripherals]))
        XCTAssertFalse(HostPeripheralSession.allowed(phase: .accepted, capabilities: [.fileTransfer]))
        XCTAssertFalse(HostPeripheralSession.allowed(phase: .accepted, capabilities: nil))
        for phase in [StreamLink.Phase.awaitingResponse, .open, .closed] {
            XCTAssertFalse(HostPeripheralSession.allowed(phase: phase, capabilities: [.peripherals]), "\(phase)")
        }
        XCTAssertEqual(StreamCapabilities.peripherals.rawValue, 1 << 6)
    }

    func testHostInfoListsGamepadOnly() {
        XCTAssertEqual(HostPeripheralSession.support.kinds, ["gamepad"])
    }

    // MARK: status

    func testAGamepadAnswersStatus1() {
        let s = makeSession()
        let r = attach(s, id: 1)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].0, 1)
        XCTAssertEqual(r[0].1, Peripheral.Status.keysAndPointer)
        XCTAssertEqual(hub.attached.map(\.name), ["Example Pad"])
        XCTAssertEqual(hub.attached.map(\.device), ["Example Phone"])
    }

    func testMIDIAndOtherKindsAnswerStatus2() {
        let s = makeSession()
        XCTAssertEqual(attach(s, id: 1, kind: "midi")[0].1, Peripheral.Status.unsupportedKind)
        XCTAssertEqual(attach(s, id: 2, kind: "joystick")[0].1, Peripheral.Status.unsupportedKind)
        XCTAssertTrue(s.attachedIds.isEmpty)
        XCTAssertTrue(hub.attached.isEmpty)
    }

    func testAtMostFourControllersPerConnection() {
        // The 8-peripheral limit cannot be reached through this host: it takes
        // only game controllers, so the 4-controller limit always bites first.
        // The 8 limit lives in the registry and is not tested separately.
        let s = makeSession()
        for id in 1...4 { XCTAssertEqual(attach(s, id: UInt32(id))[0].1, Peripheral.Status.keysAndPointer) }
        XCTAssertEqual(attach(s, id: 5)[0].1, Peripheral.Status.tooMany)
        XCTAssertEqual(s.attachedIds.count, 4)
        XCTAssertEqual(hub.attached.count, 4)
    }

    func testPeripheralsOffAnswersStatus4AndRemovesWhatIsAttached() {
        let s = makeSession()
        _ = attach(s, id: 1)
        on = false
        let removed = statuses(s.tick(now: 0.1))
        XCTAssertEqual(removed.map(\.0), [1])
        XCTAssertEqual(removed.map(\.1), [Peripheral.Status.off])
        XCTAssertEqual(attach(s, id: 2)[0].1, Peripheral.Status.off)
        XCTAssertTrue(hub.attached.isEmpty)
    }

    func testTheUserRemovingOneAnswersStatus5AndReleasesIt() {
        let s = makeSession()
        _ = attach(s, id: 1)
        input(s, vector("documented example"))
        out.reset()
        let r = statuses(s.removeByHost(id: 1))
        XCTAssertEqual(r.map(\.1), [Peripheral.Status.removed])
        XCTAssertEqual(out.presses, ["button 0 up", "key 7b up"])
        XCTAssertTrue(hub.attached.isEmpty)
    }

    // MARK: nothing is read before it is allowed

    func testInputForAnIdThatWasNeverAttachedDoesNothing() {
        let s = makeSession()
        input(s, vector("documented example"))
        XCTAssertTrue(out.events.isEmpty)
    }

    // MARK: mapping

    func testTheDocumentedExampleHoldsClickAndLeftArrow() {
        let s = makeSession()
        _ = attach(s, id: 1)
        input(s, vector("documented example"))
        XCTAssertEqual(out.presses, ["button 0 down", "key 7b down"])
        input(s, vector("at rest"), now: 0.1)
        XCTAssertEqual(out.presses, ["button 0 down", "key 7b down", "button 0 up", "key 7b up"])
    }

    func testEveryAssignedButtonPressesOnlyTheMappedOnes() {
        let s = makeSession()
        _ = attach(s, id: 1)
        input(s, vector("every assigned button"))
        XCTAssertEqual(Set(out.presses), [
            "button 0 down", "button 1 down",
            "key 7e down", "key 7d down", "key 7b down", "key 7c down", // arrows
            "key 24 down", "key 35 down",                               // Return, Escape
        ])
    }

    func testTheLeftStickMovesThePointerAndTheRightStickScrolls() {
        let s = makeSession()
        _ = attach(s, id: 1)
        // The report arrives at the time of the ticks: a controller that has
        // sent nothing for 3 s is put at rest.
        input(s, vector("stick extremes and the largest id").replacingId(1), now: 10)
        _ = s.tick(now: 10)
        _ = s.tick(now: 10.1)
        // Left stick fully left and down: pointer left and down (Y is down).
        XCTAssertLessThan(out.moved.dx, 0)
        XCTAssertGreaterThan(out.moved.dy, 0)
        // Right stick fully right and up: scroll right and up.
        XCTAssertGreaterThan(out.scrolled.dx, 0)
        XCTAssertGreaterThan(out.scrolled.dy, 0)
    }

    func testAStickInsideTheDeadZoneDoesNothing() {
        let s = makeSession()
        _ = attach(s, id: 1)
        var st = GamepadState()
        st.leftX = 3000; st.rightY = -3000
        input(s, Peripheral.gamepadInput(id: 1, state: st).payload)
        _ = s.tick(now: 1)
        _ = s.tick(now: 1.1)
        XCTAssertTrue(out.events.isEmpty)
    }

    func testTheCentreButtonsAreReturnAndEscape() {
        let s = makeSession()
        _ = attach(s, id: 1)
        var st = GamepadState()
        st.buttons = 1 << 9
        input(s, Peripheral.gamepadInput(id: 1, state: st).payload)
        st.buttons = 1 << 8
        input(s, Peripheral.gamepadInput(id: 1, state: st).payload, now: 0.1)
        XCTAssertEqual(out.presses, ["key 24 down", "key 24 up", "key 35 down"])
    }

    // MARK: release

    func testDetachReleasesEverything() {
        let s = makeSession()
        _ = attach(s, id: 1)
        input(s, vector("documented example"))
        out.reset()
        let m = Peripheral.detach(id: 1)
        _ = s.receive(type: m.type, payload: m.payload, now: 1)
        XCTAssertEqual(out.presses, ["button 0 up", "key 7b up"])
        XCTAssertEqual(s.heldCount, 0)
        XCTAssertTrue(hub.attached.isEmpty)
        // Further input for it does nothing.
        input(s, vector("documented example"), now: 2)
        XCTAssertEqual(out.presses, ["button 0 up", "key 7b up"])
    }

    func testTeardownReleasesEverythingOfEveryController() {
        let s = makeSession()
        _ = attach(s, id: 1)
        _ = attach(s, id: 2)
        input(s, vector("documented example"))
        var st = GamepadState()
        st.buttons = 1 << 15
        input(s, Peripheral.gamepadInput(id: 2, state: st).payload)
        out.reset()
        s.closeAll()
        XCTAssertEqual(Set(out.presses), ["button 0 up", "key 7b up", "key 7c up"])
        XCTAssertEqual(s.heldCount, 0)
        XCTAssertTrue(s.attachedIds.isEmpty)
        XCTAssertTrue(hub.attached.isEmpty)
    }

    func testASilentControllerIsRestedAfterThreeSeconds() {
        let s = makeSession()
        _ = attach(s, id: 1, now: 0)
        input(s, vector("documented example"), now: 0)
        out.reset()
        _ = s.tick(now: 2)
        XCTAssertTrue(out.presses.isEmpty)
        _ = s.tick(now: 3.5)
        XCTAssertEqual(out.presses, ["button 0 up", "key 7b up"])
    }

    func testTwoControllersOnTheSameKeyPressItOnceAndReleaseItLast() {
        let s = makeSession()
        _ = attach(s, id: 1)
        _ = attach(s, id: 2)
        var st = GamepadState()
        st.buttons = 1 << 12
        input(s, Peripheral.gamepadInput(id: 1, state: st).payload)
        input(s, Peripheral.gamepadInput(id: 2, state: st).payload)
        XCTAssertEqual(out.presses, ["key 7e down"])
        input(s, Peripheral.gamepadInput(id: 1, state: GamepadState()).payload, now: 0.1)
        XCTAssertEqual(out.presses, ["key 7e down"])
        input(s, Peripheral.gamepadInput(id: 2, state: GamepadState()).payload, now: 0.2)
        XCTAssertEqual(out.presses, ["key 7e down", "key 7e up"])
    }

    // MARK: the table

    func testTheMappingTableRoundTripsAndRefusesNonsense() throws {
        let data = try JSONEncoder().encode(GamepadMapping.standard)
        XCTAssertEqual(try JSONDecoder().decode(GamepadMapping.self, from: data), .standard)
        XCTAssertTrue(GamepadMapping.standard.isUsable)
        var bad = GamepadMapping.standard
        bad.buttons.append(.init(bit: 40, mouseButton: 0, macKeyCode: nil))
        XCTAssertFalse(bad.isUsable)
        bad = .standard
        bad.buttons.append(.init(bit: 3, mouseButton: 0, macKeyCode: 0x24))
        XCTAssertFalse(bad.isUsable)
        let suite = UserDefaults(suiteName: "clamshell-test-\(UUID().uuidString)")!
        XCTAssertEqual(GamepadMapping.load(from: suite), .standard)
        var custom = GamepadMapping.standard
        custom.pointerSpeed = 400
        custom.save(to: suite)
        XCTAssertEqual(GamepadMapping.load(from: suite).pointerSpeed, 400)
    }
}

private extension Data {
    /// The same gamepad payload under id 1 (the vector for the largest id).
    func replacingId(_ id: UInt32) -> Data {
        var d = self
        d.replaceSubrange(0..<4, with: [UInt8(id >> 24 & 0xFF), UInt8(id >> 16 & 0xFF), UInt8(id >> 8 & 0xFF), UInt8(id & 0xFF)])
        return d
    }
}
