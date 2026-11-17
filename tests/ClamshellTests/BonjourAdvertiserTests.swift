import XCTest
@testable import Clamshell

/// What the host puts in its local-network announcement (PROTOCOL.md
/// "Discovery"). Nothing here talks to the discovery service; the
/// `discovery-selftest` command does that.
final class BonjourAdvertiserTests: XCTestCase {
    func testEntriesAreTheFourHintsOfTheSpecification() {
        let id = String(repeating: "0123456789abcdef", count: 4)
        let entries = BonjourAdvertiser.entries(hostId: id, name: "Studio")
        XCTAssertEqual(entries.map { $0.key }, ["v", "id", "name", "kind"])
        XCTAssertEqual(entries.map { $0.value }, ["1", "0123456789abcdef", "Studio", "mac"])
    }

    func testANameWithNothingToShowIsLeftOut() {
        // A right-to-left override and a bell: neither is shown anywhere.
        let entries = BonjourAdvertiser.entries(hostId: "abcd", name: "\u{202E}\u{0007}")
        XCTAssertEqual(entries.map { $0.key }, ["v", "id", "kind"])
        XCTAssertEqual(entries.map { $0.value }, ["1", "abcd", "mac"])
    }

    func testTheRecordIsLengthPrefixedKeyValuePairs() {
        let record = BonjourAdvertiser.txtRecord([("v", "1"), ("kind", "mac")])
        XCTAssertEqual(Array(record), [3] + Array("v=1".utf8) + [8] + Array("kind=mac".utf8))
    }

    func testAnEmptyRecordIsOneZeroByte() {
        XCTAssertEqual(Array(BonjourAdvertiser.txtRecord([])), [0])
    }

    func testEntriesThatCannotBeWrittenAreLeftOut() {
        // An "=" in the key, an empty key, a key outside printable ASCII.
        let record = BonjourAdvertiser.txtRecord([("a=b", "1"), ("", "1"), ("n\u{E9}", "1"), ("ok", "1")])
        XCTAssertEqual(Array(record), [4] + Array("ok=1".utf8))
    }

    func testAnEntryMayFillExactly255Bytes() {
        let fits = String(repeating: "x", count: 253) // "k=" and 253 more
        let record = BonjourAdvertiser.txtRecord([("k", fits)])
        XCTAssertEqual(record.count, 256)
        XCTAssertEqual(record.first, 255)
        XCTAssertEqual(Array(BonjourAdvertiser.txtRecord([("k", fits + "x")])), [0])
    }

    func testValuesAreCountedInUTF8Bytes() {
        // "name=" is 5 bytes and "Büro" is 5, the ü taking two.
        let record = BonjourAdvertiser.txtRecord([("name", "B\u{FC}ro")])
        XCTAssertEqual(record.first, 10)
        XCTAssertEqual(record.count, 11)
    }

    func testAskingAgainSlowsDownToEveryFiveMinutes() {
        XCTAssertEqual(BonjourAdvertiser.retryDelay(afterFailures: 0), 5)
        XCTAssertEqual(BonjourAdvertiser.retryDelay(afterFailures: 1), 5)
        XCTAssertEqual(BonjourAdvertiser.retryDelay(afterFailures: 2), 10)
        XCTAssertEqual(BonjourAdvertiser.retryDelay(afterFailures: 6), 160)
        XCTAssertEqual(BonjourAdvertiser.retryDelay(afterFailures: 7), 300)
        XCTAssertEqual(BonjourAdvertiser.retryDelay(afterFailures: 1000), 300)
    }

    func testARefusalForLocalNetworkAccessSaysWhereToAllowIt() {
        XCTAssertTrue(BonjourAdvertiser.describe(-65570).contains("Local Network"))
        XCTAssertEqual(BonjourAdvertiser.describe(-1), "DNS-SD error -1")
    }
}
