import XCTest
@testable import Clamshell

/// A connection that has not been let in must not get a file or a peripheral
/// session. Driving the real listener needs network connections, so this checks
/// the wiring in the source text instead: it reads the sources and fails when
/// the code that creates these sessions moves somewhere that is not behind the
/// gate's admission. It does not run the host; the behaviour of `allowed(phase:)`
/// itself is covered in HostFileSessionTests and HostPeripheralSessionTests.
final class DeviceSessionWiringTests: XCTestCase {
    private var streaming: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Clamshell/Streaming", isDirectory: true)
    }

    /// The file's lines without comments.
    private func code(_ name: String) throws -> [String] {
        let text = try String(contentsOf: streaming.appendingPathComponent(name), encoding: .utf8)
        return text.components(separatedBy: "\n").filter {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return !t.hasPrefix("//")
        }
    }

    /// The name of the nearest `func` declared at or above line `index`.
    private func enclosingFunction(_ lines: [String], at index: Int) -> String {
        var i = index
        while i >= 0 {
            if let r = lines[i].range(of: "func ") {
                return String(lines[i][r.upperBound...].prefix(while: { $0 != "(" && $0 != "<" }))
            }
            i -= 1
        }
        return ""
    }

    private func allSwiftFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: streaming.path).filter { $0.hasSuffix(".swift") }.sorted()
    }

    func testStreamLinkNeverCreatesDeviceSessions() throws {
        let link = try code("StreamLink.swift").joined(separator: "\n")
        XCTAssertFalse(link.contains("HostFileSession("), "StreamLink creates a file session")
        XCTAssertFalse(link.contains("HostPeripheralSession("), "StreamLink creates a peripheral session")
        XCTAssertFalse(link.contains("DiskFileSink("), "StreamLink creates a file sink")
    }

    func testSessionsAreCreatedOnlyInStartDeviceSessions() throws {
        for needle in ["HostFileSession(", "HostPeripheralSession("] {
            var places: [String] = []
            for file in try allSwiftFiles() where file != "HostFileSession.swift" && file != "HostPeripheralSession.swift" {
                let lines = try code(file)
                for i in lines.indices where lines[i].contains(needle) {
                    places.append("\(file):\(enclosingFunction(lines, at: i))")
                }
            }
            XCTAssertEqual(places, ["StreamServer.swift:startDeviceSessions"], "\(needle) is created in \(places)")
        }
    }

    func testStartDeviceSessionsRunsOnlyFromAdmissionAndOnlyForADevice() throws {
        let lines = try code("StreamServer.swift")
        // Called from exactly one place, inside `admitted`, which the gate calls once a link is let in.
        let calls = lines.indices.filter { lines[$0].contains("startDeviceSessions(for:") && !lines[$0].contains("func ") }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(enclosingFunction(lines, at: calls.first ?? 0), "admitted")
        XCTAssertTrue(lines.contains { $0.contains("gate.onAdmit") && $0.contains("admitted") })

        // The body starts with the device check and gates each session on `allowed(phase:...)`.
        let text = lines.joined(separator: "\n")
        guard let start = text.range(of: "func startDeviceSessions(for link: StreamLink)") else {
            return XCTFail("startDeviceSessions not found")
        }
        let body = String(text[start.upperBound...].prefix(2500))
        XCTAssertTrue(body.contains("guard let device = link.device else { return }"))
        let fileGate = try XCTUnwrap(body.range(of: "HostFileSession.allowed(phase: link.phase"))
        let fileMake = try XCTUnwrap(body.range(of: "HostFileSession("))
        XCTAssertTrue(fileGate.lowerBound < fileMake.lowerBound)
        let periGate = try XCTUnwrap(body.range(of: "HostPeripheralSession.allowed(phase: link.phase"))
        let periMake = try XCTUnwrap(body.range(of: "HostPeripheralSession("))
        XCTAssertTrue(periGate.lowerBound < periMake.lowerBound)
    }

    func testGateAdmitsOnlyAfterAcceptance() throws {
        // `onAdmit` is the only way a link reaches the server; it is called after the phase is
        // set to accepted (a device behind it) or to open (a clear link that has no device).
        let lines = try code("StreamLink.swift")
        let admits = lines.indices.filter { lines[$0].contains("onAdmit(link)") }
        XCTAssertEqual(admits.count, 2)
        for i in admits {
            let before = lines[max(0, i - 8)..<i].joined(separator: "\n")
            XCTAssertTrue(before.contains("link.phase = .accepted") || before.contains("link.phase = .open"),
                          "onAdmit is not right after the phase became accepted or open")
        }
    }
}
