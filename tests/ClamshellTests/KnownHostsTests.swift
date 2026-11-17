import XCTest
import CryptoKit
@testable import Clamshell

final class KnownHostsTests: XCTestCase {
    private func key() -> Data { P256.Signing.PrivateKey().publicKey.x963Representation }
    private func id(_ k: Data) -> String { DeviceIdentity.id(ofPublicKey: k) }

    func testNormalizeAddress() {
        XCTAssertEqual(KnownHosts.normalizeAddress("192.168.1.5"), "192.168.1.5:5903")
        XCTAssertEqual(KnownHosts.normalizeAddress(" Mac.Local:5904 "), "mac.local:5904")
        XCTAssertEqual(KnownHosts.normalizeAddress("ws://Mac.Example.com/ws/a"), "mac.example.com:80")
        XCTAssertEqual(KnownHosts.normalizeAddress("wss://mac.example.com/ws/b"), "mac.example.com:443")
        XCTAssertEqual(KnownHosts.normalizeAddress("wss://u:p@mac.example.com:8443/x?y=1#z"), "mac.example.com:8443")
        XCTAssertEqual(KnownHosts.normalizeAddress("ws://[fe80::1]:5903"), "[fe80::1]:5903")
        XCTAssertNil(KnownHosts.normalizeAddress(""))
        XCTAssertNil(KnownHosts.normalizeAddress("http://mac.local"))
        XCTAssertNil(KnownHosts.normalizeAddress("ws://mac.local:0"))
        XCTAssertNil(KnownHosts.normalizeAddress("ws://mac.local:99999"))
    }

    func testPathsOnOneHostnameAreOneAddress() {
        XCTAssertEqual(KnownHosts.normalizeAddress("wss://mac.example.com/ws/a"),
                       KnownHosts.normalizeAddress("wss://mac.example.com/ws/b"))
    }

    func testWhatIsKnownAboutAnAddress() {
        var k = KnownHosts()
        let a = key()
        XCTAssertEqual(k.standing(of: "10.0.0.1:5903"), .unknown)
        k.allowUnverified(address: "10.0.0.1")
        XCTAssertEqual(k.standing(of: "10.0.0.1"), .unknownAllowed)
        // Recording a verified host binds the address and clears the mark.
        k.recordVerified(key: a, name: "Studio", address: "ws://10.0.0.1:5903/ws/a", now: 5)
        XCTAssertEqual(k.standing(of: "10.0.0.1:5903"), .host(id: id(a)))
        XCTAssertTrue(k.isVerified(address: "10.0.0.1", forHost: id(a)))
        XCTAssertTrue(k.unverifiedAllowed.isEmpty)
        // An address that belongs to a host cannot be marked allowed.
        k.allowUnverified(address: "10.0.0.1")
        XCTAssertTrue(k.unverifiedAllowed.isEmpty)
    }

    func testBindingMovesAnAddressBetweenHostsAndKeepsOneHostPerKey() {
        var k = KnownHosts()
        let a = key(), b = key()
        k.recordVerified(key: a, name: "A", address: "10.0.0.1", now: 1)
        k.recordVerified(key: b, name: "B", address: "10.0.0.1", now: 2)
        XCTAssertEqual(k.standing(of: "10.0.0.1"), .host(id: id(b)))
        XCTAssertEqual(k.host(id: id(a))?.addresses, [])
        k.recordVerified(key: a, name: "A2", address: "10.0.0.2", now: 3)
        XCTAssertEqual(k.hosts.count, 2)
        XCTAssertEqual(k.host(id: id(a))?.name, "A2")
        k.bind(address: "10.0.0.3", toHostId: id(a), now: 4)
        XCTAssertEqual(k.standing(of: "10.0.0.3"), .host(id: id(a)))
        k.bind(address: "10.0.0.4", toHostId: String(repeating: "0", count: 64), now: 4)
        XCTAssertEqual(k.standing(of: "10.0.0.4"), .unknown)
    }

    func testHintsKeepTheSpecsLimits() {
        var k = KnownHosts()
        let a = key()
        k.recordVerified(key: a, name: "Studio", address: "10.0.0.1", now: 1)
        let tooLong = "ws://" + String(repeating: "a", count: 300) + ".example.com:5903"
        k.addHints(["ws://10.0.0.2:5903", "wss://mac.example.com/ws/a",
                    "http://10.0.0.3:5903", "ws://user:pw@10.0.0.4:5903", "ws://10.0.0.5:5903?x=1",
                    "ws://10.0.0.6:5903#f", tooLong, "10.0.0.7", "not a url"], toHostId: id(a), now: 2)
        let addresses = Set(k.host(id: id(a))!.addresses.map(\.address))
        XCTAssertEqual(addresses, ["10.0.0.1:5903", "10.0.0.2:5903", "mac.example.com:443"])
        XCTAssertEqual(k.host(id: id(a))!.addresses.filter { !$0.verified }.count, 2)
    }

    func testAHintCannotTakeAnAddressFromAnotherHost() {
        var k = KnownHosts()
        let a = key(), b = key()
        k.recordVerified(key: a, name: "A", address: "10.0.0.1", now: 1)
        k.recordVerified(key: b, name: "B", address: "10.0.0.2", now: 1)
        k.addHints(["ws://10.0.0.1:5903"], toHostId: id(b), now: 2)
        XCTAssertEqual(k.standing(of: "10.0.0.1"), .host(id: id(a)))
        XCTAssertEqual(k.host(id: id(b))!.addresses.count, 1)
    }

    func testAtMost16AddressesPerHostDroppingTheOneUnusedLongest() {
        var k = KnownHosts()
        let a = key()
        k.recordVerified(key: a, name: "Studio", address: "10.0.0.1", now: 100)
        for i in 2 ... 17 { k.addHints(["ws://10.0.0.\(i):5903"], toHostId: id(a), now: Double(i)) }
        let list = k.host(id: id(a))!.addresses
        XCTAssertEqual(list.count, 16)
        // The hint unused longest (10.0.0.2) went; the verified address stayed.
        XCTAssertNil(list.first { $0.address == "10.0.0.2:5903" })
        XCTAssertNotNil(list.first { $0.address == "10.0.0.1:5903" })
        XCTAssertNotNil(list.first { $0.address == "10.0.0.17:5903" })
    }

    func testDialOrderIsLastSuccessfulFirst() {
        var k = KnownHosts()
        let a = key()
        k.recordVerified(key: a, name: "Studio", address: "10.0.0.1", now: 10)
        k.addHints(["ws://10.0.0.2:5903", "ws://10.0.0.3:5903"], toHostId: id(a), now: 20)
        k.recordVerified(key: a, name: "Studio", address: "10.0.0.4", now: 30)
        XCTAssertEqual(k.dialOrder(hostId: id(a)), ["10.0.0.4:5903", "10.0.0.1:5903", "10.0.0.2:5903", "10.0.0.3:5903"])
        k.markDialled(address: "10.0.0.3", now: 40)
        XCTAssertEqual(k.dialOrder(hostId: id(a)).last, "10.0.0.2:5903")
    }

    func testForgettingRemovesTheKeyAndEveryAddress() {
        var k = KnownHosts()
        let a = key(), b = key()
        k.recordVerified(key: a, name: "A", address: "10.0.0.1", now: 1)
        k.addHints(["ws://10.0.0.2:5903"], toHostId: id(a), now: 1)
        k.recordVerified(key: b, name: "B", address: "10.0.0.9", now: 1)
        k.forget(hostId: id(a))
        XCTAssertNil(k.host(id: id(a)))
        XCTAssertEqual(k.standing(of: "10.0.0.1"), .unknown)
        XCTAssertEqual(k.standing(of: "10.0.0.2"), .unknown)
        XCTAssertEqual(k.standing(of: "10.0.0.9"), .host(id: id(b)))
    }

    func testStoringAndReadingBack() {
        var k = KnownHosts()
        let a = key()
        k.recordVerified(key: a, name: "Studio", address: "10.0.0.1", now: 1)
        k.addHints(["wss://mac.example.com/ws/a"], toHostId: id(a), now: 2)
        k.allowUnverified(address: "10.0.0.8")
        let (back, damaged) = KnownHosts.decode(k.encoded())
        XCTAssertFalse(damaged)
        XCTAssertEqual(back, k)
        let (empty, none) = KnownHosts.decode(nil)
        XCTAssertFalse(none)
        XCTAssertEqual(empty, KnownHosts())
    }

    func testADamagedStoreGivesAnEmptyOneAndSaysSo() {
        let (k, damaged) = KnownHosts.decode(Data("not json".utf8))
        XCTAssertTrue(damaged)
        XCTAssertEqual(k, KnownHosts())
        XCTAssertTrue(KnownHosts.decode(Data(#"{"version":1}"#.utf8)).damaged)
    }

    // MARK: A damaged saved copy is refused, not replaced

    private final class MemoryBlobs: KnownHostsBlobStore {
        var blobs: [String: Data] = [:]
        var writes: [String] = []
        func read(_ name: String) -> Data? { blobs[name] }
        func write(_ data: Data, as name: String) { blobs[name] = data; writes.append(name) }
        func remove(_ name: String) { blobs[name] = nil }
    }

    func testAMissingSavedCopyIsAnEmptyListAndWritesNothing() {
        let blobs = MemoryBlobs()
        let keeper = KnownHostsKeeper(blobs: blobs)
        XCTAssertNil(keeper.damage)
        XCTAssertEqual(keeper.hosts, KnownHosts())
        XCTAssertTrue(blobs.writes.isEmpty)
        XCTAssertNil(keeper.reset(at: Date()), "nothing is damaged, so there is nothing to put aside")
        // And it saves like any other.
        XCTAssertTrue(keeper.apply(.recordVerified(key: key(), name: "Example Mac", address: "10.0.0.1"), now: 1))
        XCTAssertNotNil(blobs.blobs[KnownHostsKeeper.blobName])
    }

    func testADamagedSavedCopyIsRefusedAndNeverWrittenOver() throws {
        let blobs = MemoryBlobs()
        let damaged = Data("{\"version\":1, \"hosts\": [".utf8)
        blobs.blobs[KnownHostsKeeper.blobName] = damaged
        let keeper = KnownHostsKeeper(blobs: blobs)
        XCTAssertNotNil(keeper.damage)
        XCTAssertEqual(keeper.hosts, KnownHosts(), "a damaged copy is not used")
        // What a connection attempt would do: it reports changes and dialled addresses.
        XCTAssertFalse(keeper.apply(.recordVerified(key: key(), name: "Example Mac", address: "10.0.0.1"), now: 1))
        XCTAssertFalse(keeper.apply(.allowUnverified(address: "10.0.0.2"), now: 2))
        keeper.markDialled(address: "10.0.0.1", now: 3)
        XCTAssertEqual(blobs.blobs, [KnownHostsKeeper.blobName: damaged], "the damaged bytes are exactly as they were")
        XCTAssertTrue(blobs.writes.isEmpty)
    }

    func testAnEntryThatCannotBeReadAlsoRefusesLikeTheWindowsFile() throws {
        var k = KnownHosts()
        k.recordVerified(key: key(), name: "A", address: "10.0.0.1", now: 1)
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: k.encoded()) as? [String: Any])
        var hosts = try XCTUnwrap(obj["hosts"] as? [[String: Any]])
        hosts.append(["name": "broken"])
        obj["hosts"] = hosts
        let blobs = MemoryBlobs()
        let data = try JSONSerialization.data(withJSONObject: obj)
        blobs.blobs[KnownHostsKeeper.blobName] = data
        let keeper = KnownHostsKeeper(blobs: blobs)
        XCTAssertNotNil(keeper.damage)
        XCTAssertEqual(blobs.blobs[KnownHostsKeeper.blobName], data)
    }

    func testResetKeepsTheDamagedCopyUnderANewNameAndStartsEmpty() throws {
        let blobs = MemoryBlobs()
        let damaged = Data("not json".utf8)
        blobs.blobs[KnownHostsKeeper.blobName] = damaged
        let keeper = KnownHostsKeeper(blobs: blobs)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let moment = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 11, day: 17,
                                                                  hour: 10, minute: 15, second: 0)))
        let kept = try XCTUnwrap(keeper.reset(at: moment))
        XCTAssertEqual(kept, "known-hosts.damaged-20261117T101500Z.json")
        XCTAssertEqual(blobs.blobs[kept], damaged, "the damaged bytes are kept, not deleted")
        XCTAssertNil(blobs.blobs[KnownHostsKeeper.blobName])
        XCTAssertNil(keeper.damage)
        XCTAssertEqual(keeper.hosts, KnownHosts())
        // Now a change saves, and the kept copy is still there.
        XCTAssertTrue(keeper.apply(.recordVerified(key: key(), name: "Example Mac", address: "10.0.0.1"), now: 1))
        XCTAssertEqual(blobs.blobs[kept], damaged)
        XCTAssertFalse(KnownHosts.decode(blobs.blobs[KnownHostsKeeper.blobName]).damaged)
        // A second damaged copy in the same second does not overwrite the first.
        blobs.blobs[KnownHostsKeeper.blobName] = Data("also not json".utf8)
        let again = KnownHostsKeeper(blobs: blobs)
        XCTAssertEqual(again.reset(at: moment), "known-hosts.damaged-20261117T101500Z-2.json")
        XCTAssertEqual(blobs.blobs[kept], damaged)
    }

    func testADamagedEntryNeverThrowsAwayTheEntriesThatCanBeRead() throws {
        var k = KnownHosts()
        let a = key(), b = key()
        k.recordVerified(key: a, name: "A", address: "10.0.0.1", now: 1)
        k.recordVerified(key: b, name: "B", address: "10.0.0.2", now: 1)
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: k.encoded()) as? [String: Any])
        var hosts = try XCTUnwrap(obj["hosts"] as? [[String: Any]])
        // One entry loses its fields, one gets a key that is not a point.
        hosts.append(["name": "broken"])
        hosts.append(["key": Data(repeating: 4, count: 65).base64EncodedString(), "name": "bad", "addresses": []])
        obj["hosts"] = hosts
        obj["unverifiedAllowed"] = ["10.0.0.8:5903", 7]
        let data = try JSONSerialization.data(withJSONObject: obj)
        let (back, damaged) = KnownHosts.decode(data)
        XCTAssertTrue(damaged)
        XCTAssertEqual(back.hosts.map(\.name).sorted(), ["A", "B"])
        XCTAssertEqual(back.standing(of: "10.0.0.1"), .host(id: id(a)))
        XCTAssertEqual(back.standing(of: "10.0.0.2"), .host(id: id(b)))
        XCTAssertEqual(back.standing(of: "10.0.0.8"), .unknownAllowed)
    }

    func testChangesApplyOneByOne() {
        var k = KnownHosts()
        let a = key()
        KnownHostsChange.recordVerified(key: a, name: "Studio", address: "10.0.0.1").apply(to: &k, now: 1)
        KnownHostsChange.hints(hostId: id(a), urls: ["ws://10.0.0.2:5903"]).apply(to: &k, now: 2)
        KnownHostsChange.bind(hostId: id(a), address: "10.0.0.3").apply(to: &k, now: 3)
        KnownHostsChange.allowUnverified(address: "10.0.0.4").apply(to: &k, now: 4)
        XCTAssertEqual(k.host(id: id(a))?.addresses.count, 3)
        XCTAssertEqual(k.standing(of: "10.0.0.4"), .unknownAllowed)
        KnownHostsChange.forget(hostId: id(a)).apply(to: &k, now: 5)
        XCTAssertTrue(k.hosts.isEmpty)
    }
}
