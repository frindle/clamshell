import Foundation
import CryptoKit

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
        goldenVectors()
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
        var d3 = Data(); d3.appendString(String(repeating: "—", count: 60)) // 3-byte scalars: 180 bytes
        var r3 = PeerReader(d3)
        check(r3.string() == String(repeating: "—", count: 42), "3-byte scalars truncate to whole characters, not to empty")

        // The framed message survives the incremental parser byte-by-byte.
        let parser = StreamMessageParser()
        var got: (StreamMessageType, Data)?
        parser.onMessage = { got = ($0, $1) }
        for b in hello { parser.feed(Data([b])) }
        check(got?.0 == .peerHello && got?.1 == payload(hello), "byte-at-a-time framing")
    }

    /// Whole-message byte vectors, pinned as literal hex. The identical table
    /// lives in WindowsServer/Peer/PeerSelfTest.cs; a change on either side
    /// that isn't mirrored fails that side's selftest.
    static func goldenMessages() -> [(String, Data)] {
        let key = Data([0x04]) + Data(repeating: 0xAB, count: 64)
        let nonce = Data(repeating: 0x11, count: 32)
        let sig = Data(repeating: 0x22, count: 64)
        let proof = Data(repeating: 0x33, count: 32)
        return [
            ("challenge", StreamMessage.peerChallenge(nonce: nonce)),
            ("hello", StreamMessage.peerHello(publicKey: key, clientNonce: nonce, signature: sig, pinProof: proof,
                                              name: "Mac Studio", screenWidth: 5120, screenHeight: 1440)),
            ("helloNoPin", StreamMessage.peerHello(publicKey: key, clientNonce: nonce, signature: sig, pinProof: nil,
                                                   name: "x", screenWidth: 1, screenHeight: 1)),
            ("helloAck", StreamMessage.peerHelloAck(status: .ok, publicKey: key, signature: sig, pinProof: proof,
                                                    name: "Win PC", screenWidth: 2560, screenHeight: 1440)),
            ("helloAckRefused", StreamMessage.peerHelloAck(status: .badPin)),
            ("edgeEnter", StreamMessage.edgeEnter(edge: .left, x: 0, y: 0.25, leftButtonDown: true)),
            ("edgeLeave", StreamMessage.edgeLeave()),
            ("clipboardText", StreamMessage.clipboard(text: "héllo ✓")),
            ("clipboardPng", StreamMessage.clipboardData(kind: 1, bytes: Data([0x89, 0x50, 0x4E, 0x47]))),
            ("handoffBegin", StreamMessage.handoffBegin(HandoffBeginPayload(
                windowId: 0x01020304, edge: .right, position: 0.5, grabX: 0.1, grabY: 0.9, width: 1280, height: 720,
                streamPort: 5921, title: "Doc — Pages", appName: "Pages"))),
            ("handoffAccept", StreamMessage.handoffAccept(windowId: 7)),
            ("handoffReject", StreamMessage.handoffReject(windowId: 7, reason: .busy)),
            ("handoffReturnEdge", StreamMessage.handoffReturn(windowId: 9, edge: .top, position: 0.75)),
            ("handoffReturnHome", StreamMessage.handoffReturn(windowId: 9, edge: nil, position: 0)),
            ("windowClosed", StreamMessage.windowClosed(windowId: 42)),
            ("fileOffer", StreamMessage.fileOffer(transferId: 3, size: 1 << 33, name: "a b.zip")),
            ("fileAccept", StreamMessage.fileAccept(transferId: 3)),
            ("fileReject", StreamMessage.fileReject(transferId: 3, reason: .disk)),
            ("fileChunk", StreamMessage.fileChunk(transferId: 3, offset: 131072, bytes: Data([1, 2, 3]))),
            ("fileDone", StreamMessage.fileDone(transferId: 3, sha256: Data(repeating: 0x5A, count: 32))),
            ("fileCancel", StreamMessage.fileCancel(transferId: 3, reason: .tooLarge)),
            ("mouseMove", StreamMessage.mouseMove(x: 0.5, y: 0.25)),
            ("mouseButton", StreamMessage.mouseButton(button: 1, down: true, x: 0.1, y: 0.2)),
            ("key", StreamMessage.key(macKeyCode: 0x25, down: true, flags: 0x140000)),
            ("scroll", StreamMessage.scroll(dx: 0, dy: -40)),
        ]
    }

    static let goldenHex: [String: String] = [
        "challenge": "40000000201111111111111111111111111111111111111111111111111111111111111111",
        "hello": "41000000d7020104abababababababababababababababababababababababababababababababababababababababababababababababababababababababababababababababab1111111111111111111111111111111111111111111111111111111111111111222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222223333333333333333333333333333333333333333333333333333333333333333000a4d61632053747564696f00001400000005a0",
        "helloNoPin": "41000000ae020004abababababababababababababababababababababababababababababababababababababababababababababababababababababababababababababababab1111111111111111111111111111111111111111111111111111111111111111222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222220001780000000100000001",
        "helloAck": "42000000b4020004abababababababababababababababababababababababababababababababababababababababababababababababababababababababababababababababab22222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222013333333333333333333333333333333333333333333333333333333333333333000657696e20504300000a00000005a0",
        "helloAckRefused": "42000000020202",
        "edgeEnter": "440000000a00000000003e80000001",
        "edgeLeave": "4500000000",
        "clipboardText": "300000000a68c3a96c6c6f20e29c93",
        "clipboardPng": "46000000050189504e47",
        "handoffBegin": "480000003101020304013f0000003dcccccd3f66666600000500000002d01721000d446f6320e2809420506167657300055061676573",
        "handoffAccept": "490000000400000007",
        "handoffReject": "4a000000050000000705",
        "handoffReturnEdge": "4b0000000900000009023f400000",
        "handoffReturnHome": "4b0000000900000009ff00000000",
        "windowClosed": "4c000000040000002a",
        "fileOffer": "500000001500000003000000020000000000076120622e7a6970",
        "fileAccept": "510000000400000003",
        "fileReject": "52000000050000000303",
        "fileChunk": "530000000f000000030000000000020000010203",
        "fileDone": "5400000024000000035a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a",
        "fileCancel": "55000000050000000302",
        "mouseMove": "20000000083f0000003e800000",
        "mouseButton": "210000000a01013dcccccd3e4ccccd",
        "key": "220000000b0025010000000000140000",
        "scroll": "230000000800000000c2200000",
    ]

    /// Fixed-key crypto vectors: a P-256 key with raw scalar 0x01…0x20, its
    /// peer id, and the PIN proof — .NET must derive the same public key and
    /// id, and verify a signature this side made (ECDSA signatures are
    /// randomized, so the Swift-made one is pinned for the C# side to verify).
    static let fixedScalar = Data((1...32).map { UInt8($0) })

    private static func goldenVectors() {
        func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
        let printAll = ProcessInfo.processInfo.environment["CLAMSHELL_PRINT_GOLDEN"] != nil
        for (name, bytes) in goldenMessages() {
            if printAll { print("golden \(name) \(hex(bytes))") }
            check(goldenHex[name] == hex(bytes), "golden vector \(name)")
        }
        if let key = try? P256.Signing.PrivateKey(rawRepresentation: fixedScalar) {
            let pub = key.publicKey.x963Representation
            check(hex(pub) == "04515c3d6eb9e396b904d3feca7f54fdcd0cc1e997bf375dca515ad0a6c3b4035f4536be3a50f318fbf9a5475902a221502bef0d57e08c53b2cc0a56f17d9f9354", "fixed public key")
            check(PeerIdentity.peerId(for: pub) == "4269889431e3131966fcaf6a457141943ed2c35b5b917ae62cb339546f523551", "fixed peer id")
            let pinned = Data(hexString: "8d7c8838f0c897ef1f01724ab9968ef27416a4e381277aacb5cfdcaf95c732303f58a8d113ae080d694ed0c5674abcb68a8fb40aac77e079c4be9739fb1cf8df")
            check(pinned.map { PeerIdentity.verify(signature: $0, nonce: Data(repeating: 0x02, count: 32), publicKey: pub) } == true,
                  "pinned fixed-key signature verifies")
            if printAll {
                print("golden fixedPublicKey \(hex(pub))")
                print("golden fixedPeerId \(PeerIdentity.peerId(for: pub))")
                let nonce = Data(repeating: 0x02, count: 32)
                if let sig = try? key.signature(for: nonce + pub).rawRepresentation { print("golden fixedSignature \(hex(sig))") }
            }
        } else { check(false, "fixed scalar is a valid P-256 key") }
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
        // Pinned: WindowsServer/Peer/PeerSelfTest.cs asserts the same value.
        check(hex == "a6f4272b2275bc4ada594f129c3b2fe53bff85d3e8db0515b14219807066a8d1", "pin-proof vector")
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

extension Data {
    /// Test helper: "0a0b" → [0x0a, 0x0b]; nil on odd length or non-hex.
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var out = Data(capacity: hexString.count / 2)
        var i = hexString.startIndex
        while i < hexString.endIndex {
            let j = hexString.index(i, offsetBy: 2)
            guard let b = UInt8(hexString[i..<j], radix: 16) else { return nil }
            out.append(b); i = j
        }
        self = out
    }
}
