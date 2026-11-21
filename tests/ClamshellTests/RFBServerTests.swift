import XCTest
@testable import Clamshell

private final class Flag {
    private let lock = NSLock()
    private var value: Bool
    init(_ v: Bool) { value = v }
    var on: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

private struct FixedAuth: RFBAuthenticator {
    func verify(user: String, password: String) -> Bool { user == "alice" && password == "correct horse" }
}

private final class RecordingSink: RFBInputSink {
    private let lock = NSLock()
    private(set) var log: [String] = []
    private func add(_ s: String) { lock.lock(); log.append(s); lock.unlock() }
    func mouseMove(x: Float, y: Float) { add("move \(x) \(y)") }
    func mouseButton(button: UInt8, down: Bool, x: Float, y: Float) { add("button \(button) \(down) \(x) \(y)") }
    func scroll(dx: Float, dy: Float) { add("scroll \(dx) \(dy)") }
    func key(code: UInt16, down: Bool, flags: UInt64) { add("key \(code) \(down) \(flags)") }
    func text(_ string: String) { add("text \(string)") }
    func releaseAll() { add("release") }
    var entries: [String] { lock.lock(); defer { lock.unlock() }; return log }
}

private func colour(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
    (UInt8(x % 256), UInt8((y * 3) % 256), UInt8((x / 16 + y / 16) % 2 == 0 ? 220 : 30))
}

final class RFBServerTests: XCTestCase {
    private var servers: [RFBServer] = []

    override func tearDown() {
        servers.forEach { $0.stop() }
        servers = []
        super.tearDown()
    }

    private func makeServer(width: Int = 150, height: Int = 90, enabled: Flag = Flag(true),
                            limiter: RFBRateLimiter = RFBRateLimiter(),
                            sink: RecordingSink? = nil,
                            source: RFBStaticFrameSource? = nil) -> (RFBServer, RFBStaticFrameSource, Flag) {
        let src = source ?? RFBStaticFrameSource(width: width, height: height, fill: colour)
        let s = RFBServer(options: .init(port: 0, failureDelay: 0), authenticator: FixedAuth(), source: src,
                          limiter: limiter, makeInput: { sink }, enabled: { enabled.on })
        s.log = { _ in }
        XCTAssertTrue(s.start())
        servers.append(s)
        return (s, src, enabled)
    }

    private func login(_ server: RFBServer, password: String = "correct horse") -> RFBClient? {
        guard let c = RFBClient(port: server.boundPort), c.negotiate() != nil,
              let r = c.authenticate(user: "alice", password: password), r.ok else { return nil }
        return c
    }

    // MARK: handshake and login

    func testOnlyAppleRemoteDesktopAuthenticationIsOffered() throws {
        let (server, _, _) = makeServer()
        let c = try XCTUnwrap(RFBClient(port: server.boundPort))
        let sec = try XCTUnwrap(c.negotiate())
        XCTAssertEqual(sec.types, [30])
        XCTAssertFalse(sec.types.contains(1), "no 'none'")
        XCTAssertFalse(sec.types.contains(2), "no VNC password")
    }

    func testChoosingAnotherSecurityTypeIsRefused() throws {
        let (server, _, _) = makeServer()
        let c = try XCTUnwrap(RFBClient(port: server.boundPort))
        _ = c.negotiate()
        c.write([1])   // "none"
        let head = try XCTUnwrap(c.read(4))
        XCTAssertEqual(RFBWire.readU32(head, 0), 1)
    }

    func testLoginSucceedsAndServerInitDescribesTheScreen() throws {
        let (server, _, _) = makeServer()
        let c = try XCTUnwrap(login(server))
        let info = try XCTUnwrap(c.initialise())
        XCTAssertEqual(info.width, 150)
        XCTAssertEqual(info.height, 90)
        XCTAssertEqual(info.format, RFBPixelFormat.standard)
        XCTAssertEqual(info.name, "Clamshell")
    }

    func testWrongPasswordIsRefusedWithAReason() throws {
        let (server, _, _) = makeServer()
        let c = try XCTUnwrap(RFBClient(port: server.boundPort))
        _ = c.negotiate()
        let r = try XCTUnwrap(c.authenticate(user: "alice", password: "wrong"))
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.reason, "Authentication failed.")
        XCTAssertTrue(c.sawEOF())
    }

    func testUnknownUserIsRefused() throws {
        let (server, _, _) = makeServer()
        let c = try XCTUnwrap(RFBClient(port: server.boundPort))
        _ = c.negotiate()
        let r = try XCTUnwrap(c.authenticate(user: "mallory", password: "correct horse"))
        XCTAssertFalse(r.ok)
    }

    func testGarbageInPlaceOfCredentialsIsRefusedNotCrashed() throws {
        let (server, _, _) = makeServer()
        let c = try XCTUnwrap(RFBClient(port: server.boundPort))
        _ = c.negotiate()
        c.write([30])
        _ = c.read(4 + 256)
        // A public value of zero is not allowed.
        c.write([UInt8](repeating: 7, count: 128) + [UInt8](repeating: 0, count: 128))
        let head = try XCTUnwrap(c.read(4))
        XCTAssertEqual(RFBWire.readU32(head, 0), 1)
    }

    func testTooManyFailuresLockThePeerOutForAWhile() throws {
        let limiter = RFBRateLimiter(perPeerLimit: 2, globalLimit: 50, window: 60)
        let (server, _, _) = makeServer(limiter: limiter)
        for _ in 0..<2 {
            let c = try XCTUnwrap(RFBClient(port: server.boundPort))
            _ = c.negotiate()
            XCTAssertEqual(c.authenticate(user: "alice", password: "nope")?.ok, false)
        }
        let c = try XCTUnwrap(RFBClient(port: server.boundPort))
        let sec = try XCTUnwrap(c.negotiate())
        XCTAssertTrue(sec.types.isEmpty)
        XCTAssertEqual(sec.reason, RFBServer.tooManyReason)
        // Even the right password is not tried while locked out.
        XCTAssertNil(login(server))
    }

    func testRateLimiterWindowAndSuccessReset() {
        var now: TimeInterval = 100
        let l = RFBRateLimiter(perPeerLimit: 2, globalLimit: 3, window: 60, now: { now })
        XCTAssertTrue(l.allowed(peer: "a"))
        l.recordFailure(peer: "a"); l.recordFailure(peer: "a")
        XCTAssertFalse(l.allowed(peer: "a"))
        XCTAssertTrue(l.allowed(peer: "b"))
        l.recordFailure(peer: "b")
        XCTAssertFalse(l.allowed(peer: "c"), "global limit")
        now += 61
        XCTAssertTrue(l.allowed(peer: "a"))
        l.recordFailure(peer: "a")
        l.recordSuccess(peer: "a")
        XCTAssertTrue(l.allowed(peer: "a"))
    }

    // MARK: the Screen Sharing switch

    func testSwitchOffRefusesNewClientsBeforeAnyLogin() throws {
        let flag = Flag(false)
        let (server, _, _) = makeServer(enabled: flag)
        let c = try XCTUnwrap(RFBClient(port: server.boundPort))
        let sec = try XCTUnwrap(c.negotiate())
        XCTAssertTrue(sec.types.isEmpty)
        XCTAssertEqual(sec.reason, RFBServer.offReason)
        XCTAssertEqual(server.clientCount, 0)
    }

    func testSwitchOffDropsAnOpenClientAndOnLetsNewOnesIn() throws {
        let flag = Flag(true)
        let (server, _, _) = makeServer(enabled: flag)
        let c = try XCTUnwrap(login(server))
        _ = try XCTUnwrap(c.initialise())
        let deadline = Date().addingTimeInterval(5)
        while server.clientCount == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertEqual(server.clientCount, 1)

        flag.on = false
        NotificationCenter.default.post(name: RemoteAccessSwitch.didChange, object: nil)
        XCTAssertTrue(c.sawEOF(), "the open session is closed")
        let gone = Date().addingTimeInterval(5)
        while server.clientCount > 0 && Date() < gone { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertEqual(server.clientCount, 0)

        flag.on = true
        XCTAssertNotNil(login(server))
    }

    func testSwitchOffWhileTheClientTypesTheLoginStillRefuses() throws {
        // The server rechecks after the password is verified.
        let flag = Flag(true)
        let src = RFBStaticFrameSource(width: 64, height: 64, fill: colour)
        let s = RFBServer(options: .init(port: 0, failureDelay: 0), authenticator: FixedAuth(), source: src,
                          makeInput: { nil }, enabled: { flag.on })
        s.log = { _ in }
        XCTAssertTrue(s.start()); servers.append(s)
        let c = try XCTUnwrap(RFBClient(port: s.boundPort))
        XCTAssertEqual(c.negotiate()?.types, [30])
        flag.on = false
        let r = try XCTUnwrap(c.authenticate(user: "alice", password: "correct horse"))
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.reason, RFBServer.offReason)
    }

    // MARK: updates

    private func assertMatches(_ rects: [RFBClient.Rect], file: StaticString = #filePath, line: UInt = #line) {
        for r in rects {
            guard let px = r.pixels else { XCTFail("no pixels", file: file, line: line); continue }
            for y in 0..<r.h { for x in 0..<r.w {
                let got = px[y * r.w + x], want = colour(r.x + x, r.y + y)
                if got != want { XCTFail("pixel \(r.x + x),\(r.y + y) differs", file: file, line: line); return }
            } }
        }
    }

    func testFullUpdateInZRLEDecodesToTheScreen() throws {
        let (server, _, _) = makeServer()
        let c = try XCTUnwrap(login(server))
        _ = try XCTUnwrap(c.initialise())
        c.setEncodings([RFBEncoding.zrle, RFBEncoding.raw])
        c.requestUpdate(incremental: false, x: 0, y: 0, w: 150, h: 90)
        let rects = try XCTUnwrap(c.readUpdate())
        XCTAssertTrue(rects.allSatisfy { $0.encoding == RFBEncoding.zrle })
        XCTAssertEqual(rects.reduce(0) { $0 + $1.w * $1.h }, 150 * 90)
        assertMatches(rects)
    }

    func testRawIsUsedWhenTheClientDoesNotAskForZRLE() throws {
        let (server, _, _) = makeServer()
        let c = try XCTUnwrap(login(server))
        _ = try XCTUnwrap(c.initialise())
        c.setEncodings([RFBEncoding.raw])
        c.requestUpdate(incremental: false, x: 0, y: 0, w: 150, h: 90)
        let rects = try XCTUnwrap(c.readUpdate())
        XCTAssertTrue(rects.allSatisfy { $0.encoding == RFBEncoding.raw })
        assertMatches(rects)
    }

    func testIncrementalUpdateSendsOnlyTheChangedTile() throws {
        let (server, src, _) = makeServer(width: 200, height: 130)
        let c = try XCTUnwrap(login(server))
        _ = try XCTUnwrap(c.initialise())
        c.setEncodings([RFBEncoding.zrle])
        c.requestUpdate(incremental: false, x: 0, y: 0, w: 200, h: 130)
        _ = try XCTUnwrap(c.readUpdate())
        src.set(x: 130, y: 70, (1, 2, 3))   // tile column 2, row 1
        c.requestUpdate(incremental: true, x: 0, y: 0, w: 200, h: 130)
        let rects = try XCTUnwrap(c.readUpdate())
        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects[0].x, 128)
        XCTAssertEqual(rects[0].y, 64)
        XCTAssertEqual(rects[0].w, 64)
        XCTAssertEqual(rects[0].h, 64)
        let px = try XCTUnwrap(rects[0].pixels)
        XCTAssertTrue(px[(70 - 64) * 64 + (130 - 128)] == (1, 2, 3))
    }

    func testClientPixelFormatIsHonoured() throws {
        let (server, _, _) = makeServer()
        let c = try XCTUnwrap(login(server))
        _ = try XCTUnwrap(c.initialise())
        let f565 = RFBPixelFormat(bitsPerPixel: 16, depth: 16, bigEndian: false, trueColour: true,
                                  redMax: 31, greenMax: 63, blueMax: 31, redShift: 11, greenShift: 5, blueShift: 0)
        c.setPixelFormat(f565)
        c.setEncodings([RFBEncoding.zrle])
        c.requestUpdate(incremental: false, x: 0, y: 0, w: 150, h: 90)
        let rects = try XCTUnwrap(c.readUpdate())
        let r = try XCTUnwrap(rects.first)
        let px = try XCTUnwrap(r.pixels)
        let want = f565.channels(of: f565.value(red: colour(r.x, r.y).0, green: colour(r.x, r.y).1, blue: colour(r.x, r.y).2))
        XCTAssertTrue(px[0] == want)
    }

    func testDisplaySizeChangeIsAnnouncedToClientsThatKnowDesktopSize() throws {
        let (server, src, _) = makeServer()
        let c = try XCTUnwrap(login(server))
        _ = try XCTUnwrap(c.initialise())
        c.setEncodings([RFBEncoding.zrle, RFBEncoding.desktopSize])
        c.requestUpdate(incremental: false, x: 0, y: 0, w: 150, h: 90)
        _ = try XCTUnwrap(c.readUpdate())
        src.replace(width: 100, height: 70, fill: colour)
        c.requestUpdate(incremental: true, x: 0, y: 0, w: 150, h: 90)
        let rects = try XCTUnwrap(c.readUpdate())
        XCTAssertEqual(rects.first?.encoding, RFBEncoding.desktopSize)
        XCTAssertEqual(rects.first?.w, 100)
        XCTAssertEqual(rects.first?.h, 70)
        c.requestUpdate(incremental: false, x: 0, y: 0, w: 100, h: 70)
        let full = try XCTUnwrap(c.readUpdate())
        XCTAssertEqual(full.reduce(0) { $0 + $1.w * $1.h }, 100 * 70)
    }

    func testSourceIsHeldOnlyWhileAClientIsConnected() throws {
        let (server, src, _) = makeServer()
        XCTAssertEqual(src.acquired, 0)
        let c = try XCTUnwrap(login(server))
        _ = try XCTUnwrap(c.initialise())
        XCTAssertEqual(src.acquired, 1)
        c.disconnect()
        let deadline = Date().addingTimeInterval(5)
        while src.acquired != 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertEqual(src.acquired, 0)
    }

    // MARK: input

    func testKeyboardAndPointerReachTheInputSinkAndReleaseOnDisconnect() throws {
        let sink = RecordingSink()
        let (server, _, _) = makeServer(sink: sink)
        let c = try XCTUnwrap(login(server))
        _ = try XCTUnwrap(c.initialise())
        c.key(0x61, down: true)       // typed text
        c.key(0x61, down: false)
        c.pointer(mask: 1, x: 75, y: 45)
        c.pointer(mask: 0, x: 75, y: 45)
        c.requestUpdate(incremental: false, x: 0, y: 0, w: 1, h: 1)   // a round trip so the above were read
        _ = c.readUpdate()
        XCTAssertTrue(sink.entries.contains("text a"))
        XCTAssertTrue(sink.entries.contains("button 0 true 0.5 0.5"))
        XCTAssertTrue(sink.entries.contains("button 0 false 0.5 0.5"))
        c.disconnect()
        let deadline = Date().addingTimeInterval(5)
        while !sink.entries.contains("release") && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertTrue(sink.entries.contains("release"))
    }

    func testKeyboardMapping() {
        let sink = RecordingSink()
        let k = RFBKeyboard(sink: sink)
        k.key(keysym: 0xFF0D, down: true); k.key(keysym: 0xFF0D, down: false)          // Return
        k.key(keysym: 0xFFE3, down: true)                                               // Control
        k.key(keysym: 0x63, down: true); k.key(keysym: 0x63, down: false)               // c as a shortcut
        k.key(keysym: 0xFFE3, down: false)
        k.key(keysym: 0x40, down: true); k.key(keysym: 0x40, down: false)               // @ typed
        k.key(keysym: 0x01000000 + 0x20AC, down: true)                                  // euro, by Unicode keysym
        XCTAssertEqual(sink.entries, [
            "key 36 true 0", "key 36 false 0",
            "key 59 true \(RFBKeyboard.controlFlag)",
            "key 8 true \(RFBKeyboard.controlFlag)", "key 8 false \(RFBKeyboard.controlFlag)",
            "key 59 false 0",
            "text @", "text \u{20AC}",
        ])
        k.releaseAll()
        XCTAssertEqual(sink.entries.last, "release")
    }

    func testPointerButtonsAndWheel() {
        let sink = RecordingSink()
        let p = RFBPointer(sink: sink, width: 200, height: 100)
        p.event(mask: 0, x: 100, y: 50)
        p.event(mask: 2, x: 100, y: 50)      // middle
        p.event(mask: 4, x: 100, y: 50)      // right
        p.event(mask: 8, x: 300, y: -5)      // wheel up, clamped position
        XCTAssertEqual(sink.entries, [
            "move 0.5 0.5",
            "button 2 true 0.5 0.5",
            "button 2 false 0.5 0.5", "button 1 true 0.5 0.5",
            "button 1 false 1.0 0.0", "scroll 0.0 40.0",
        ])
    }

    // MARK: building blocks

    func testTilesOnlyReportWhatChanged() {
        let src = RFBStaticFrameSource(width: 130, height: 70, fill: colour)
        let t = RFBFramebufferTracker(width: 130, height: 70)
        let whole = RFBFramebufferTracker.Rect(x: 0, y: 0, w: 130, h: 70)
        src.withLatestFrame { f in
            let first = t.changes(in: f, region: whole)
            XCTAssertEqual(first.reduce(0) { $0 + $1.w * $1.h }, 130 * 70)
            first.forEach { t.commit($0, frame: f) }
            XCTAssertTrue(t.changes(in: f, region: whole).isEmpty)
        }
        src.set(x: 129, y: 69, (9, 9, 9))
        src.withLatestFrame { f in
            XCTAssertEqual(t.changes(in: f, region: whole), [.init(x: 128, y: 64, w: 2, h: 6)])
        }
    }

    func testZRLERoundTripsAcrossImageKinds() throws {
        let w = 130, h = 70
        let kinds: [(String, (Int, Int) -> (UInt8, UInt8, UInt8))] = [
            ("solid", { _, _ in (10, 20, 30) }),
            ("two colours", { x, y in (x + y) % 2 == 0 ? (255, 0, 0) : (0, 0, 255) }),
            ("five colours", { x, _ in [(0, 0, 0), (255, 0, 0), (0, 255, 0), (0, 0, 255), (9, 9, 9)][x % 5] }),
            ("noise", { x, y in (UInt8((x * 37 + y * 11) % 256), UInt8((x * 5 + y * 91) % 256), UInt8((x * y) % 256)) }),
        ]
        let formats: [RFBPixelFormat] = [
            .standard,
            RFBPixelFormat(bitsPerPixel: 32, depth: 24, bigEndian: true, trueColour: true,
                           redMax: 255, greenMax: 255, blueMax: 255, redShift: 8, greenShift: 16, blueShift: 24),
            RFBPixelFormat(bitsPerPixel: 32, depth: 32, bigEndian: false, trueColour: true,
                           redMax: 255, greenMax: 255, blueMax: 255, redShift: 24, greenShift: 16, blueShift: 8),
            RFBPixelFormat(bitsPerPixel: 16, depth: 16, bigEndian: true, trueColour: true,
                           redMax: 31, greenMax: 63, blueMax: 31, redShift: 11, greenShift: 5, blueShift: 0),
            RFBPixelFormat(bitsPerPixel: 8, depth: 8, bigEndian: false, trueColour: true,
                           redMax: 7, greenMax: 7, blueMax: 3, redShift: 5, greenShift: 2, blueShift: 0),
        ]
        for format in formats {
            XCTAssertTrue(format.isSupported)
            let deflater = RFBDeflater(), inflater = RFBInflater()
            for (name, fill) in kinds {
                let src = RFBStaticFrameSource(width: w, height: h, fill: fill)
                // Two rectangles per image, so the shared zlib stream is exercised across them.
                for (x, y, rw, rh) in [(0, 0, w, h), (3, 5, 70, 40)] {
                    src.withLatestFrame { frame in
                        let body = RFBEncoding.zrleRect(frame, x: x, y: y, w: rw, h: rh, format: format, deflater: deflater)
                        guard let body, let px = RFBEncoding.decodeZRLE(body, w: rw, h: rh, format: format, inflater: inflater) else {
                            XCTFail("\(name) \(format.bitsPerPixel)bpp did not round trip"); return
                        }
                        for j in 0..<rh { for i in 0..<rw {
                            let p = frame.pixel(x + i, y + j)
                            let want = format.channels(of: format.value(red: p.r, green: p.g, blue: p.b))
                            if px[j * rw + i] != want { XCTFail("\(name) \(format.bitsPerPixel)bpp pixel \(i),\(j)"); return }
                        } }
                        let raw = RFBEncoding.rawRect(frame, x: x, y: y, w: rw, h: rh, format: format)
                        XCTAssertEqual(raw.count, rw * rh * format.pixelSize)
                    }
                }
            }
        }
    }

    func testPrimeIsPrimeByFermatAndDiffieHellmanAgrees() {
        let m = RFBARD.modulus
        let pMinus1 = { () -> [UInt8] in var p = RFBARD.prime; p[p.count - 1] &-= 1; return p }()
        let one = [UInt8](repeating: 0, count: m.byteLength - 1) + [1]
        for base in [[UInt8(2)], [UInt8(3)], [UInt8(0x12), 0x34]] {
            XCTAssertEqual(m.power(base: base, exponent: pMinus1), one)
        }
        XCTAssertEqual(m.power(base: [2], exponent: [10]), [UInt8](repeating: 0, count: m.byteLength - 2) + [4, 0])

        let a = RFBARD.makeServerKeys(), b = RFBARD.makeServerKeys()
        XCTAssertEqual(RFBARD.aesKey(peerPublic: b.publicKey, secret: a.secret),
                       RFBARD.aesKey(peerPublic: a.publicKey, secret: b.secret))
        XCTAssertEqual(RFBARD.aesKey(peerPublic: b.publicKey, secret: a.secret)?.count, 16)
    }

    func testDiffieHellmanRejectsDegeneratePublicValues() {
        let n = RFBARD.keyLength
        let zero = [UInt8](repeating: 0, count: n)
        let one = [UInt8](repeating: 0, count: n - 1) + [1]
        var pm1 = RFBARD.prime; pm1[n - 1] &-= 1
        let secret = RFBARD.makeServerKeys().secret
        for bad in [zero, one, pm1, RFBARD.prime, [1, 2, 3]] {
            XCTAssertNil(RFBARD.aesKey(peerPublic: bad, secret: secret))
        }
    }

    func testCredentialsRoundTripAndAreBounded() throws {
        let key = (0..<16).map { UInt8($0) }
        let c = try XCTUnwrap(RFBARD.encryptCredentials(user: "alice", password: "p@ss wörd", key: key))
        XCTAssertEqual(c.count, 128)
        let d = try XCTUnwrap(RFBARD.decryptCredentials(c, key: key))
        XCTAssertEqual(d.user, "alice")
        XCTAssertEqual(d.password, "p@ss wörd")
        XCTAssertNil(RFBARD.decryptCredentials(c, key: (0..<15).map { UInt8($0) }))
        let long = try XCTUnwrap(RFBARD.encryptCredentials(user: String(repeating: "u", count: 200), password: "x", key: key))
        XCTAssertEqual(RFBARD.decryptCredentials(long, key: key)?.user.count, 63)
    }

    func testTheSelfTestPasses() {
        XCTAssertTrue(RFBSelfTest.run(out: { _ in }))
        XCTAssertTrue(RFBServerGate.present)
    }
}
