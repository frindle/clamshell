import XCTest
import CryptoKit
@testable import Clamshell

/// How the host shares out the room in its tables by address group
/// (PROTOCOL.md "Host rules"). The helper and the group function are pure;
/// the tables are driven with a clock the test moves by hand.
final class RoomSharingTests: XCTestCase {
    private var dir: URL!
    private var clock = Date(timeIntervalSince1970: 1_794_000_000)

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clamshell-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func store() -> DeviceTrustStore {
        DeviceTrustStore(directory: dir, watch: false, now: { [unowned self] in self.clock })
    }

    private func newKey() -> Data { P256.Signing.PrivateKey().publicKey.x963Representation }

    private func ask(_ s: DeviceTrustStore, _ key: Data, from address: String, open: Bool = true) -> DeviceTrustStore.Answer {
        s.ask(publicKey: key, name: "Pad", address: address, group: AddressGroup.of(address),
              hasOpenConnection: { _ in open })
    }

    // MARK: the group function

    func testAddressGroups() {
        XCTAssertEqual(AddressGroup.of("192.0.2.7"), "192.0.2.7")
        XCTAssertEqual(AddressGroup.of(" 192.0.2.7 "), "192.0.2.7")
        XCTAssertEqual(AddressGroup.of("192.0.2.7:51000"), "192.0.2.7")
        XCTAssertEqual(AddressGroup.of("::ffff:192.0.2.7"), "192.0.2.7")
        XCTAssertEqual(AddressGroup.of("::FFFF:192.0.2.7"), "192.0.2.7")
        XCTAssertEqual(AddressGroup.of("::ffff:c000:207"), "192.0.2.7")
        XCTAssertEqual(AddressGroup.of("[::ffff:192.0.2.7]:443"), "192.0.2.7")
        // Any other IPv6 address is its first 64 bits, without port or scope.
        XCTAssertEqual(AddressGroup.of("2001:db8:1:2:3:4:5:6"), "2001:db8:1:2/64")
        XCTAssertEqual(AddressGroup.of("2001:db8:1:2:ffff::1"), "2001:db8:1:2/64")
        XCTAssertEqual(AddressGroup.of("2001:DB8::1"), "2001:db8:0:0/64")
        XCTAssertEqual(AddressGroup.of("[2001:db8::1]:443"), "2001:db8:0:0/64")
        XCTAssertEqual(AddressGroup.of("fe80::1%en0"), "fe80:0:0:0/64")
        XCTAssertEqual(AddressGroup.of("::1"), "0:0:0:0/64")
        XCTAssertEqual(AddressGroup.of("2001:db8::1"), AddressGroup.of("2001:db8::ffff:ffff:ffff:ffff"))
        XCTAssertNotEqual(AddressGroup.of("2001:db8:0:1::1"), AddressGroup.of("2001:db8:0:2::1"))
        // Nothing usable.
        for text in ["", " ", "unknown", "example.com", "300.1.1.1", "192.0.2", "[2001:db8::1", "2001:db8::g", "%en0", "::ffff:"] {
            XCTAssertEqual(AddressGroup.of(text), AddressGroup.unknown, text)
        }
    }

    // MARK: the helper

    private typealias Entry = RoomSharing.Entry

    private func entries(_ spec: [(String, Double, Bool)]) -> [Entry] {
        spec.map { Entry(group: $0.0, age: $0.1, removable: $0.2) }
    }

    func testRoomAndUnderShareAdmits() {
        let table = entries([("a", 5, true), ("a", 4, true), ("b", 3, true)])
        XCTAssertEqual(RoomSharing.decide(entries: [], size: 4, share: 2, group: "a"), .admit)
        XCTAssertEqual(RoomSharing.decide(entries: table, size: 4, share: 3, group: "a"), .admit)
        XCTAssertEqual(RoomSharing.decide(entries: table, size: 4, share: 2, group: "b"), .admit)
        XCTAssertEqual(RoomSharing.decide(entries: table, size: 4, share: 2, group: "new"), .admit)
    }

    func testGroupAtItsShareReplacesItsOwnFirstRemovable() {
        // Room in the table, but "a" has its two.
        let table = entries([("a", 5, true), ("b", 9, true), ("a", 8, true)])
        // The oldest of its own, not the oldest in the table.
        XCTAssertEqual(RoomSharing.decide(entries: table, size: 8, share: 2, group: "a"), .replace(2))
        // A tie goes to the entry that comes first.
        let tie = entries([("a", 7, true), ("a", 7, true)])
        XCTAssertEqual(RoomSharing.decide(entries: tie, size: 8, share: 2, group: "a"), .replace(0))
        // Entries that cannot be removed are skipped.
        let skip = entries([("a", 9, false), ("a", 1, true), ("b", 99, true)])
        XCTAssertEqual(RoomSharing.decide(entries: skip, size: 8, share: 2, group: "a"), .replace(1))
        // Nothing removable: turned away.
        let none = entries([("a", 9, false), ("a", 1, false), ("b", 99, true)])
        XCTAssertEqual(RoomSharing.decide(entries: none, size: 8, share: 2, group: "a"), .turnAway)
    }

    func testFullTableTakesFromTheGroupHoldingMost() {
        // a holds three, b two, c one; the table holds six.
        let table = entries([("a", 1, true), ("b", 50, true), ("a", 9, true), ("c", 60, true), ("b", 40, true), ("a", 3, true)])
        // c holds fewer than a: takes a's oldest, even though b and c hold older ones.
        XCTAssertEqual(RoomSharing.decide(entries: table, size: 6, share: 4, group: "c"), .replace(2))
        // A group that holds nothing does too.
        XCTAssertEqual(RoomSharing.decide(entries: table, size: 6, share: 4, group: "new"), .replace(2))
        // b holds two, a three: still fewer.
        XCTAssertEqual(RoomSharing.decide(entries: table, size: 6, share: 4, group: "b"), .replace(2))
        // The heaviest group itself is turned away.
        XCTAssertEqual(RoomSharing.decide(entries: table, size: 6, share: 4, group: "a"), .turnAway)
    }

    func testFullTableTurnsAwayWhenTheHeaviestGroupHasNothingRemovable() {
        let table = entries([("a", 1, false), ("a", 9, false), ("b", 50, true)])
        XCTAssertEqual(RoomSharing.decide(entries: table, size: 3, share: 3, group: "c"), .turnAway)
    }

    func testFullTableTurnsAwayAnArrivalThatHoldsAsManyAsTheHeaviest() {
        // Two groups with two each: neither holds fewer than the other.
        let table = entries([("a", 1, true), ("b", 2, true), ("a", 3, true), ("b", 4, true)])
        XCTAssertEqual(RoomSharing.decide(entries: table, size: 4, share: 3, group: "a"), .turnAway)
        XCTAssertEqual(RoomSharing.decide(entries: table, size: 4, share: 3, group: "b"), .turnAway)
        // One more group arrives holding none: takes from the group that comes first.
        XCTAssertEqual(RoomSharing.decide(entries: table, size: 4, share: 3, group: "c"), .replace(2))
    }

    // MARK: the waiting list

    func testFloodFromOneGroupCannotKeepAnotherGroupsDeviceOffTheList() {
        let s = store()
        let attacker = "198.51.100.9", owner = "192.0.2.20"
        var flood: [Data] = []
        // Three invented devices a minute from one group, as many as it may list.
        for _ in 0 ..< 3 {
            let key = newKey()
            flood.append(key)
            XCTAssertEqual(ask(s, key, from: attacker), .waiting)
        }
        XCTAssertEqual(ask(s, newKey(), from: attacker), .busy)
        // The owner's own device is not kept out by that.
        let mine = newKey()
        XCTAssertEqual(ask(s, mine, from: owner), .waiting)

        // The next minute the flood goes on: a fourth, then no more.
        clock += 61
        let fourth = newKey()
        XCTAssertEqual(ask(s, fourth, from: attacker), .waiting)
        clock += 61
        XCTAssertEqual(ask(s, newKey(), from: attacker, open: true), .busy)
        XCTAssertEqual(s.waiting().filter { AddressGroup.of($0.address) == attacker }.count, 4)
        // Mine is still listed and answered as waiting.
        XCTAssertEqual(s.state(of: DeviceIdentity.id(ofPublicKey: mine)), .waiting)
        XCTAssertEqual(ask(s, mine, from: owner), .waiting)
    }

    func testGroupAtItsShareReplacesOnlyAWaitingDeviceThatIsGoneAndLongUnseen() {
        let s = store()
        let attacker = "198.51.100.9"
        var keys: [Data] = []
        for _ in 0 ..< 4 {
            let key = newKey()
            keys.append(key)
            XCTAssertEqual(ask(s, key, from: attacker), .waiting)
            clock += 61
        }
        // At its share. Every device has a connection: nothing is replaced.
        XCTAssertEqual(ask(s, newKey(), from: attacker, open: true), .busy)
        // No connection, but seen a moment ago: nothing is replaced.
        clock += 1
        XCTAssertEqual(ask(s, keys[3], from: attacker), .waiting)
        XCTAssertEqual(ask(s, newKey(), from: attacker, open: false), .busy)
        XCTAssertEqual(s.waiting().count, 4)
        // Long unseen and no connection: the one seen least recently goes.
        clock += DeviceTrustStore.recentlySeen
        let late = newKey()
        XCTAssertEqual(ask(s, late, from: attacker, open: false), .waiting)
        XCTAssertNil(s.state(of: DeviceIdentity.id(ofPublicKey: keys[0])))
        XCTAssertEqual(s.state(of: DeviceIdentity.id(ofPublicKey: keys[1])), .waiting)
        XCTAssertEqual(s.waiting().count, 4)
    }

    func testFullListTakesFromTheGroupHoldingMost() {
        let s = store()
        // Four groups of four fill the list of sixteen.
        var first: [String: Data] = [:]
        for g in 1 ... 4 {
            for n in 0 ..< 4 {
                let key = newKey()
                if n == 0 { first["198.51.100.\(g)"] = key }
                XCTAssertEqual(ask(s, key, from: "198.51.100.\(g)"), .waiting)
                clock += 21
                if n == 2 { clock += 61 }
            }
        }
        XCTAssertEqual(s.waiting().count, 16)
        // Nobody has a connection and everybody was last seen long ago.
        clock += 3600
        let newcomer = newKey()
        XCTAssertEqual(ask(s, newcomer, from: "192.0.2.20", open: false), .waiting)
        XCTAssertEqual(s.waiting().count, 16)
        XCTAssertEqual(s.state(of: DeviceIdentity.id(ofPublicKey: newcomer)), .waiting)
        // The first group (it comes first among equals) lost its least recently seen.
        XCTAssertNil(s.state(of: DeviceIdentity.id(ofPublicKey: first["198.51.100.1"]!)))
    }

    func testWaitingDeviceAskingAgainCountsAsSeen() throws {
        let s = store()
        let key = newKey()
        XCTAssertEqual(ask(s, key, from: "192.0.2.20"), .waiting)
        let id = DeviceIdentity.id(ofPublicKey: key)
        let listed = try XCTUnwrap(s.record(id: id)).lastSeen
        clock += 11
        XCTAssertEqual(ask(s, key, from: "192.0.2.20"), .waiting)
        XCTAssertEqual(try XCTUnwrap(s.record(id: id)).lastSeen, listed + 11)
    }

    // MARK: the tables of connections

    func testSlowConnectionFromOneGroupSurvivesAFloodOfSilentOnesFromAnother() {
        let auth = HostAuth(directory: dir, requireApproval: true, watch: false)
        var closed: [String] = []
        let slow = auth.addUnanswered(group: "192.0.2.20") { closed.append("slow") }
        for n in 0 ..< 200 {
            _ = auth.addUnanswered(group: "198.51.100.9") { closed.append("flood \(n)") }
        }
        XCTAssertFalse(closed.contains("slow"))
        // The flood kept its own eight and gave way to itself.
        XCTAssertEqual(closed.count, 200 - HostAuth.maxUnansweredPerGroup)
        XCTAssertEqual(closed.first, "flood 0")
        XCTAssertEqual(closed.last, "flood \(200 - HostAuth.maxUnansweredPerGroup - 1)")
        auth.removeUnanswered(slow)
    }

    func testFullTableOfConnectionsMakesRoomForANewGroup() {
        let auth = HostAuth(directory: dir, requireApproval: true, watch: false)
        var closed: [String] = []
        for g in 1 ... 4 {
            for n in 0 ..< HostAuth.maxUnansweredPerGroup {
                _ = auth.addUnanswered(group: "198.51.100.\(g)") { closed.append("g\(g) #\(n)") }
            }
        }
        XCTAssertEqual(closed, [])
        // Full. A fifth group takes the oldest of the group that comes first.
        _ = auth.addUnanswered(group: "192.0.2.20") { closed.append("new") }
        XCTAssertEqual(closed, ["g1 #0"])
        // A group at its share gives up its own oldest, not another group's.
        _ = auth.addUnanswered(group: "198.51.100.2") { closed.append("g2 again") }
        XCTAssertEqual(closed, ["g1 #0", "g2 #0"])
    }

    func testWaitingConnectionsAreSharedByGroupAndTheOldestGivesWay() {
        let auth = HostAuth(directory: dir, requireApproval: true, watch: false)
        var closed: [String] = []
        func admit(_ device: String, _ group: String) -> HostAuth.Waiting? {
            auth.admitWaitingConnection(deviceId: device, group: group) { closed.append(device) }
        }
        XCTAssertNotNil(admit("a1", "g1"))
        XCTAssertNotNil(admit("a2", "g1"))
        XCTAssertNotNil(admit("a3", "g1"))
        // The group is at its share of three: a fourth takes the oldest's place.
        XCTAssertNotNil(admit("a4", "g1"))
        XCTAssertEqual(closed, ["a1"])
        XCTAssertFalse(auth.hasWaitingConnection(deviceId: "a1"))
        // Another group still has room and waits.
        let mine = admit("m1", "g2")
        XCTAssertNotNil(mine)
        XCTAssertTrue(auth.hasWaitingConnection(deviceId: "m1"))
        // A released place is free again.
        auth.releaseWaiting(mine!)
        XCTAssertFalse(auth.hasWaitingConnection(deviceId: "m1"))
        XCTAssertTrue(auth.hasWaitingConnection(deviceId: "a4"))
    }

    func testFullTableOfWaitingConnectionsKeepsRoomForAnotherGroup() {
        let auth = HostAuth(directory: dir, requireApproval: true, watch: false)
        var closed: [String] = []
        func admit(_ device: String, _ group: String) -> HostAuth.Waiting? {
            auth.admitWaitingConnection(deviceId: device, group: group) { closed.append(device) }
        }
        for (device, group) in [("a1", "g1"), ("a2", "g1"), ("a3", "g1"), ("b1", "g2"), ("b2", "g2"), ("b3", "g2"),
                                ("c1", "g3"), ("c2", "g3")] {
            XCTAssertNotNil(admit(device, group), device)
        }
        // Full. g3 holds two, g1 three: g3 takes the place of g1's oldest.
        XCTAssertNotNil(admit("c3", "g3"))
        XCTAssertEqual(closed, ["a1"])
        // Now g2 and g3 hold three each and g1 two. A new group takes the
        // oldest of g2, which comes first among the heaviest.
        XCTAssertNotNil(admit("d1", "g4"))
        XCTAssertEqual(closed, ["a1", "b1"])
        XCTAssertTrue(auth.hasWaitingConnection(deviceId: "d1"))
        XCTAssertFalse(auth.hasWaitingConnection(deviceId: "b1"))
    }
}
