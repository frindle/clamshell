import XCTest
@testable import Clamshell

final class DisplayEndpointTests: XCTestCase {
    private func b(_ a: String) -> String? { DisplayEndpoint.displayB(fromA: a) }

    func testPathRule() {
        XCTAssertEqual(b("wss://mac.example.com/ws/a"), "wss://mac.example.com/ws/b")
        XCTAssertEqual(b("wss://mac.example.com/prefix/ws/a"), "wss://mac.example.com/prefix/ws/b")
        // Path rule beats the label and port rules.
        XCTAssertEqual(b("ws://mac-a.example.com:5903/ws/a"), "ws://mac-a.example.com:5903/ws/b")
    }

    func testHostLabelRule() {
        XCTAssertEqual(b("wss://mac-a.example.com"), "wss://mac-b.example.com")
        XCTAssertEqual(b("wss://mac-a.example.com/stream"), "wss://mac-b.example.com/stream")
        XCTAssertEqual(b("ws://studio-a.local:5903"), "ws://studio-b.local:5903")
        XCTAssertEqual(b("studio-a.local"), "ws://studio-b.local:5903")
        // Only the first label counts, and only a "-a" suffix.
        XCTAssertEqual(b("ws://mac.a-a.example.com:5903"), "ws://mac.a-a.example.com:5904")
        XCTAssertEqual(b("ws://data.example.com:5903"), "ws://data.example.com:5904")
    }

    func testPortRule() {
        XCTAssertEqual(b("192.168.1.5"), "ws://192.168.1.5:5904")
        XCTAssertEqual(b("192.168.1.5:5903"), "ws://192.168.1.5:5904")
        XCTAssertEqual(b("ws://10.0.0.2:6000"), "ws://10.0.0.2:6001")
        XCTAssertEqual(b("mac.local"), "ws://mac.local:5904")
    }

    func testNoRuleApplies() {
        XCTAssertNil(b("wss://mac.example.com"))
        XCTAssertNil(b("wss://mac.example.com/stream"))
        XCTAssertNil(b(""))
        XCTAssertNil(b("   "))
        XCTAssertNil(b("http://mac.example.com:80"))
        XCTAssertNil(b("ws://mac.example.com:65535"))
    }

    func testNearbyURL() {
        XCTAssertEqual(NearbyHost.url(host: "192.168.1.20", port: 5903), "ws://192.168.1.20:5903")
        XCTAssertEqual(NearbyHost.url(host: "fe80::1%en0", port: 5903), "ws://[fe80::1]:5903")
        XCTAssertEqual(NearbyHost.url(host: "[fe80::1]", port: 5903), "ws://[fe80::1]:5903")
        XCTAssertNil(NearbyHost.url(host: "", port: 5903))
        XCTAssertNil(NearbyHost.url(host: "192.168.1.20", port: 0))
    }

    func testNearbyLabel() {
        XCTAssertEqual(NearbyHost.label(hint: "Studio", serviceName: "svc"), "Studio")
        XCTAssertEqual(NearbyHost.label(hint: nil, serviceName: "svc"), "svc")
        XCTAssertEqual(NearbyHost.label(hint: "  \n\t ", serviceName: "svc"), "svc")
        XCTAssertEqual(NearbyHost.label(hint: "A\u{7}B\nC", serviceName: "svc"), "ABC")
        XCTAssertEqual(NearbyHost.label(hint: String(repeating: "x", count: 100), serviceName: "svc").count, 60)
    }
}
