import XCTest
@testable import Clamshell

final class ConnectionMonitorTests: XCTestCase {
    private let none = "Active Internet connections (including servers)\nProto Recv-Q Send-Q  Local Address          Foreign Address        (state)\n"

    func testNothingListeningOn5900MeansNoSession() {
        // The state of a Mac with Screen Sharing off: no 5900 rows at all.
        let conns = ConnectionMonitor.parseEstablished(netstat: none
            + "tcp4       0      0  10.0.0.2.5906          10.0.0.9.50111         ESTABLISHED\n")
        XCTAssertEqual(conns.count, 1)
        XCTAssertFalse(ConnectionMonitor.screenSharingSessionActive(in: conns))
        XCTAssertFalse(ConnectionMonitor.screenSharingSessionActive(in: []))
        XCTAssertTrue(ConnectionMonitor.parseEstablished(netstat: "").isEmpty)
    }

    func testRemoteClientOn5900IsASession() {
        let conns = ConnectionMonitor.parseEstablished(netstat: none
            + "tcp4       0      0  10.0.0.2.5900          10.0.0.9.50222         ESTABLISHED\n")
        XCTAssertTrue(ConnectionMonitor.screenSharingSessionActive(in: conns))
    }

    func testLoopbackOn5900IsNotASession() {
        let conns = ConnectionMonitor.parseEstablished(netstat: none
            + "tcp4       0      0  127.0.0.1.5900         127.0.0.1.50333        ESTABLISHED\n"
            + "tcp6       0      0  ::1.5900               ::1.50334              ESTABLISHED\n")
        XCTAssertFalse(ConnectionMonitor.screenSharingSessionActive(in: conns))
    }

    func testListenRowsAreIgnored() {
        let conns = ConnectionMonitor.parseEstablished(netstat: none
            + "tcp46      0      0  *.5900                 *.*                    LISTEN\n")
        XCTAssertTrue(conns.isEmpty)
    }
}
