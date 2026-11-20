import XCTest
@testable import Clamshell

/// Host-key pinning, the timeout and the log hygiene of "Unlock disk", with a fake SSH
/// transport that behaves like a library: it reports the server's key, and signs in
/// (records the password) only if the key was accepted.
final class DiskUnlockTests: XCTestCase {
    private final class FakeServer: SSHUnlockTransport, @unchecked Sendable {
        var fingerprint = "SHA256:AAAA"
        var passwordOK = true
        var reachable = true
        var hang = false
        private(set) var received: [String] = []
        func attempt(host: String, port: Int, username: String, password: String, connectTimeout: TimeInterval,
                     acceptHostKey: @escaping (String) async -> Bool) async -> SSHAttempt {
            if hang { try? await Task.sleep(nanoseconds: 5_000_000_000); return .failed }
            guard reachable else { return .connectFailed }
            guard await acceptHostKey(fingerprint) else { return .hostKeyRefused }
            received.append(password)
            return passwordOK ? .authenticated : .authFailed
        }
    }

    private final class Env: @unchecked Sendable {
        var pins = SSHHostPins()
        var asked: [String] = []
        var answer = true
        var lines: [String] = []
    }

    private func unlocker(_ server: FakeServer, _ env: Env, overall: TimeInterval = 5) -> DiskUnlocker {
        DiskUnlocker(transport: server, loadPins: { env.pins }, savePins: { env.pins = $0 },
                     askToTrust: { _, fp in env.asked.append(fp); return env.answer },
                     log: { env.lines.append($0) }, overallTimeout: overall)
    }

    private let secret = "Zebra-Quartz-19-synthetic"

    func testFirstKeyIsAskedOnceThenPinned() async {
        let server = FakeServer(), env = Env()
        let u = unlocker(server, env)
        let first = await u.unlock(host: "mac.example.com", username: "tester", password: secret)
        XCTAssertEqual(first, .unlocked)
        XCTAssertEqual(env.asked, ["SHA256:AAAA"])
        XCTAssertEqual(env.pins.pins["mac.example.com:22"], "SHA256:AAAA")
        let second = await u.unlock(host: "MAC.example.com", username: "tester", password: secret)
        XCTAssertEqual(second, .unlocked)
        XCTAssertEqual(env.asked.count, 1, "a pinned key is not asked about again")
    }

    func testDeclinedKeySendsNothingAndPinsNothing() async {
        let server = FakeServer(), env = Env()
        env.answer = false
        let r = await unlocker(server, env).unlock(host: "mac.example.com", username: "tester", password: secret)
        XCTAssertEqual(r, .hostKeyDeclined)
        XCTAssertTrue(server.received.isEmpty)
        XCTAssertTrue(env.pins.pins.isEmpty)
    }

    func testChangedKeyIsRefusedWithoutAsking() async {
        let server = FakeServer(), env = Env()
        env.pins.pin(endpoint: "mac.example.com:22", fingerprint: "SHA256:AAAA")
        server.fingerprint = "SHA256:BBBB"
        let r = await unlocker(server, env).unlock(host: "mac.example.com", username: "tester", password: secret)
        XCTAssertEqual(r, .hostKeyMismatch)
        XCTAssertTrue(server.received.isEmpty, "the password must not be sent to a key that does not match")
        XCTAssertTrue(env.asked.isEmpty)
        XCTAssertEqual(env.pins.pins["mac.example.com:22"], "SHA256:AAAA", "the pin is not replaced")
    }

    func testWrongPasswordUnreachableAndTimeout() async {
        let server = FakeServer(), env = Env()
        server.passwordOK = false
        let wrong = await unlocker(server, env).unlock(host: "h", username: "tester", password: secret)
        XCTAssertEqual(wrong, .wrongPassword)
        server.reachable = false
        let down = await unlocker(server, env).unlock(host: "h", username: "tester", password: secret)
        XCTAssertEqual(down, .unreachable)
        server.reachable = true
        server.hang = true
        let slow = await unlocker(server, env, overall: 0.2).unlock(host: "h", username: "tester", password: secret)
        XCTAssertEqual(slow, .timedOut)
    }

    func testPasswordAndUserNeverAppearInLogsOrMessages() async {
        let server = FakeServer(), env = Env()
        let u = unlocker(server, env)
        var texts: [String] = []
        for ok in [true, false] {
            server.passwordOK = ok
            texts.append(await u.unlock(host: "h", username: "tester-user", password: secret).text)
        }
        server.fingerprint = "SHA256:CCCC"
        texts.append(await u.unlock(host: "h", username: "tester-user", password: secret).text)
        let all = (env.lines + texts).joined(separator: "\n")
        XCTAssertFalse(all.contains(secret))
        XCTAssertFalse(all.contains("tester-user"))
        XCTAssertFalse(env.lines.isEmpty)
    }

    func testFingerprintFormatMatchesOpenSSH() {
        // SHA-256 of empty input, base64 without padding.
        XCTAssertEqual(SSHFingerprint.sha256(ofKeyBlob: Data()), "SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU")
    }
}
