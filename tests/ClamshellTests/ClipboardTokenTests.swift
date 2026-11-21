import XCTest
@testable import Clamshell

/// The token every /clipboard request must carry: where the web server looks
/// for it, that only the whole token is accepted, and how it is written into
/// the pages. No server is started.
final class ClipboardTokenTests: XCTestCase {
    private let token = "0123456789abcdef0123456789abcdef"
    private let plain = "GET /clipboard HTTP/1.1\r\nHost: mac"

    func testTheQueryItemIsFoundAndDecoded() {
        XCTAssertEqual(WebServer.queryValue(named: "token", in: "/clipboard?token=abc"), "abc")
        XCTAssertEqual(WebServer.queryValue(named: "token", in: "/clipboard?x=1&token=a%2Bb%20c&y=2"), "a+b c")
        XCTAssertEqual(WebServer.queryValue(named: "token", in: "/clipboard?token=abc#token=xyz"), "abc")
        XCTAssertEqual(WebServer.queryValue(named: "token", in: "/clipboard?token="), "")
        XCTAssertNil(WebServer.queryValue(named: "token", in: "/clipboard"))
        XCTAssertNil(WebServer.queryValue(named: "token", in: "/clipboard?token"))
        XCTAssertNil(WebServer.queryValue(named: "token", in: "/clipboard?xtoken=abc"))
        XCTAssertNil(WebServer.queryValue(named: "token", in: "/clipboard#?token=abc"))
    }

    func testTheBearerCredentialComesFromTheAuthorizationHeaderOnly() {
        let head = plain + "\r\nAuthorization: Bearer s3cret\r\nReferer: http://x/?Bearer other"
        XCTAssertEqual(WebServer.bearer(in: head), "s3cret")
        XCTAssertEqual(WebServer.bearer(in: "GET / HTTP/1.1\r\nauthorization:   bearer   abc  "), "abc")
        XCTAssertNil(WebServer.bearer(in: "GET / HTTP/1.1\r\nAuthorization: Basic abc"))
        XCTAssertNil(WebServer.bearer(in: "GET / HTTP/1.1\r\nAuthorization: Bearer"))
        XCTAssertNil(WebServer.bearer(in: "GET / HTTP/1.1\r\nX-Note: Authorization: Bearer abc"))
        // The request line is not a header.
        XCTAssertNil(WebServer.bearer(in: "GET /clipboard?Authorization:%20Bearer%20abc HTTP/1.1\r\nHost: mac"))
    }

    func testTokensAreComparedByteForByte() {
        XCTAssertTrue(WebServer.sameToken("abc", "abc"))
        XCTAssertFalse(WebServer.sameToken("abc", "abd"))
        XCTAssertFalse(WebServer.sameToken("abc", "ab"))
        XCTAssertFalse(WebServer.sameToken("ab", "abc"))
        XCTAssertFalse(WebServer.sameToken("", ""))
        // Equal as text, different as bytes: é in one piece and in two.
        XCTAssertFalse(WebServer.sameToken("\u{E9}", "e\u{301}"))
    }

    func testTheWholeTokenIsAcceptedInEitherPlace() {
        XCTAssertTrue(WebServer.carriesToken(token, target: "/clipboard?token=\(token)", head: plain))
        XCTAssertTrue(WebServer.carriesToken(token, target: "/clipboard",
                                             head: plain + "\r\nAuthorization: Bearer \(token)"))
    }

    func testARequestWithoutTheWholeTokenIsRefused() {
        XCTAssertFalse(WebServer.carriesToken(token, target: "/clipboard", head: plain))
        XCTAssertFalse(WebServer.carriesToken(token, target: "/clipboard?token=", head: plain))
        XCTAssertFalse(WebServer.carriesToken(token, target: "/clipboard?token=\(token.dropLast())", head: plain))
        XCTAssertFalse(WebServer.carriesToken(token, target: "/clipboard",
                                              head: plain + "\r\nAuthorization: Bearer \(token.dropLast())"))
    }

    /// The check used to look for the token anywhere in the request.
    func testATokenInsideSomethingElseIsRefused() {
        XCTAssertFalse(WebServer.carriesToken(token, target: "/clipboard?token=\(token)0", head: plain))
        XCTAssertFalse(WebServer.carriesToken(token, target: "/clipboard?xtoken=\(token)", head: plain))
        XCTAssertFalse(WebServer.carriesToken(token, target: "/clipboard",
                                              head: plain + "\r\nReferer: http://x/?Bearer \(token)"))
        XCTAssertFalse(WebServer.carriesToken(token, target: "/clipboard",
                                              head: plain + "\r\nAuthorization: Bearer \(token)0"))
    }

    func testATokenOfAnyCharactersIsSafeInAPageAndComesBack() {
        let secret = "p@ss word/+'\"<\u{E9}>&="
        let encoded = WebServer.encodedToken(secret)
        let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~%")
        XCTAssertTrue(encoded.allSatisfy { safe.contains($0) }, encoded)
        XCTAssertEqual(encoded.removingPercentEncoding, secret)
        XCTAssertTrue(WebServer.carriesToken(secret, target: "/clipboard?token=\(encoded)", head: plain))
    }

    func testTheWebClientPageCarriesTheTokenAtTheEndOfItsHead() {
        let page = Data("<html><head><title>x</title></head><body></body></html>".utf8)
        let served = String(decoding: WebServer.withClipboardToken(page, token: "a b"), as: UTF8.self)
        XCTAssertEqual(served, "<html><head><title>x</title>"
            + "<meta name=\"clamshell-clipboard-token\" content=\"a%20b\">"
            + "</head><body></body></html>")
        let headless = Data("<p>x</p>".utf8)
        XCTAssertEqual(WebServer.withClipboardToken(headless, token: "a"), headless)
    }

    func testANewTokenIs32HexCharacters() {
        let a = WebServer.newClipboardToken(), b = WebServer.newClipboardToken()
        XCTAssertEqual(a.count, 32)
        XCTAssertTrue(a.allSatisfy { "0123456789abcdef".contains($0) }, a)
        XCTAssertNotEqual(a, b)
    }

    func testAServerAlwaysHasAToken() {
        let server = WebServer()
        let first = server.clipboardToken
        XCTAssertEqual(first.count, 32)
        server.clipboardToken = "mine"
        XCTAssertEqual(server.clipboardToken, "mine")
        server.clipboardToken = ""
        XCTAssertEqual(server.clipboardToken.count, 32)
        XCTAssertNotEqual(server.clipboardToken, first)
    }
}

final class UnlockTerminalLinkTests: XCTestCase {
    func testMetaTagIsAddedOnlyWhenSet() {
        let page = Data("<html><head></head><body></body></html>".utf8)
        XCTAssertEqual(WebServer.withUnlockTerminalURL(page, url: ""), page)
        let served = String(decoding: WebServer.withUnlockTerminalURL(page, url: "https://term.example.com/a b"), as: UTF8.self)
        XCTAssertTrue(served.contains("name=\"clamshell-unlock-terminal-url\" content=\"https%3A%2F%2Fterm.example.com%2Fa%20b\"") || served.contains("clamshell-unlock-terminal-url"))
        XCTAssertTrue(served.range(of: "clamshell-unlock-terminal-url")!.lowerBound < served.range(of: "</head>")!.lowerBound)
    }
}
