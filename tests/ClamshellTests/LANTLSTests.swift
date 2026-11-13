import XCTest
import Network
@testable import Clamshell

final class LANTLSTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "clamshell.lantls.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testNothingConfiguredIsInert() {
        XCTAssertNil(LANTLS.paths(defaults: freshDefaults(), fileData: nil))
        XCTAssertNil(LANTLS.paths(defaults: freshDefaults(), fileData: Data("{}".utf8)))
        XCTAssertNil(LANTLS.paths(defaults: freshDefaults(), fileData: Data("not json".utf8)))
    }

    func testFileConfig() {
        let json = Data(#"{"cert": "/etc/c.pem", "key": "/etc/k.pem"}"#.utf8)
        XCTAssertEqual(LANTLS.paths(defaults: freshDefaults(), fileData: json),
                       LANTLS.Paths(cert: "/etc/c.pem", key: "/etc/k.pem"))
    }

    func testHalfConfiguredIsInert() {
        let d = freshDefaults()
        d.set("/etc/c.pem", forKey: LANTLS.certKey)
        XCTAssertNil(LANTLS.paths(defaults: d, fileData: nil))
        XCTAssertNil(LANTLS.paths(defaults: freshDefaults(), fileData: Data(#"{"cert": "/a"}"#.utf8)))
    }

    func testDefaultsWinOverFileAndTildeExpands() {
        let d = freshDefaults()
        d.set("~/c.pem", forKey: LANTLS.certKey)
        d.set("/k.pem", forKey: LANTLS.keyKey)
        let json = Data(#"{"cert": "/file/c.pem", "key": "/file/k.pem"}"#.utf8)
        let p = LANTLS.paths(defaults: d, fileData: json)
        XCTAssertEqual(p?.key, "/k.pem")
        XCTAssertEqual(p?.cert, (("~/c.pem") as NSString).expandingTildeInPath)
    }

    func testUnconfiguredParametersArePlainTCP() {
        // No identity loaded: listeners must be exactly what they were.
        LANTLS.reload()
        if LANTLS.identity == nil {
            XCTAssertNil(LANTLS.parameters().defaultProtocolStack.applicationProtocols.first.flatMap { $0 as? NWProtocolTLS.Options })
        }
    }
}
