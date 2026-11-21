import XCTest
@testable import Clamshell

/// The files that let the browser client open full screen from a Home Screen
/// icon: the web app manifest and its icons ship in the bundle and are served
/// with the right types.
final class WebClientHomeScreenTests: XCTestCase {
    func testManifestIsServedAsAManifest() {
        XCTAssertEqual(WebServer.contentType(for: "webmanifest"), "application/manifest+json")
        XCTAssertEqual(WebServer.contentType(for: "png"), "image/png")
    }

    func testManifestAndIconsAreInTheBundle() throws {
        let root = try XCTUnwrap(WebServer.webclientRoot)
        for name in ["manifest.webmanifest", "icon-180.png", "icon-192.png", "icon-512.png", "fullscreen.js"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path), name)
        }
    }

    func testManifestOpensWithoutBrowserBarsAndKeepsTheAddedAddress() throws {
        let root = try XCTUnwrap(WebServer.webclientRoot)
        let data = try Data(contentsOf: root.appendingPathComponent("manifest.webmanifest"))
        let m = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(m["display"] as? String, "fullscreen")
        XCTAssertEqual(m["scope"] as? String, "/client")
        // No start_url: an icon added from /client?display=b opens Display B.
        XCTAssertNil(m["start_url"])
        let icons = try XCTUnwrap(m["icons"] as? [[String: Any]])
        for icon in icons {
            let src = try XCTUnwrap(icon["src"] as? String)
            XCTAssertTrue(src.hasPrefix("/client/"), src)
            let file = root.appendingPathComponent(String(src.dropFirst("/client/".count)))
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), src)
        }
    }
}
