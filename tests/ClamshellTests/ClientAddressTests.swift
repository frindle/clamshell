import XCTest
@testable import Clamshell

/// Which address a connection is grouped by when it comes through a proxy
/// (PROTOCOL.md "Host rules"). Pure: no sockets.
final class ClientAddressTests: XCTestCase {
    private func headers(_ pairs: (String, String)...) -> [(name: String, value: String)] {
        pairs.map { (name: $0.0, value: $0.1) }
    }

    private let loopbackOnly = TrustedProxies()

    func testCFConnectingIPComesFirst() {
        let got = ClientAddress.resolve(
            peer: "127.0.0.1",
            headers: headers(("X-Forwarded-For", "198.51.100.9"), ("CF-Connecting-IP", "203.0.113.5")),
            trusted: loopbackOnly)
        XCTAssertEqual(got, "203.0.113.5")
    }

    func testHeaderNamesIgnoreCase() {
        let got = ClientAddress.resolve(peer: "127.0.0.1", headers: headers(("cf-connecting-ip", "203.0.113.5")),
                                        trusted: loopbackOnly)
        XCTAssertEqual(got, "203.0.113.5")
    }

    func testTheRightMostUntrustedForwardedEntryIsUsed() {
        // The client wrote 192.0.2.1 itself; the proxy at 198.51.100.7 saw
        // 203.0.113.5 and appended it; 198.51.100.7 is a trusted proxy too.
        let trusted = TrustedProxies(["198.51.100.0/24"])
        let got = ClientAddress.resolve(
            peer: "198.51.100.7",
            headers: headers(("X-Forwarded-For", "192.0.2.1, 203.0.113.5, 198.51.100.8")),
            trusted: trusted)
        XCTAssertEqual(got, "203.0.113.5")
    }

    func testHeadersFromAnUntrustedPeerAreIgnored() {
        let got = ClientAddress.resolve(
            peer: "203.0.113.77",
            headers: headers(("CF-Connecting-IP", "192.0.2.1"), ("X-Forwarded-For", "192.0.2.2")),
            trusted: loopbackOnly)
        XCTAssertEqual(got, "203.0.113.77")
    }

    func testAListedProxyIsTrustedButAnUnlistedOneIsNot() {
        let h = headers(("CF-Connecting-IP", "203.0.113.5"))
        XCTAssertEqual(ClientAddress.resolve(peer: "198.51.100.7", headers: h, trusted: TrustedProxies(["198.51.100.7"])),
                       "203.0.113.5")
        XCTAssertEqual(ClientAddress.resolve(peer: "198.51.100.7", headers: h, trusted: loopbackOnly),
                       "198.51.100.7")
    }

    func testIPv6ClientsAndProxies() {
        let trusted = TrustedProxies(["2001:db8:aa::/48"])
        XCTAssertTrue(trusted.contains("2001:db8:aa:1::5"))
        XCTAssertFalse(trusted.contains("2001:db8:bb::5"))
        let got = ClientAddress.resolve(peer: "2001:db8:aa::1",
                                        headers: headers(("CF-Connecting-IP", "2001:db8:cc:1:2:3:4:5")),
                                        trusted: trusted)
        XCTAssertEqual(got, "2001:db8:cc:1:2:3:4:5")
        XCTAssertEqual(AddressGroup.of(got), "2001:db8:cc:1/64")
        XCTAssertEqual(ClientAddress.resolve(peer: "::1", headers: headers(("X-Forwarded-For", "[2001:db8:cc::9]:443")),
                                             trusted: loopbackOnly),
                       "2001:db8:cc::9")
    }

    func testLoopbackIsAlwaysTrusted() {
        for peer in ["127.0.0.1", "127.9.9.9", "::1", "::ffff:127.0.0.1"] {
            XCTAssertTrue(loopbackOnly.contains(peer), peer)
        }
        XCTAssertFalse(loopbackOnly.contains("192.0.2.1"))
        XCTAssertFalse(loopbackOnly.contains(""))
    }

    func testNothingParsableKeepsThePeer() {
        let cases: [[(name: String, value: String)]] = [
            [],
            headers(("CF-Connecting-IP", "not an address")),
            headers(("X-Forwarded-For", "unknown")),
            headers(("X-Forwarded-For", "")),
            // Only trusted proxies listed: no client to find.
            headers(("X-Forwarded-For", "127.0.0.1, ::1")),
        ]
        for h in cases {
            XCTAssertEqual(ClientAddress.resolve(peer: "127.0.0.1", headers: h, trusted: loopbackOnly), "127.0.0.1")
        }
    }

    func testTwoRelayedClientsLandInDifferentGroups() {
        let a = ClientAddress.resolve(peer: "127.0.0.1", headers: headers(("CF-Connecting-IP", "203.0.113.5")),
                                      trusted: loopbackOnly)
        let b = ClientAddress.resolve(peer: "127.0.0.1", headers: headers(("CF-Connecting-IP", "203.0.113.6")),
                                      trusted: loopbackOnly)
        XCTAssertNotEqual(AddressGroup.of(a), AddressGroup.of(b))
        // Without the headers they would share the relay's group.
        XCTAssertEqual(AddressGroup.of("127.0.0.1"), AddressGroup.of("127.0.0.1"))
    }

    func testTheStoredSettingIsAnArrayOfStrings() {
        XCTAssertTrue(TrustedProxies.fromStored(["192.0.2.0/24"]).contains("192.0.2.9"))
        XCTAssertFalse(TrustedProxies.fromStored("192.0.2.0/24").contains("192.0.2.9"))
        XCTAssertFalse(TrustedProxies.fromStored(nil).contains("192.0.2.9"))
        // An entry that cannot be read, or a range too wide for its family, is ignored.
        XCTAssertFalse(TrustedProxies(["nonsense", "192.0.2.0/33"]).contains("192.0.2.9"))
    }

    // MARK: - Which connection the upgrade headers belong to

    func testOneSetAndOneConnectionBind() {
        let queue = UpgradeHeaders()
        queue.connectionAccepted()
        queue.record(headers(("CF-Connecting-IP", "203.0.113.5")))
        XCTAssertEqual(queue.bindAtReady()?.first?.value, "203.0.113.5")
        // Nothing is left for the next one.
        queue.connectionAccepted()
        XCTAssertNil(queue.bindAtReady())
    }

    func testTwoConnectionsInFlightBindNeither() {
        let queue = UpgradeHeaders()
        queue.connectionAccepted()
        queue.connectionAccepted()
        queue.record(headers(("CF-Connecting-IP", "203.0.113.5")))
        queue.record(headers(("CF-Connecting-IP", "203.0.113.6")))
        XCTAssertNil(queue.bindAtReady())
        XCTAssertNil(queue.bindAtReady())
    }

    func testTwoSetsForOneConnectionBindNothing() {
        let queue = UpgradeHeaders()
        queue.connectionAccepted()
        queue.record(headers(("CF-Connecting-IP", "203.0.113.5")))
        queue.record(headers(("CF-Connecting-IP", "203.0.113.6")))
        XCTAssertNil(queue.bindAtReady())
    }

    func testAConnectionThatClosesBeforeReadyDropsTheSets() {
        // A plants a header set and drops. B arrives on its own and must not
        // get A's address.
        let queue = UpgradeHeaders()
        queue.connectionAccepted()
        queue.record(headers(("CF-Connecting-IP", "192.0.2.99")))
        queue.connectionClosedBeforeReady()
        queue.connectionAccepted()
        XCTAssertNil(queue.bindAtReady())
        // And the next honest pair binds again.
        queue.connectionAccepted()
        queue.record(headers(("CF-Connecting-IP", "203.0.113.5")))
        XCTAssertEqual(queue.bindAtReady()?.first?.value, "203.0.113.5")
    }

    func testAnOverlappingCloseDropsTheOtherConnectionsSetToo() {
        let queue = UpgradeHeaders()
        queue.connectionAccepted()   // A
        queue.connectionAccepted()   // B
        queue.record(headers(("CF-Connecting-IP", "203.0.113.5")))
        queue.record(headers(("CF-Connecting-IP", "203.0.113.6")))
        queue.connectionClosedBeforeReady()   // A drops
        XCTAssertNil(queue.bindAtReady())     // B gets nothing, not A's
    }

    func testSetsAgeOut() {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let queue = UpgradeHeaders(maxAge: 10, now: { clock })
        queue.connectionAccepted()
        queue.record(headers(("CF-Connecting-IP", "203.0.113.5")))
        clock = clock.addingTimeInterval(11)
        XCTAssertNil(queue.bindAtReady())

        queue.connectionAccepted()
        queue.record(headers(("CF-Connecting-IP", "203.0.113.6")))
        clock = clock.addingTimeInterval(9)
        XCTAssertEqual(queue.bindAtReady()?.first?.value, "203.0.113.6")
    }
}
