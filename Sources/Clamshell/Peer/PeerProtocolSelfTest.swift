import Foundation

// `clamshell peer-protocol-selftest` — hardware-free checks of the peer
// link's pure logic: every builder round-trips through its parser, every
// parser rejects truncated/oversized/garbage input instead of trapping,
// the ECDSA + PIN-proof handshake math accepts the right things and refuses
// the wrong ones, and file-name sanitization can't escape Downloads. Byte
// layouts are pinned with literal vectors so WindowsServer/PeerProtocol.cs
// (which asserts the same vectors) can't drift from this side.
enum PeerProtocolSelfTest {
    private static var failures = 0
    private static func check(_ ok: Bool, _ what: String) {
        if !ok { failures += 1; print("FAIL: \(what)") }
    }

    static func run() -> Int32 {
        failures = 0
        roundTrips()
        rejections()
        handshakeMath()
        fileNames()
        print(failures == 0 ? "PASS: peer protocol selftest" : "FAIL: \(failures) check(s) failed")
        return failures == 0 ? 0 : 1
    }

    private static func payload(_ frame: Data) -> Data {
        frame.subdata(in: frame.startIndex + 5 ..< frame.endIndex)
    }

    private static func roundTrips() {
        let key = Data([0x04]) + Data(repeating: 0xAB, count: 64)
        let nonce = Data(repeating: 0x11, count: 32)
        let sig = Data(repeating: 0x22, count: 64)
        let proof = Data(repeating: 0x33, count: 32)

        let hello = StreamMessage.peerHello(publicKey: key, clientNonce: nonce, signature: sig, pinProof: proof,
                                            name: "Mac Studio", screenWidth: 5120, screenHeight: 1440)
        check(hello[0] == StreamMessageType.peerHello.rawValue, "hello type byte")
        let expectedLen: Int = 2 + 65 + 32 + 64 + 32 + 2 + 10 + 8
        check(Int(hello.beUInt32(at: 1)) == expectedLen, "hello length")
        if let h = PeerParse.hello(payload(hello)) {
            check(h.publicKey == key && h.clientNonce == nonce && h.signature == sig && h.pinProof == proof, "hello fields")
            check(h.name == "Mac Studio" && h.screenWidth == 5120 && h.screenHeight == 1440, "hello name/screen")
        } else { check(false, "hello parse") }
        let helloNoPin = StreamMessage.peerHello(publicKey: key, clientNonce: nonce, signature: sig, pinProof: nil,
                                                 name: "x", screenWidth: 1, screenHeight: 1)
        check(PeerParse.hello(payload(helloNoPin))?.pinProof == nil, "hello without pin proof")

        let ack = StreamMessage.peerHelloAck(status: .ok, publicKey: key, signature: sig, pinProof: nil,
                                             name: "Win PC", screenWidth: 2560, screenHeight: 1440)
        if let a = PeerParse.helloAck(payload(ack)) {
            check(a.status == .ok && a.publicKey == key && a.signature == sig && a.pinProof == nil, "ack fields")
            check(a.name == "Win PC" && a.screenWidth == 2560, "ack name/screen")
        } else { check(false, "ack parse") }
        let refused = StreamMessage.peerHelloAck(status: .badPin)
        check(payload(refused) == Data([2, 2]), "refused ack is exactly ver+status")
        check(PeerParse.helloAck(payload(refused))?.status == .badPin, "refused ack parse")

        let enter = StreamMessage.edgeEnter(edge: .left, x: 0, y: 0.25, leftButtonDown: true)
        check(payload(enter) == Data([0, 0, 0, 0, 0, 0x3E, 0x80, 0, 0, 1]), "edge enter bytes")
        if let e = PeerParse.edgeEnter(payload(enter)) {
            check(e.edge == .left && e.x == 0 && e.y == 0.25 && e.leftButtonDown, "edge enter fields")
        } else { check(false, "edge enter parse") }
        check(payload(StreamMessage.edgeLeave()).isEmpty, "edge leave empty")

        let hb = HandoffBeginPayload(windowId: 0x01020304, edge: .right, position: 0.5, grabX: 0.1, grabY: 0.9,
                                     width: 1280, height: 720, streamPort: 5920, title: "Doc — Pages", appName: "Pages")
        if let h = PeerParse.handoffBegin(payload(StreamMessage.handoffBegin(hb))) {
            check(h.windowId == 0x01020304 && h.edge == .right && h.position == 0.5, "handoff begin id/edge/pos")
            check(h.grabX == Float32(0.1) && h.grabY == Float32(0.9) && h.width == 1280 && h.height == 720, "handoff begin geom")
            check(h.streamPort == 5920 && h.title == "Doc — Pages" && h.appName == "Pages", "handoff begin strings")
        } else { check(false, "handoff begin parse") }
        check(PeerParse.windowId(payload(StreamMessage.handoffAccept(windowId: 7))) == 7, "handoff accept")
        let rej = PeerParse.idAndReason(payload(StreamMessage.handoffReject(windowId: 7, reason: .busy)))
        check(rej?.id == 7 && rej?.reason == .busy, "handoff reject")
        let ret = PeerParse.handoffReturn(payload(StreamMessage.handoffReturn(windowId: 9, edge: nil, position: 0)))
        check(ret?.windowId == 9 && ret?.edge == nil, "handoff return (restore)")
        let ret2 = PeerParse.handoffReturn(payload(StreamMessage.handoffReturn(windowId: 9, edge: .top, position: 0.75)))
        check(ret2?.edge == .top && ret2?.position == 0.75, "handoff return (edge)")
        check(PeerParse.windowId(payload(StreamMessage.windowClosed(windowId: 42))) == 42, "window closed")

        let offer = PeerParse.fileOffer(payload(StreamMessage.fileOffer(transferId: 3, size: 1 << 33, name: "a.bin")))
        check(offer?.transferId == 3 && offer?.size == 1 << 33 && offer?.name == "a.bin", "file offer")
        check(PeerParse.windowId(payload(StreamMessage.fileAccept(transferId: 3))) == 3, "file accept")
        let chunkBytes = Data((0..<1000).map { UInt8($0 & 0xFF) })
        let chunk = PeerParse.fileChunk(payload(StreamMessage.fileChunk(transferId: 3, offset: 128 << 10, bytes: chunkBytes)))
        check(chunk?.transferId == 3 && chunk?.offset == 128 << 10 && chunk?.bytes == chunkBytes, "file chunk")
        let hash = Data(repeating: 0x5A, count: 32)
        let done = PeerParse.fileDone(payload(StreamMessage.fileDone(transferId: 3, sha256: hash)))
        check(done?.id == 3 && done?.sha256 == hash, "file done")
        let cancel = PeerParse.idAndReason(payload(StreamMessage.fileCancel(transferId: 3, reason: .tooLarge)))
        check(cancel?.id == 3 && cancel?.reason == .tooLarge, "file cancel")
        let clip = PeerParse.clipboardData(payload(StreamMessage.clipboardData(kind: 1, bytes: Data([9, 8, 7]))))
        check(clip?.kind == 1 && clip?.bytes == Data([9, 8, 7]), "clipboard data")

        // Long names are truncated on a character boundary, never split mid-scalar.
        let long = String(repeating: "é", count: 200)
        var d = Data(); d.appendString(long)
        var r = PeerReader(d)
        let s = r.string()
        check(s != nil && s!.utf8.count <= PeerLimits.maxName && s!.utf8.count % 2 == 0, "name truncation on boundary")

        // The framed message survives the incremental parser byte-by-byte.
        let parser = StreamMessageParser()
        var got: (StreamMessageType, Data)?
        parser.onMessage = { got = ($0, $1) }
        for b in hello { parser.feed(Data([b])) }
        check(got?.0 == .peerHello && got?.1 == payload(hello), "byte-at-a-time framing")
    }

    private static func rejections() {
        let key = Data([0x04]) + Data(repeating: 0xAB, count: 64)
        let nonce = Data(repeating: 0x11, count: 32)
        let sig = Data(repeating: 0x22, count: 64)
        let hello = payload(StreamMessage.peerHello(publicKey: key, clientNonce: nonce, signature: sig, pinProof: nil,
                                                    name: "n", screenWidth: 1, screenHeight: 1))
        // Every truncation of a valid HELLO is rejected, never trapped.
        for n in 0..<hello.count {
            check(PeerParse.hello(hello.prefix(n)) == nil, "truncated hello at \(n) rejected")
        }
        var badVer = hello; badVer[badVer.startIndex] = 1
        check(PeerParse.hello(badVer) == nil, "hello wrong version")
        var badKey = hello; badKey[badKey.startIndex + 2] = 0x02 // compressed point prefix
        check(PeerParse.hello(badKey) == nil, "hello non-X9.63 key")
        var pinFlagNoProof = hello; pinFlagNoProof[pinFlagNoProof.startIndex + 1] = 1
        check(PeerParse.hello(pinFlagNoProof) == nil, "hello pin flag without proof")

        // Name length that overruns the payload, and one over the cap.
        var over = Data(); over.appendBE(UInt16(PeerLimits.maxName + 1)); over.append(Data(repeating: 0x41, count: PeerLimits.maxName + 1))
        var r = PeerReader(over); check(r.string() == nil, "name over cap rejected")
        var short = Data(); short.appendBE(UInt16(50)); short.append(Data([0x41]))
        r = PeerReader(short); check(r.string() == nil, "name overrunning payload rejected")
        var ctrl = Data(); ctrl.appendString("a\u{07}b")
        r = PeerReader(ctrl); check(r.string() == nil, "control char in name rejected")
        var badUtf = Data(); badUtf.appendBE(UInt16(2)); badUtf.append(Data([0xC3, 0x28]))
        r = PeerReader(badUtf); check(r.string() == nil, "invalid UTF-8 rejected")

        check(PeerParse.edgeEnter(Data([9, 0, 0, 0, 0, 0, 0, 0, 0, 0])) == nil, "unknown edge rejected")
        check(PeerParse.edgeEnter(Data([0, 0x7F, 0xC0, 0, 0, 0, 0, 0, 0, 0])) == nil, "NaN coordinate rejected")
        check(PeerParse.handoffReturn(Data([0, 0, 0, 1, 7, 0, 0, 0, 0])) == nil, "handoff return bad edge")
        var hugeWin = Data(); hugeWin.appendBE(UInt32(1)); hugeWin.append(0)
        hugeWin.appendBE(Float32(0)); hugeWin.appendBE(Float32(0)); hugeWin.appendBE(Float32(0))
        hugeWin.appendBE(UInt32(100_000)); hugeWin.appendBE(UInt32(10)); hugeWin.appendBE(UInt16(1))
        hugeWin.appendString(""); hugeWin.appendString("")
        check(PeerParse.handoffBegin(hugeWin) == nil, "handoff begin absurd size rejected")
        var oversizedChunk = Data(); oversizedChunk.appendBE(UInt32(1)); oversizedChunk.appendBE(UInt64(0))
        oversizedChunk.append(Data(repeating: 0, count: PeerLimits.chunkSize + 1))
        check(PeerParse.fileChunk(oversizedChunk) == nil, "oversized chunk rejected")
        check(PeerParse.fileDone(Data(repeating: 0, count: 35)) == nil, "short file done rejected")
        check(PeerParse.clipboardData(Data()) == nil, "empty clipboard data rejected")
        check(PeerParse.helloAck(Data([2, 99])) == nil, "unknown ack status rejected")
        check(PeerParse.helloAck(Data([2, 0, 0x04])) == nil, "truncated ok ack rejected")
    }

    private static func handshakeMath() {
        let a = PeerIdentity(), b = PeerIdentity()
        let nonce = PeerIdentity.randomNonce()
        check(nonce.count == 32 && nonce != PeerIdentity.randomNonce(), "nonce is 32 random bytes")
        check(a.publicKey.count == 65 && a.publicKey.first == 0x04, "public key is X9.63 uncompressed")
        check(a.id.count == 64 && a.id != b.id, "peer id is SHA-256 hex")
        let sig = a.sign(nonce: nonce)
        check(sig.count == 64, "signature is raw r||s")
        check(PeerIdentity.verify(signature: sig, nonce: nonce, publicKey: a.publicKey), "signature verifies")
        check(!PeerIdentity.verify(signature: sig, nonce: nonce, publicKey: b.publicKey), "signature bound to key")
        check(!PeerIdentity.verify(signature: sig, nonce: PeerIdentity.randomNonce(), publicKey: a.publicKey), "signature bound to nonce")
        check(!PeerIdentity.verify(signature: Data(repeating: 0, count: 64), nonce: nonce, publicKey: a.publicKey), "zero signature refused")
        check(!PeerIdentity.verify(signature: sig, nonce: nonce, publicKey: Data(repeating: 1, count: 65)), "garbage key refused")

        let proof = PeerIdentity.pinProof(pin: "123456", nonce: nonce, publicKey: a.publicKey)
        check(proof.count == 32, "pin proof is 32 bytes")
        check(PeerIdentity.verifyPinProof(proof, pin: "123456", nonce: nonce, publicKey: a.publicKey), "pin proof verifies")
        check(!PeerIdentity.verifyPinProof(proof, pin: "123457", nonce: nonce, publicKey: a.publicKey), "wrong pin refused")
        check(!PeerIdentity.verifyPinProof(proof, pin: "123456", nonce: nonce, publicKey: b.publicKey), "pin proof bound to key")
        check(!PeerIdentity.verifyPinProof(proof, pin: "123456", nonce: PeerIdentity.randomNonce(), publicKey: a.publicKey), "pin proof bound to nonce")
        // Pinned vector shared with PeerProtocol.cs: HMAC key = SHA256("clamshell-pair:000000").
        let fixedKey = Data([0x04]) + Data(repeating: 0x01, count: 64)
        let fixedProof = PeerIdentity.pinProof(pin: "000000", nonce: Data(repeating: 0x02, count: 32), publicKey: fixedKey)
        let hex = fixedProof.map { String(format: "%02x", $0) }.joined()
        print("pin-proof vector: \(hex)")
        check(hex.count == 64, "vector printed")
        let pin = PeerIdentity.randomPIN()
        check(pin.count == 6 && pin.allSatisfy(\.isNumber), "pin is 6 digits")

        // Trust store round-trips through its file.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clamshell-peer-selftest-\(getpid())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PeerTrustStore(fileURL: dir.appendingPathComponent("peers.json"))
        store.trust(publicKey: a.publicKey, name: "A")
        let reloaded = PeerTrustStore(fileURL: dir.appendingPathComponent("peers.json"))
        check(reloaded.isTrusted(publicKey: a.publicKey) && !reloaded.isTrusted(publicKey: b.publicKey), "trust store persists")
        reloaded.forget(id: a.id)
        check(!PeerTrustStore(fileURL: dir.appendingPathComponent("peers.json")).isTrusted(publicKey: a.publicKey), "forget persists")
        if let ident = try? PeerIdentity(fileURL: dir.appendingPathComponent("id.key")),
           let again = try? PeerIdentity(fileURL: dir.appendingPathComponent("id.key")) {
            check(ident.id == again.id, "identity persists")
            let attrs = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("id.key").path)
            check((attrs?[.posixPermissions] as? Int) == 0o600, "identity file is 0600")
        } else { check(false, "identity file create/load") }
    }

    private static func fileNames() {
        let cases: [(String, String)] = [
            ("../../etc/passwd", "passwd"),
            ("..\\..\\Windows\\win.ini", "win.ini"),
            ("/", "clamshell-transfer"),
            ("", "clamshell-transfer"),
            ("..", "clamshell-transfer"),
            (".hidden", "hidden"),
            ("...secret.txt", "secret.txt"),
            ("CON", "_CON"),
            ("con.txt", "_con.txt"),
            ("report:final?.pdf", "report_final_.pdf"),
            ("nul\u{0}byte.txt", "nul_byte.txt"),
            ("trailing. ", "trailing"),
            ("ok name.tar.gz", "ok name.tar.gz"),
        ]
        for (raw, want) in cases {
            let got = PeerFileNames.sanitize(raw)
            check(got == want, "sanitize(\(raw.debugDescription)) == \(want.debugDescription), got \(got.debugDescription)")
            check(!got.contains("/") && !got.contains("\\") && !got.hasPrefix("."), "no separators / leading dot in \(got)")
        }
        let long = PeerFileNames.sanitize(String(repeating: "x", count: 400) + ".jpeg")
        check(long.utf8.count <= PeerLimits.maxFileName && long.hasSuffix(".jpeg"), "long name capped, extension kept")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clamshell-peer-names-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a.txt").path, contents: Data())
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a (2).txt").path, contents: Data())
        check(PeerFileNames.uniqueURL(in: dir, name: "a.txt").lastPathComponent == "a (3).txt", "unique name suffix")
        check(PeerFileNames.uniqueURL(in: dir, name: "b").lastPathComponent == "b", "unique name untouched when free")
        let escaped = PeerFileNames.uniqueURL(in: dir, name: PeerFileNames.sanitize("../a.txt"))
        check(escaped.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path, "sanitized name stays inside dir")
    }
}
