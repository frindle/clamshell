import XCTest
@testable import Clamshell

/// The offline-shell worker as the host serves it: placeholders filled, kill switch honoured.
final class ServiceWorkerScriptTests: XCTestCase {
    private let js = Data("const BUILD = '__BUILD__';\nconst KILL = '__KILL__' === 'true';\n".utf8)

    func testBuildAndEnabledAreFilledIn() {
        let out = String(decoding: WebServer.serviceWorkerScript(js, build: "1.2-7", enabled: true), as: UTF8.self)
        XCTAssertTrue(out.contains("const BUILD = '1.2-7';"))
        XCTAssertTrue(out.contains("'false' === 'true'"))
    }

    func testKillSwitchTurnsTheWorkerIntoASelfRemover() {
        let out = String(decoding: WebServer.serviceWorkerScript(js, build: "1.2-7", enabled: false), as: UTF8.self)
        XCTAssertTrue(out.contains("'true' === 'true'"))
        XCTAssertFalse(out.contains("__KILL__"))
    }

    func testBuildStringHasNoCharactersThatCouldBreakOutOfTheLiteral() {
        let b = WebServer.serviceWorkerBuild
        XCTAssertFalse(b.contains("'"))
        XCTAssertFalse(b.isEmpty)
    }
}
