import XCTest
@testable import Clamshell

final class LoginCredentialsTests: XCTestCase {
    func testRoundTrip() throws {
        let c = LoginCredentials(user: "example", password: "pässwörd 🔑")
        XCTAssertEqual(LoginCredentials.decode(c.encode()), c)
    }

    func testWireFormatIsPinned() throws {
        let json = #"{"kind":"login","password":"pw","user":"u","v":1}"#
        XCTAssertEqual(String(decoding: LoginCredentials(user: "u", password: "pw").encode(), as: UTF8.self), json)
        XCTAssertEqual(LoginCredentials.decode(Data(json.utf8)), LoginCredentials(user: "u", password: "pw"))
        XCTAssertEqual(StreamMessageType.loginCredentials.rawValue, 0x5C)
        XCTAssertEqual(StreamCapabilities.loginCredentials.rawValue, 1 << 7)
    }

    func testRejectsWhatAClientMaySendNoMore() {
        func decode(_ s: String) -> LoginCredentials? { LoginCredentials.decode(Data(s.utf8)) }
        XCTAssertNil(decode(#"{"v":2,"kind":"login","user":"u","password":"p"}"#))
        XCTAssertNil(decode(#"{"v":1,"kind":"unlock","user":"u","password":"p"}"#))
        XCTAssertNil(decode(#"{"v":1,"kind":"login","user":"","password":"p"}"#))
        XCTAssertNil(decode(#"{"v":1,"kind":"login","user":"u","password":""}"#))
        XCTAssertNil(decode(#"{"v":1,"kind":"login","user":"u"}"#))
        XCTAssertNil(decode("not json"))
        // A tab or line break would be typed as a key press.
        XCTAssertNil(decode(#"{"v":1,"kind":"login","user":"u\tx","password":"p"}"#))
        XCTAssertNil(decode(#"{"v":1,"kind":"login","user":"u","password":"p\n"}"#))
        let long = String(repeating: "a", count: LoginCredentials.maxFieldBytes + 1)
        XCTAssertNil(decode(#"{"v":1,"kind":"login","user":"u","password":"\#(long)"}"#))
        XCTAssertNil(LoginCredentials.decode(Data(count: LoginCredentials.maxPayloadBytes + 1)))
    }

    func testNothingPrintsThePassword() {
        let c = LoginCredentials(user: "example", password: "hunter2-secret")
        for text in [c.description, c.debugDescription, "\(c)", String(describing: c)] {
            XCTAssertFalse(text.contains("hunter2"))
            XCTAssertFalse(text.contains("example"))
        }
    }

    /// The typed sequence is the name, Tab, the password, Return, as key presses
    /// and Unicode text through the same core as INPUT_TEXT.
    func testTypingSequence() {
        let core = InputCore(boundsProvider: { CGRect(x: 0, y: 0, width: 100, height: 100) },
                             displaysProvider: { [] }, cursorProvider: { .zero }, clock: { 0 },
                             doubleClickInterval: { 0.5 })
        let events = core.text(LoginCredentials(user: "bob", password: "pw1").typingPayload)
        XCTAssertEqual(events, [
            .text("bob"),
            .key(code: InputCore.tabKeyCode, down: true, flags: 0), .key(code: InputCore.tabKeyCode, down: false, flags: 0),
            .text("pw1"),
            .key(code: InputCore.returnKeyCode, down: true, flags: 0), .key(code: InputCore.returnKeyCode, down: false, flags: 0),
        ])
    }

    // MARK: when the host acts

    func testOnlyTheLoginWindowAgentOnAnEncryptedTrustedSessionTypes() {
        let caps: StreamCapabilities = [.loginCredentials, .textInput]
        XCTAssertTrue(LoginCredentialsPolicy.allowed(serving: true, phase: .accepted, capabilities: caps))
        // The ordinary app (not the agent).
        XCTAssertFalse(LoginCredentialsPolicy.allowed(serving: false, phase: .accepted, capabilities: caps))
        // Approval off: a session in the clear never types a password.
        XCTAssertFalse(LoginCredentialsPolicy.allowed(serving: true, phase: .open, capabilities: nil))
        XCTAssertFalse(LoginCredentialsPolicy.allowed(serving: true, phase: .pending, capabilities: caps))
        // The client did not say it sends logins.
        XCTAssertFalse(LoginCredentialsPolicy.allowed(serving: true, phase: .accepted, capabilities: [.textInput]))
        XCTAssertFalse(LoginCredentialsPolicy.allowed(serving: true, phase: .accepted, capabilities: nil))
    }

    func testRateLimit() {
        XCTAssertTrue(LoginCredentialsPolicy.rateAllows(last: nil, now: 0))
        XCTAssertFalse(LoginCredentialsPolicy.rateAllows(last: 10, now: 11))
        XCTAssertTrue(LoginCredentialsPolicy.rateAllows(last: 10, now: 10 + LoginCredentialsPolicy.minInterval))
    }
}
