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

final class SafeUpdateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: CLI parsing

    func testParseStatusAndRollback() {
        XCTAssertEqual(SafeUpdate.parse(["status"]), .status)
        XCTAssertEqual(SafeUpdate.parse(["rollback"]), .rollback)
        XCTAssertEqual(SafeUpdate.parse(["status", "x"]), .usage(SafeUpdate.usage))
        XCTAssertEqual(SafeUpdate.parse(["rollback", "--now"]), .usage(SafeUpdate.usage))
    }

    func testParseUpdateWithAndWithoutVersion() {
        XCTAssertEqual(SafeUpdate.parse(["update"]), .update(version: nil))
        XCTAssertEqual(SafeUpdate.parse(["update", "--version", "0.9.24"]), .update(version: "0.9.24"))
        XCTAssertEqual(SafeUpdate.parse(["update", "--version", "v0.9.24"]), .update(version: "v0.9.24"))
        for bad in [["update", "--version"], ["update", "0.9.24"], ["update", "--version", "../x"],
                    ["update", "--version", "latest"], ["update", "--version", "1.0", "extra"]] {
            XCTAssertEqual(SafeUpdate.parse(bad), .usage(SafeUpdate.usage), "\(bad)")
        }
    }

    func testParseHealthWatch() {
        XCTAssertEqual(SafeUpdate.parse(["health-watch", "--app", "/Applications/Clamshell.app"]),
                       .healthWatch(app: "/Applications/Clamshell.app", timeout: 90))
        XCTAssertEqual(SafeUpdate.parse(["health-watch", "--app", "/a.app", "--timeout", "5"]),
                       .healthWatch(app: "/a.app", timeout: 5))
        XCTAssertEqual(SafeUpdate.parse(["health-watch"]), .usage(SafeUpdate.usage))
    }

    func testCommandNamesCoverEveryParsedCommand() {
        XCTAssertEqual(SafeUpdate.commandNames, ["status", "update", "rollback", "health-watch"])
        XCTAssertTrue(SafeUpdate.commandNames.isDisjoint(with: DeviceCommands.names))
    }

    func testReleaseURLs() {
        XCTAssertEqual(SafeUpdate.releaseAPIURL(version: nil)?.lastPathComponent, "latest")
        XCTAssertEqual(SafeUpdate.releaseAPIURL(version: "0.9.24")?.path, "/repos/frindle/clamshell/releases/tags/v0.9.24")
        XCTAssertEqual(SafeUpdate.releaseAPIURL(version: "v0.9.24")?.path, "/repos/frindle/clamshell/releases/tags/v0.9.24")
        XCTAssertNil(SafeUpdate.releaseAPIURL(version: ""))
        XCTAssertNil(SafeUpdate.releaseAPIURL(version: "a/b"))
        XCTAssertNil(SafeUpdate.releaseAPIURL(version: "x1"))
    }

    // MARK: health check

    func testHealthyOnlyWhenOldGoneAndBothUp() {
        let now = t0.addingTimeInterval(10)
        XCTAssertEqual(SafeUpdate.decide(startedAt: t0, now: now, oldGone: true, webUp: true, streamUp: true), .healthy)
        XCTAssertEqual(SafeUpdate.decide(startedAt: t0, now: now, oldGone: false, webUp: true, streamUp: true), .waiting)
        XCTAssertEqual(SafeUpdate.decide(startedAt: t0, now: now, oldGone: true, webUp: false, streamUp: true), .waiting)
        XCTAssertEqual(SafeUpdate.decide(startedAt: t0, now: now, oldGone: true, webUp: true, streamUp: false), .waiting)
    }

    func testRollbackAfterTimeoutNamesWhatWasMissing() {
        let late = t0.addingTimeInterval(91)
        guard case .rollback(let reason) = SafeUpdate.decide(startedAt: t0, now: late, oldGone: true,
                                                              webUp: true, streamUp: false) else {
            return XCTFail("expected rollback")
        }
        XCTAssertTrue(reason.contains("no stream port bound"))
        XCTAssertFalse(reason.contains("web port"))
        guard case .rollback(let r2) = SafeUpdate.decide(startedAt: t0, now: late, oldGone: false,
                                                          webUp: false, streamUp: false) else {
            return XCTFail("expected rollback")
        }
        XCTAssertTrue(r2.contains("old process") && r2.contains("5901") && r2.contains("stream"))
    }

    func testHealthyAtTheDeadlineStillCountsAndEdgeIsExact() {
        XCTAssertEqual(SafeUpdate.decide(startedAt: t0, now: t0.addingTimeInterval(89.9), oldGone: true,
                                         webUp: false, streamUp: false), .waiting)
        XCTAssertEqual(SafeUpdate.decide(startedAt: t0, now: t0.addingTimeInterval(90), oldGone: true,
                                         webUp: true, streamUp: true), .healthy)
        if case .rollback = SafeUpdate.decide(startedAt: t0, now: t0.addingTimeInterval(90), oldGone: true,
                                              webUp: false, streamUp: true) {} else { XCTFail("expected rollback at 90 s") }
    }

    func testStaleMarkerNeverRollsBack() {
        XCTAssertEqual(SafeUpdate.decide(startedAt: t0, now: t0.addingTimeInterval(3 * 3600), oldGone: true,
                                         webUp: false, streamUp: false), .stale)
    }

    // MARK: rollback path

    func testRollbackPlanSelection() {
        XCTAssertEqual(SafeUpdate.rollbackPlan(previousExists: true, signatureValid: true, sameIdentity: true), .go)
        for (e, v, i) in [(false, true, true), (true, false, true), (true, true, false)] {
            if case .unavailable = SafeUpdate.rollbackPlan(previousExists: e, signatureValid: v, sameIdentity: i) {} else {
                XCTFail("expected unavailable for \(e) \(v) \(i)")
            }
        }
        XCTAssertEqual(SafeUpdate.rollbackPlan(previousExists: false, signatureValid: true, sameIdentity: true),
                       .unavailable("no previous version is kept"))
    }

    func testPreviousBundleLivesInTheStateFolderAtAFixedPath() {
        let state = URL(fileURLWithPath: "/tmp/state", isDirectory: true)
        XCTAssertEqual(SafeUpdate.previousBundle(in: state).path, "/tmp/state/previous/Clamshell.app")
        XCTAssertEqual(SafeUpdate.statusFile(in: state).lastPathComponent, "update-status.json")
    }

    func testCleanupNeverMatchesThePreviousBundle() {
        XCTAssertTrue(SafeUpdate.isStaleCopy(name: "clamshell-old-1234.app"))
        XCTAssertTrue(SafeUpdate.isStaleCopy(name: ".Clamshell-update-ABCD.app"))
        XCTAssertFalse(SafeUpdate.isStaleCopy(name: "Clamshell.app"))
        XCTAssertFalse(SafeUpdate.isStaleCopy(name: "previous"))
        XCTAssertFalse(SafeUpdate.isStaleCopy(name: "clamshell-old-1234"))
    }

    func testRollbackSwapPutsThePreviousBundleBackAndRefusesAMissingOne() throws {
        let dir = NSTemporaryDirectory() + "clamshell-test-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }
        let installed = dir + "/Clamshell.app"
        try fm.createDirectory(atPath: installed, withIntermediateDirectories: true)
        // Nothing kept: refused, installed app untouched.
        XCTAssertThrowsError(try SafeUpdateOps.rollbackSwap(installed: installed, previous: dir + "/previous/Clamshell.app"))
        XCTAssertTrue(fm.fileExists(atPath: installed))
        // An unsigned folder fails its signature check and is never swapped in.
        let previous = dir + "/previous/Clamshell.app"
        try fm.createDirectory(atPath: previous, withIntermediateDirectories: true)
        XCTAssertThrowsError(try SafeUpdateOps.rollbackSwap(installed: installed, previous: previous))
        XCTAssertTrue(fm.fileExists(atPath: previous))
        XCTAssertTrue(fm.fileExists(atPath: installed))
    }

    // MARK: records and process parsing

    func testRecordRoundTripAndLine() throws {
        let r = SafeUpdate.Record(at: t0, from: "0.9.24", to: "0.9.25", result: "rolled-back", reason: "not serving")
        let data = try XCTUnwrap(SafeUpdate.encode(r))
        XCTAssertEqual(SafeUpdate.decode(SafeUpdate.Record.self, from: data), r)
        XCTAssertTrue(r.line.hasSuffix("0.9.24 -> 0.9.25: rolled-back (not serving)"))
        XCTAssertNil(SafeUpdate.decode(SafeUpdate.Record.self, from: Data("junk".utf8)))
        let p = SafeUpdate.Pending(startedAt: t0, from: "a", to: "b", oldPID: 42, installedApp: "/x.app")
        XCTAssertEqual(SafeUpdate.decode(SafeUpdate.Pending.self, from: try XCTUnwrap(SafeUpdate.encode(p))), p)
    }

    func testParsePIDsDropsOwnAndJunk() {
        XCTAssertEqual(SafeUpdate.parsePIDs("101\n202\n 303 \nx\n\n", excluding: 202), [101, 303])
        XCTAssertEqual(SafeUpdate.parsePIDs("", excluding: 1), [])
    }

    func testPortProbeSeesAListener() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(fd, 1), 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        let port = UInt16(bigEndian: addr.sin_port)
        XCTAssertTrue(SafeUpdateOps.portAnswers(port))
        close(fd)
        XCTAssertFalse(SafeUpdateOps.portAnswers(port))
    }

    // MARK: launch agent plists

    private func plist(at path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func assertKeepAliveShape(_ p: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(p["Label"] as? String, SafeUpdate.agentLabel, file: file, line: line)
        XCTAssertEqual(p["RunAtLoad"] as? Bool, true, file: file, line: line)
        // Restart after a crash, not after a clean quit.
        XCTAssertEqual((p["KeepAlive"] as? [String: Any])?["SuccessfulExit"] as? Bool, false, file: file, line: line)
        XCTAssertGreaterThanOrEqual(p["ThrottleInterval"] as? Int ?? 0, 5, file: file, line: line)
        XCTAssertEqual(p["LimitLoadToSessionType"] as? String, "Aqua", file: file, line: line)
        // The kickstart that restarts the app must not take the watcher with it.
        XCTAssertEqual(p["AbandonProcessGroup"] as? Bool, true, file: file, line: line)
    }

    func testBundledAgentPlist() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let p = try plist(at: root.appendingPathComponent("scripts/launchagent/\(SafeUpdate.agentPlistName)").path)
        assertKeepAliveShape(p)
        XCTAssertEqual(p["BundleProgram"] as? String, "Contents/MacOS/Clamshell")
    }

    func testFallbackAgentPlistMatchesAndEscapes() throws {
        let text = SafeUpdate.fallbackAgentPlist(executable: "/Applications/Clam & <Shell>.app/Contents/MacOS/Clamshell")
        let p = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil) as? [String: Any])
        assertKeepAliveShape(p)
        XCTAssertEqual(p["ProgramArguments"] as? [String], ["/Applications/Clam & <Shell>.app/Contents/MacOS/Clamshell"])
        XCTAssertEqual(SafeUpdate.fallbackAgentURL(home: "/Users/x").path, "/Users/x/Library/LaunchAgents/com.frindle.clamshell.agent.plist")
    }
}
