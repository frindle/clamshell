import XCTest
@testable import Clamshell

/// The client's controller reports (PROTOCOL.md "Game controllers").
final class ControllerReportTests: XCTestCase {
    // MARK: snapshot to report

    func testTheExampleInTheSpecificationComesOut() {
        var s = ControllerSnapshot()
        s.a = true
        s.left = true
        s.rightTrigger = 0.5
        s.leftX = 1
        let m = Peripheral.gamepadInput(id: 1, state: s.state)
        XCTAssertEqual(m.type, 0x53)
        XCTAssertEqual(Array(m.payload),
                       [0, 0, 0, 1,  0, 0, 0x40, 0x01,  0, 0x80,  0x7F, 0xFF,  0, 0,  0, 0,  0, 0])
    }

    func testEveryButtonHasItsBit() {
        func bits(_ f: (inout ControllerSnapshot) -> Void) -> UInt32 {
            var s = ControllerSnapshot(); f(&s); return s.state.buttons
        }
        XCTAssertEqual(bits { $0.a = true }, 1 << 0)
        XCTAssertEqual(bits { $0.b = true }, 1 << 1)
        XCTAssertEqual(bits { $0.x = true }, 1 << 2)
        XCTAssertEqual(bits { $0.y = true }, 1 << 3)
        XCTAssertEqual(bits { $0.leftShoulder = true }, 1 << 4)
        XCTAssertEqual(bits { $0.rightShoulder = true }, 1 << 5)
        XCTAssertEqual(bits { $0.view = true }, 1 << 8)
        XCTAssertEqual(bits { $0.menu = true }, 1 << 9)
        XCTAssertEqual(bits { $0.leftStickButton = true }, 1 << 10)
        XCTAssertEqual(bits { $0.rightStickButton = true }, 1 << 11)
        XCTAssertEqual(bits { $0.up = true }, 1 << 12)
        XCTAssertEqual(bits { $0.down = true }, 1 << 13)
        XCTAssertEqual(bits { $0.left = true }, 1 << 14)
        XCTAssertEqual(bits { $0.right = true }, 1 << 15)
        XCTAssertEqual(bits { $0.home = true }, 1 << 16)
        XCTAssertEqual(ControllerSnapshot().state, .rest)
    }

    func testYIsNegatedOnBothSticks() {
        var s = ControllerSnapshot()
        s.leftY = 1      // up on GameController
        s.rightY = -1    // down on GameController
        XCTAssertEqual(s.state.leftY, -32767, "up is negative on the wire")
        XCTAssertEqual(s.state.rightY, 32767, "down is positive on the wire")
        s.leftX = 1; s.rightX = -1
        XCTAssertEqual(s.state.leftX, 32767)
        XCTAssertEqual(s.state.rightX, -32767, "-32768 is never used")
    }

    func testValuesAreClampedAndOddOnesAreHarmless() {
        XCTAssertEqual(ControllerSnapshot.axis(5), 32767)
        XCTAssertEqual(ControllerSnapshot.axis(-5), -32767)
        XCTAssertEqual(ControllerSnapshot.axis(.nan), 0)
        XCTAssertEqual(ControllerSnapshot.axis(.infinity), 0)
        XCTAssertEqual(ControllerSnapshot.axis(0), 0)
        XCTAssertEqual(ControllerSnapshot.trigger(0), 0)
        XCTAssertEqual(ControllerSnapshot.trigger(1), 255)
        XCTAssertEqual(ControllerSnapshot.trigger(2), 255)
        XCTAssertEqual(ControllerSnapshot.trigger(-1), 0)
        XCTAssertEqual(ControllerSnapshot.trigger(.nan), 0)
        XCTAssertEqual(ControllerSnapshot.trigger(0.5), 128)
    }

    // MARK: attach and detach

    func testAttachAndDetachFollowTheSpecification() throws {
        let c = ControllerClient()
        let (id, attach) = c.connect(name: "Example Pad")
        XCTAssertEqual(id, 1)
        XCTAssertEqual(attach.type, 0x50)
        guard case let .attach(a) = Peripheral.parseAttach(attach.payload) else { return XCTFail("attach did not parse") }
        XCTAssertEqual(a.id, 1)
        XCTAssertEqual(a.kind, "gamepad")
        XCTAssertEqual(a.name, "Example Pad")
        XCTAssertFalse(a.rumble)
        XCTAssertEqual(c.rows.map(\.name), ["Example Pad"])

        let (id2, _) = c.connect(name: "")
        XCTAssertEqual(id2, 2)
        XCTAssertEqual(c.rows.last?.name, "Game controller", "a blank name gets a plain one")

        let detach = try XCTUnwrap(c.disconnect(id: 1))
        XCTAssertEqual(detach, Peripheral.detach(id: 1))
        XCTAssertNil(c.disconnect(id: 1), "twice sends nothing")
        let (id3, _) = c.connect(name: "Again")
        XCTAssertEqual(id3, 3, "ids are not reused")
    }

    // MARK: sending

    private func status(_ id: UInt32, _ s: UInt8) -> Data { Peripheral.status(id: id, status: s).payload }

    func testAChangeGoesOutAtOnceAndASoonerOneWaitsForTick() throws {
        let c = ControllerClient()
        let (id, _) = c.connect(name: "P")
        var s = ControllerSnapshot(); s.a = true
        XCTAssertEqual(c.input(id: id, s, now: 100), Peripheral.gamepadInput(id: id, state: s.state))
        var t = s; t.b = true
        XCTAssertNil(c.input(id: id, t, now: 100.001), "inside 4 ms: held back")
        XCTAssertEqual(c.tick(now: 100.002), [], "still inside 4 ms")
        XCTAssertEqual(c.tick(now: 100.005), [Peripheral.gamepadInput(id: id, state: t.state)],
                       "the last state always goes out")
        XCTAssertEqual(c.tick(now: 100.006), [], "and only once")
    }

    func testAnUnchangedStateIsNotSentAgainUntilTheRepeat() {
        let c = ControllerClient()
        let (id, _) = c.connect(name: "P")
        var s = ControllerSnapshot(); s.x = true
        XCTAssertNotNil(c.input(id: id, s, now: 10))
        XCTAssertNil(c.input(id: id, s, now: 10.5))
        XCTAssertEqual(c.tick(now: 10.5), [])
        XCTAssertEqual(c.tick(now: 11.0).count, 1, "a report at least once a second")
        XCTAssertEqual(c.tick(now: 11.5), [])
    }

    func testTheFirstStateIsSentEvenWhenItIsAtRest() {
        let c = ControllerClient()
        let (id, _) = c.connect(name: "P")
        XCTAssertEqual(c.input(id: id, ControllerSnapshot(), now: 1),
                       Peripheral.gamepadInput(id: id, state: .rest))
    }

    func testNothingIsSentAfterTheHostRefuses() {
        for refusal in [Peripheral.Status.unsupportedKind, Peripheral.Status.tooMany,
                        Peripheral.Status.off, Peripheral.Status.removed] {
            let c = ControllerClient()
            let (id, _) = c.connect(name: "P")
            c.receiveStatus(status(id, refusal))
            var s = ControllerSnapshot(); s.a = true
            XCTAssertNil(c.input(id: id, s, now: 5), "status \(refusal)")
            XCTAssertEqual(c.tick(now: 50), [], "status \(refusal)")
            XCTAssertEqual(c.rows.first?.status, refusal)
        }
    }

    func testStatus1KeepsSendingAndStatusOfAnotherIdIsIgnored() {
        let c = ControllerClient()
        let (id, _) = c.connect(name: "P")
        c.receiveStatus(status(id, Peripheral.Status.keysAndPointer))
        c.receiveStatus(status(99, Peripheral.Status.off))
        c.receiveStatus(Data("x".utf8))
        var s = ControllerSnapshot(); s.a = true
        XCTAssertNotNil(c.input(id: id, s, now: 5))
        XCTAssertEqual(c.rows.first?.status, 1)
    }

    func testRestReportsBeforeLeavingTheForeground() throws {
        let c = ControllerClient()
        let (id, _) = c.connect(name: "P")
        var s = ControllerSnapshot(); s.leftX = 1; s.a = true
        _ = c.input(id: id, s, now: 1)
        XCTAssertEqual(c.restReports(now: 2), [Peripheral.gamepadInput(id: id, state: .rest)])
    }

    func testANewConnectionAttachesEveryControllerAgain() throws {
        let c = ControllerClient()
        let (one, _) = c.connect(name: "One")
        let (two, _) = c.connect(name: "Two")
        c.receiveStatus(status(one, Peripheral.Status.off))
        let again = c.reconnect()
        XCTAssertEqual(again.map(\.type), [0x50, 0x50])
        XCTAssertEqual(c.rows.map(\.id), [one, two])
        XCTAssertEqual(c.rows.map(\.status), [nil, nil], "what the old host said no longer holds")
        var s = ControllerSnapshot(); s.a = true
        XCTAssertNotNil(c.input(id: one, s, now: 9), "sends again on the new connection")
    }

    // MARK: texts

    func testEveryStatusHasWords() {
        XCTAssertEqual(ControllerClient.statusText(nil), "waiting for the Mac")
        XCTAssertEqual(ControllerClient.statusText(1), "moves the pointer and sends keys")
        XCTAssertEqual(ControllerClient.statusText(2), "not supported by the Mac")
        XCTAssertEqual(ControllerClient.statusText(3), "the Mac has as many as it takes")
        XCTAssertEqual(ControllerClient.statusText(4), "turned off on the Mac")
        XCTAssertEqual(ControllerClient.statusText(5), "removed on the Mac")
        XCTAssertEqual(ControllerClient.statusText(77), "not accepted by the Mac")
    }
}
