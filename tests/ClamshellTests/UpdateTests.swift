import XCTest
@testable import Clamshell

final class UpdateTests: XCTestCase {
    // Two Apple-signed apps that ship with every macOS: each is validly
    // signed, and they are different identities (different bundle IDs).
    private let calculator = "/System/Applications/Calculator.app"
    private let textEdit = "/System/Applications/TextEdit.app"

    func testBundleSatisfiesItsOwnRequirement() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: calculator))
        let requirement = try XCTUnwrap(CodeIdentity.designatedRequirement(at: calculator))
        XCTAssertTrue(CodeIdentity.text(requirement).contains("com.apple.calculator"))
        XCTAssertTrue(CodeIdentity.satisfies(calculator, requirement: requirement))
        XCTAssertTrue(CodeIdentity.sameIdentity(current: calculator, candidate: calculator))
    }

    func testDifferentAppIsNotTheSameIdentity() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: calculator)
                          && FileManager.default.fileExists(atPath: textEdit))
        XCTAssertFalse(CodeIdentity.sameIdentity(current: calculator, candidate: textEdit))
    }

    func testUnsignedOrMissingCodeNeverMatches() throws {
        let dir = NSTemporaryDirectory() + "clamshell-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let unsigned = dir + "/tool"
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: unsigned))
        XCTAssertNil(CodeIdentity.designatedRequirement(at: unsigned))
        XCTAssertFalse(CodeIdentity.sameIdentity(current: unsigned, candidate: unsigned))
        XCTAssertFalse(CodeIdentity.sameIdentity(current: dir + "/missing", candidate: unsigned))
        try XCTSkipUnless(FileManager.default.fileExists(atPath: calculator))
        XCTAssertFalse(CodeIdentity.sameIdentity(current: calculator, candidate: unsigned))
        XCTAssertFalse(CodeIdentity.sameIdentity(current: calculator, candidate: dir + "/missing"))
    }

    func testDmgAssetIsPickedFromReleaseJSON() {
        let json = """
        {"tag_name":"v9.9.9","assets":[
          {"name":"notes.txt","browser_download_url":"https://example.com/notes.txt"},
          {"name":"Clamshell-9.9.9.dmg","browser_download_url":"https://example.com/Clamshell-9.9.9.dmg"}]}
        """
        XCTAssertEqual(UpdateInstaller.dmgAssetURL(fromReleaseJSON: Data(json.utf8))?.absoluteString,
                       "https://example.com/Clamshell-9.9.9.dmg")
    }

    func testReleaseJSONWithoutUsableDmgIsRejected() {
        let noDmg = #"{"assets":[{"browser_download_url":"https://example.com/a.zip"}]}"#
        let plainHTTP = #"{"assets":[{"browser_download_url":"http://example.com/a.dmg"}]}"#
        let rateLimited = #"{"message":"API rate limit exceeded"}"#
        for body in [noDmg, plainHTTP, rateLimited, "not json", ""] {
            XCTAssertNil(UpdateInstaller.dmgAssetURL(fromReleaseJSON: Data(body.utf8)), body)
        }
    }
}
