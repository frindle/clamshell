import XCTest
import CryptoKit
@testable import Clamshell

/// Checks SecureSession.swift against tests/vectors/auth-v1.json (PROTOCOL.md
/// "Device authentication and encrypted session"). ECDSA signatures are
/// randomized, so recorded ones are verified; everything else must come out
/// byte for byte.
final class SecureSessionTests: XCTestCase {
    private typealias Dict = [String: Any]

    private lazy var root: Dict = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("vectors/auth-v1.json")
        let data = try! Data(contentsOf: url)
        return try! JSONSerialization.jsonObject(with: data) as! Dict
    }()

    private func hex(_ s: String) -> Data {
        var d = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            d.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return d
    }

    private func toHex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    private func str(_ key: String) -> String { root[key] as! String }
    private func bytes(_ key: String) -> Data { hex(str(key)) }
    private func pair(_ key: String) -> (priv: Data, pub: Data) {
        let d = root[key] as! [String: String]
        return (hex(d["private"]!), hex(d["public"]!))
    }
    private func result(_ name: String) -> Dict { (root["results"] as! Dict)[name] as! Dict }
    private func raw(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    private var hostCaps: StreamCapabilities { StreamCapabilities(rawValue: UInt32((root["hostCaps"] as! NSNumber).intValue)) }
    private var clientCaps: StreamCapabilities { StreamCapabilities(rawValue: UInt32((root["clientCaps"] as! NSNumber).intValue)) }

    private var vectorExtension: AuthExtension {
        let e = root["responseExtension"] as! Dict
        return AuthExtension(type: UInt8((e["type"] as! NSNumber).intValue), value: hex(e["value"] as! String))
    }

    /// The host's half, built from the vector's fixed keys and nonce.
    private func vectorHost() throws -> HostHandshake {
        try HostHandshake(identityKey: pair("hostIdentity").pub, capabilities: hostCaps, name: str("hostName"),
                          ephemeral: try P256.KeyAgreement.PrivateKey(rawRepresentation: pair("hostEphemeral").priv),
                          nonce: bytes("hostNonce"))
    }

    /// The client's half. The signer hands back the recorded signature so the
    /// response is the vector's byte for byte.
    private func vectorClient(challenge: Data? = nil) throws -> ClientHandshake {
        let recorded = bytes("clientSignature")
        return try ClientHandshake(challengePayload: challenge ?? bytes("challenge"),
                                   deviceKey: pair("deviceKey").pub, capabilities: clientCaps,
                                   name: str("deviceName"), extensions: [vectorExtension],
                                   ephemeral: try P256.KeyAgreement.PrivateKey(rawRepresentation: pair("clientEphemeral").priv),
                                   nonce: bytes("clientNonce"),
                                   sign: { _ in recorded })
    }

    // MARK: keys, ids, names

    func testPublicKeysComeFromThePrivateKeys() throws {
        for name in ["hostIdentity", "deviceKey"] {
            let p = pair(name)
            XCTAssertEqual(try P256.Signing.PrivateKey(rawRepresentation: p.priv).publicKey.x963Representation, p.pub, name)
            XCTAssertTrue(DeviceIdentity.isValidPublicKey(p.pub))
        }
        for name in ["hostEphemeral", "clientEphemeral"] {
            let p = pair(name)
            XCTAssertEqual(try P256.KeyAgreement.PrivateKey(rawRepresentation: p.priv).publicKey.x963Representation, p.pub, name)
        }
    }

    func testIdsAndFingerprints() {
        XCTAssertEqual(DeviceIdentity.id(ofPublicKey: pair("hostIdentity").pub), str("hostId"))
        XCTAssertEqual(DeviceIdentity.fingerprint(ofPublicKey: pair("hostIdentity").pub), str("hostFingerprint"))
        XCTAssertEqual(DeviceIdentity.id(ofPublicKey: pair("deviceKey").pub), str("deviceId"))
        XCTAssertEqual(DeviceIdentity.fingerprint(ofId: str("deviceId")), str("deviceFingerprint"))
    }

    func testInvalidPublicKeysAreRefused() {
        let good = pair("deviceKey").pub
        XCTAssertFalse(DeviceIdentity.isValidPublicKey(Data()))
        XCTAssertFalse(DeviceIdentity.isValidPublicKey(good.dropLast()))
        XCTAssertFalse(DeviceIdentity.isValidPublicKey(good + Data([0])))
        var offCurve = good
        offCurve[offCurve.count - 1] ^= 0x01
        XCTAssertFalse(DeviceIdentity.isValidPublicKey(offCurve))
        var compressedMarker = good
        compressedMarker[0] = 0x02
        XCTAssertFalse(DeviceIdentity.isValidPublicKey(compressedMarker))
        XCTAssertFalse(DeviceIdentity.isValidPublicKey(Data(count: 65)))
    }

    func testCleanName() {
        XCTAssertEqual(AuthWire.cleanName("Studio"), "Studio")
        XCTAssertEqual(AuthWire.cleanName("  Pad\u{0007} One\n"), "Pad One")
        // Bidirectional override and zero-width characters vanish.
        XCTAssertEqual(AuthWire.cleanName("iPad\u{202E}dab\u{200B}i"), "iPaddabi")
        XCTAssertEqual(AuthWire.cleanName("\u{2066}\u{2069}"), "")
        // 64 bytes at most, never half a character.
        let long = String(repeating: "é", count: 40) // 80 bytes
        let cut = AuthWire.cleanName(long)
        XCTAssertEqual(cut.utf8.count, 64)
        XCTAssertEqual(cut, String(repeating: "é", count: 32))
        XCTAssertLessThanOrEqual(AuthWire.cleanName(String(repeating: "a", count: 63) + "é").utf8.count, 64)
    }

    // MARK: handshake payloads

    func testChallengeBytes() throws {
        let host = try vectorHost()
        XCTAssertEqual(toHex(host.challenge.payload), str("challenge"))
        XCTAssertEqual(host.challenge.payload.count, 176)

        let decoded = try AuthChallenge.decode(bytes("challenge"))
        XCTAssertEqual(decoded.hello.capabilities.rawValue, hostCaps.rawValue)
        XCTAssertEqual(decoded.hello.nonce, bytes("hostNonce"))
        XCTAssertEqual(decoded.hello.ephemeralKey, pair("hostEphemeral").pub)
        XCTAssertEqual(decoded.hello.identityKey, pair("hostIdentity").pub)
        XCTAssertEqual(decoded.hello.name, str("hostName"))
        XCTAssertTrue(decoded.hello.extensions.isEmpty)
    }

    func testResponseBytesAndClientSignature() throws {
        let client = try vectorClient()
        XCTAssertEqual(toHex(client.response), str("response"))
        XCTAssertEqual(client.hostId, str("hostId"))
        XCTAssertEqual(client.hostFingerprint, str("hostFingerprint"))
        XCTAssertEqual(client.hostName, str("hostName"))
        XCTAssertEqual(client.hostCapabilities.rawValue, hostCaps.rawValue)

        let response = try AuthResponse.decode(bytes("response"))
        XCTAssertEqual(toHex(response.body), str("responseBody"))
        XCTAssertEqual(response.signature, bytes("clientSignature"))
        XCTAssertEqual(response.hello.extensions, [vectorExtension])

        let input = AuthWire.clientSignatureInput(challenge: bytes("challenge"), responseBody: response.body)
        XCTAssertEqual(toHex(input), str("clientSignatureInput"))
        XCTAssertTrue(AuthSignature.verify(bytes("clientSignature"), over: input, publicKey: pair("deviceKey").pub))
        XCTAssertFalse(AuthSignature.verify(bytes("clientSignature"), over: input, publicKey: pair("hostIdentity").pub))
    }

    func testHostVerifiesTheRecordedResponse() throws {
        let device = try vectorHost().verify(responsePayload: bytes("response"))
        XCTAssertEqual(device.id, str("deviceId"))
        XCTAssertEqual(device.fingerprint, str("deviceFingerprint"))
        XCTAssertEqual(device.publicKey, pair("deviceKey").pub)
        XCTAssertEqual(device.name, str("deviceName"))
        XCTAssertEqual(device.capabilities.rawValue, clientCaps.rawValue)
        // The unknown extension type is carried, not an error.
        XCTAssertEqual(device.extensions, [vectorExtension])
    }

    func testHostRefusesBadResponses() throws {
        let host = try vectorHost()
        let good = bytes("response")

        var wrongVersion = good
        wrongVersion[0] = 2
        XCTAssertThrowsError(try host.verify(responsePayload: wrongVersion)) { XCTAssertEqual($0 as? AuthError, .unsupportedVersion) }

        // Any change to the signed body breaks the signature.
        var flippedCaps = good
        flippedCaps[4] ^= 0x01
        XCTAssertThrowsError(try host.verify(responsePayload: flippedCaps)) { XCTAssertEqual($0 as? AuthError, .badSignature) }
        var flippedNonce = good
        flippedNonce[5] ^= 0x80
        XCTAssertThrowsError(try host.verify(responsePayload: flippedNonce)) { XCTAssertEqual($0 as? AuthError, .badSignature) }
        var flippedSignature = good
        flippedSignature[flippedSignature.count - 1] ^= 0x01
        XCTAssertThrowsError(try host.verify(responsePayload: flippedSignature)) { XCTAssertEqual($0 as? AuthError, .badSignature) }

        // Keys that are not curve points are refused before any signature check.
        var badDeviceKey = good
        badDeviceKey[1 + 4 + 32 + 65 + 64] ^= 0x01 // last byte of the device key
        XCTAssertThrowsError(try host.verify(responsePayload: badDeviceKey)) { XCTAssertEqual($0 as? AuthError, .invalidKey) }
        var badEphemeral = good
        badEphemeral[1 + 4 + 32 + 64] ^= 0x01 // last byte of the key-exchange key
        XCTAssertThrowsError(try host.verify(responsePayload: badEphemeral)) { XCTAssertEqual($0 as? AuthError, .invalidKey) }

        // Layout.
        XCTAssertThrowsError(try host.verify(responsePayload: good + Data([0]))) { XCTAssertEqual($0 as? AuthError, .malformed) }
        XCTAssertThrowsError(try host.verify(responsePayload: good.dropLast())) { XCTAssertEqual($0 as? AuthError, .malformed) }
        XCTAssertThrowsError(try host.verify(responsePayload: Data())) { XCTAssertEqual($0 as? AuthError, .malformed) }
        var longName = good
        longName[1 + 4 + 32 + 65 + 65] = 65
        XCTAssertThrowsError(try host.verify(responsePayload: longName)) { XCTAssertEqual($0 as? AuthError, .malformed) }
        XCTAssertThrowsError(try host.verify(responsePayload: Data(count: AuthWire.maxResponseBytes + 1))) {
            XCTAssertEqual($0 as? AuthError, .malformed)
        }

        // A response signed for another challenge (replay) does not verify.
        let other = try HostHandshake(identityKey: pair("hostIdentity").pub, capabilities: hostCaps, name: str("hostName"))
        XCTAssertThrowsError(try other.verify(responsePayload: good)) { XCTAssertEqual($0 as? AuthError, .badSignature) }
    }

    func testExtensionRecords() throws {
        let list = [AuthExtension(type: 0x7F, value: Data([1, 2, 3])), AuthExtension(type: 0x01, value: Data())]
        let block = try AuthWire.encodeExtensions(list)
        XCTAssertEqual([UInt8](block), [0x7F, 0, 3, 1, 2, 3, 0x01, 0, 0])
        XCTAssertEqual(try AuthWire.decodeExtensions(block), list)
        XCTAssertEqual(try AuthWire.decodeExtensions(Data()), [])
        // A record that runs past the end of the block.
        XCTAssertThrowsError(try AuthWire.decodeExtensions(Data([0x7F, 0, 4, 1, 2, 3])))
        XCTAssertThrowsError(try AuthWire.decodeExtensions(Data([0x7F, 0])))
    }

    // MARK: results

    func testResultBodiesAndHostSignatures() throws {
        let host = try vectorHost()
        let client = try vectorClient()
        let hostKey = try P256.Signing.PrivateKey(rawRepresentation: pair("hostIdentity").priv)
        let cases: [(String, AuthStatus)] = [("accepted", .accepted), ("pending", .pending), ("busy", .busy)]
        for (name, status) in cases {
            let v = result(name)
            XCTAssertEqual((v["status"] as! NSNumber).intValue, Int(status.rawValue), name)
            XCTAssertEqual(toHex(try AuthResult.body(status: status)), v["body"] as! String, name)

            let covered = status.signsEmptyResponse ? Data() : bytes("response")
            let input = AuthWire.hostSignatureInput(challenge: bytes("challenge"), response: covered,
                                                    resultBody: hex(v["body"] as! String))
            XCTAssertEqual(toHex(input), v["signatureInput"] as! String, name)
            XCTAssertTrue(AuthSignature.verify(hex(v["signature"] as! String), over: input,
                                               publicKey: pair("hostIdentity").pub), name)

            // The recorded payload is accepted by a client...
            XCTAssertEqual(try client.status(ofResult: hex(v["payload"] as! String)), status, name)
            // ...and so is one this host signs now.
            let fresh = try host.result(status, response: bytes("response"), sign: AuthSignature.signer(hostKey))
            XCTAssertEqual(fresh.count, 3 + 64)
            XCTAssertEqual(try client.status(ofResult: fresh), status, name)
        }
    }

    func testClientRefusesResultsThatDoNotVerify() throws {
        let client = try vectorClient()
        let accepted = hex(result("accepted")["payload"] as! String)
        let pending = hex(result("pending")["payload"] as! String)

        // Pending relabelled as accepted: the status byte is signed.
        var relabelled = pending
        relabelled[0] = AuthStatus.accepted.rawValue
        XCTAssertThrowsError(try client.status(ofResult: relabelled)) { XCTAssertEqual($0 as? AuthError, .badSignature) }

        // Signed by some other key.
        let stranger = P256.Signing.PrivateKey()
        let host = try vectorHost()
        let forged = try host.result(.accepted, response: bytes("response"), sign: AuthSignature.signer(stranger))
        XCTAssertThrowsError(try client.status(ofResult: forged)) { XCTAssertEqual($0 as? AuthError, .badSignature) }

        // An accepted result for a different response does not carry over.
        let hostKey = try P256.Signing.PrivateKey(rawRepresentation: pair("hostIdentity").priv)
        let forOther = try host.result(.accepted, response: bytes("response") + Data([0]), sign: AuthSignature.signer(hostKey))
        XCTAssertThrowsError(try client.status(ofResult: forOther)) { XCTAssertEqual($0 as? AuthError, .badSignature) }

        XCTAssertThrowsError(try client.status(ofResult: accepted.dropLast())) { XCTAssertEqual($0 as? AuthError, .malformed) }
        var unknownStatus = accepted
        unknownStatus[0] = 9
        XCTAssertThrowsError(try client.status(ofResult: unknownStatus)) { XCTAssertEqual($0 as? AuthError, .malformed) }
    }

    func testClientRefusesBadChallenges() throws {
        let key = P256.Signing.PrivateKey()
        func attempt(_ challenge: Data) throws -> ClientHandshake {
            try ClientHandshake(challengePayload: challenge, deviceKey: key.publicKey.x963Representation,
                                capabilities: [], name: "x", sign: AuthSignature.signer(key))
        }
        let good = bytes("challenge")
        XCTAssertNoThrow(try attempt(good))
        var version = good
        version[0] = 0
        XCTAssertThrowsError(try attempt(version)) { XCTAssertEqual($0 as? AuthError, .unsupportedVersion) }
        var identity = good
        identity[1 + 4 + 32 + 65 + 64] ^= 0x01
        XCTAssertThrowsError(try attempt(identity)) { XCTAssertEqual($0 as? AuthError, .invalidKey) }
        var ephemeral = good
        ephemeral[1 + 4 + 32 + 64] ^= 0x01
        XCTAssertThrowsError(try attempt(ephemeral)) { XCTAssertEqual($0 as? AuthError, .invalidKey) }
        XCTAssertThrowsError(try attempt(good + Data([0]))) { XCTAssertEqual($0 as? AuthError, .malformed) }
        XCTAssertThrowsError(try attempt(good.dropLast())) { XCTAssertEqual($0 as? AuthError, .malformed) }
    }

    // MARK: session keys

    func testTranscriptHashSharedSecretAndKeys() throws {
        XCTAssertEqual(toHex(AuthWire.transcriptHash(challenge: bytes("challenge"), response: bytes("response"))),
                       str("transcriptHash"))
        XCTAssertEqual(toHex(bytes("hostNonce") + bytes("clientNonce")), str("hkdfSalt"))
        XCTAssertEqual(toHex(AuthWire.sessionInfo + bytes("transcriptHash")), str("hkdfInfo"))

        let hostEphemeral = try P256.KeyAgreement.PrivateKey(rawRepresentation: pair("hostEphemeral").priv)
        let clientPublic = try P256.KeyAgreement.PublicKey(x963Representation: pair("clientEphemeral").pub)
        let shared = try hostEphemeral.sharedSecretFromKeyAgreement(with: clientPublic)
        XCTAssertEqual(toHex(shared.withUnsafeBytes { Data($0) }), str("sharedSecret"))

        let keys = SessionKeys.derive(sharedSecret: shared, hostNonce: bytes("hostNonce"),
                                      clientNonce: bytes("clientNonce"),
                                      challenge: bytes("challenge"), response: bytes("response"))
        XCTAssertEqual(toHex(raw(keys.hostToClient) + raw(keys.clientToHost)), str("sessionKeyMaterial"))
        XCTAssertEqual(toHex(raw(keys.hostToClient)), str("keyHostToClient"))
        XCTAssertEqual(toHex(raw(keys.clientToHost)), str("keyClientToHost"))
        XCTAssertEqual(toHex(keys.transcriptHash), str("transcriptHash"))
    }

    func testBothSidesDeriveTheVectorKeys() throws {
        let host = try vectorHost()
        let hostKeys = try host.sessionKeys(with: try host.verify(responsePayload: bytes("response")))
        let clientKeys = try vectorClient().sessionKeys()
        for keys in [hostKeys, clientKeys] {
            XCTAssertEqual(toHex(raw(keys.hostToClient)), str("keyHostToClient"))
            XCTAssertEqual(toHex(raw(keys.clientToHost)), str("keyClientToHost"))
        }
    }

    // MARK: SECURE

    private var secureVectors: [Dict] { root["secure"] as! [Dict] }
    private func key(for direction: String) -> SymmetricKey {
        SymmetricKey(data: bytes(direction == "hostToClient" ? "keyHostToClient" : "keyClientToHost"))
    }

    func testSecureFramesByteForByte() throws {
        XCTAssertEqual(secureVectors.count, 4)
        for direction in ["hostToClient", "clientToHost"] {
            var sealer = SecureSealer(key: key(for: direction))
            var opener = SecureOpener(key: key(for: direction))
            for v in secureVectors where v["direction"] as! String == direction {
                let counter = (v["counter"] as! NSNumber).uint64Value
                XCTAssertEqual(sealer.counter, counter)
                XCTAssertEqual(toHex(SecureFrame.nonce(counter)), v["nonce"] as! String)
                let inner = hex(v["inner"] as! String)
                let frame = hex(v["frame"] as! String)
                XCTAssertEqual(toHex(try sealer.sealMessage(inner)), v["frame"] as! String)

                // The frame is an ordinary SECURE message: type, length, payload.
                XCTAssertEqual(frame.first, StreamMessageType.secure.rawValue)
                XCTAssertEqual(Int(frame.beUInt32(at: 1)), frame.count - 5)
                let opened = try opener.open(frame.subdata(in: 5 ..< frame.count))
                XCTAssertEqual(opened.type, inner.first)
                XCTAssertEqual(opened.payload, inner.subdata(in: 5 ..< inner.count))
            }
            XCTAssertEqual(sealer.counter, 2)
            XCTAssertEqual(opener.counter, 2)
        }
    }

    func testSecureRefusesTamperingReorderingAndTheWrongKey() throws {
        let frames = secureVectors.filter { $0["direction"] as! String == "hostToClient" }
            .map { hex($0["frame"] as! String) }.map { $0.subdata(in: 5 ..< $0.count) }

        var flipped = frames[0]
        flipped[3] ^= 0x01
        var a = SecureOpener(key: key(for: "hostToClient"))
        XCTAssertThrowsError(try a.open(flipped)) { XCTAssertEqual($0 as? AuthError, .decryptFailed) }

        var tag = frames[0]
        tag[tag.count - 1] ^= 0x01
        var b = SecureOpener(key: key(for: "hostToClient"))
        XCTAssertThrowsError(try b.open(tag)) { XCTAssertEqual($0 as? AuthError, .decryptFailed) }

        // Out of order: the second message cannot be opened first.
        var c = SecureOpener(key: key(for: "hostToClient"))
        XCTAssertThrowsError(try c.open(frames[1])) { XCTAssertEqual($0 as? AuthError, .decryptFailed) }

        // Replayed: the first message cannot be opened twice.
        var d = SecureOpener(key: key(for: "hostToClient"))
        XCTAssertNoThrow(try d.open(frames[0]))
        XCTAssertThrowsError(try d.open(frames[0])) { XCTAssertEqual($0 as? AuthError, .decryptFailed) }

        // A message for the other direction does not open.
        var e = SecureOpener(key: key(for: "clientToHost"))
        XCTAssertThrowsError(try e.open(frames[0])) { XCTAssertEqual($0 as? AuthError, .decryptFailed) }

        var f = SecureOpener(key: key(for: "hostToClient"))
        XCTAssertThrowsError(try f.open(Data(count: 15))) { XCTAssertEqual($0 as? AuthError, .decryptFailed) }
        XCTAssertThrowsError(try f.open(Data())) { XCTAssertEqual($0 as? AuthError, .decryptFailed) }
    }

    func testSecureRefusesForbiddenAndMalformedInnerMessages() throws {
        let k = SymmetricKey(size: .bits256)
        // What a hostile peer could seal by hand.
        func handSealed(_ inner: Data, counter: UInt64 = 0) throws -> Data {
            let box = try AES.GCM.seal(inner, using: k, nonce: try AES.GCM.Nonce(data: SecureFrame.nonce(counter)))
            return box.ciphertext + box.tag
        }
        for type in [StreamMessageType.secure, .authChallenge, .authResponse, .authResult] {
            let inner = StreamMessage.frame(type: type, payload: Data([1, 2, 3]))
            var sealer = SecureSealer(key: k)
            XCTAssertThrowsError(try sealer.seal(inner)) { XCTAssertEqual($0 as? AuthError, .forbiddenInnerMessage) }
            XCTAssertEqual(sealer.counter, 0)
            var opener = SecureOpener(key: k)
            XCTAssertThrowsError(try opener.open(try handSealed(inner))) { XCTAssertEqual($0 as? AuthError, .forbiddenInnerMessage) }
        }
        // Not exactly one whole message.
        let whole = StreamMessage.frame(type: .ping)
        for inner in [Data(), Data([0x07]), whole + Data([0]), whole + whole, Data([0x07, 0, 0, 0, 2, 1])] {
            var opener = SecureOpener(key: k)
            XCTAssertThrowsError(try opener.open(try handSealed(inner)), "\(inner.count)") { XCTAssertEqual($0 as? AuthError, .malformed) }
            var sealer = SecureSealer(key: k)
            XCTAssertThrowsError(try sealer.seal(inner), "\(inner.count)")
        }
        // An unknown inner type opens; the caller ignores it.
        var opener = SecureOpener(key: k)
        let unknown = try opener.open(try handSealed(Data([0xEE, 0, 0, 0, 1, 9])))
        XCTAssertEqual(unknown.type, 0xEE)
        XCTAssertEqual(unknown.payload, Data([9]))
    }

    func testCounterLimit() throws {
        let k = SymmetricKey(size: .bits256)
        var last = SecureSealer(key: k, counter: AuthWire.counterLimit - 1)
        let payload = try last.seal(StreamMessage.frame(type: .ping))
        XCTAssertThrowsError(try last.seal(StreamMessage.frame(type: .ping))) { XCTAssertEqual($0 as? AuthError, .counterExhausted) }
        var opener = SecureOpener(key: k, counter: AuthWire.counterLimit - 1)
        XCTAssertNoThrow(try opener.open(payload))
        XCTAssertThrowsError(try opener.open(payload)) { XCTAssertEqual($0 as? AuthError, .counterExhausted) }
    }

    // MARK: a whole exchange with fresh keys

    func testFreshHandshakeRoundTrip() throws {
        let hostKey = P256.Signing.PrivateKey()
        let deviceKey = P256.Signing.PrivateKey()
        let host = try HostHandshake(identityKey: hostKey.publicKey.x963Representation,
                                     capabilities: [.approvalRequired, .textInput], name: "Host\u{202E}")
        XCTAssertEqual(host.challenge.hello.name, "Host")
        let client = try ClientHandshake(challengePayload: host.challenge.payload,
                                         deviceKey: deviceKey.publicKey.x963Representation,
                                         capabilities: [.deviceApproval], name: "Pad",
                                         sign: AuthSignature.signer(deviceKey))
        XCTAssertEqual(client.hostIdentityKey, hostKey.publicKey.x963Representation)
        XCTAssertTrue(client.hostCapabilities.contains(.approvalRequired))

        let device = try host.verify(responsePayload: client.response)
        XCTAssertEqual(device.id, DeviceIdentity.id(ofPublicKey: deviceKey.publicKey.x963Representation))
        XCTAssertEqual(device.name, "Pad")
        XCTAssertTrue(device.capabilities.contains(.deviceApproval))

        let signer = AuthSignature.signer(hostKey)
        XCTAssertEqual(try client.status(ofResult: try host.result(.pending, response: device.response, sign: signer)), .pending)
        XCTAssertEqual(try client.status(ofResult: try host.result(.timeout, response: device.response, sign: signer)), .timeout)
        XCTAssertEqual(try client.status(ofResult: try host.result(.denied, response: device.response, sign: signer)), .denied)
        XCTAssertEqual(try client.status(ofResult: try host.result(.accepted, response: device.response, sign: signer)), .accepted)

        let hostKeys = try host.sessionKeys(with: device)
        let clientKeys = try client.sessionKeys()
        XCTAssertEqual(raw(hostKeys.hostToClient), raw(clientKeys.hostToClient))
        XCTAssertEqual(raw(hostKeys.clientToHost), raw(clientKeys.clientToHost))
        XCTAssertNotEqual(raw(hostKeys.hostToClient), raw(hostKeys.clientToHost))

        var hostSealer = SecureSealer(key: hostKeys.hostToClient)
        var clientOpener = SecureOpener(key: clientKeys.hostToClient)
        var clientSealer = SecureSealer(key: clientKeys.clientToHost)
        var hostOpener = SecureOpener(key: hostKeys.clientToHost)
        for n in 0 ..< 3 {
            let down = StreamMessage.frame(type: .hostInfo, payload: Data("{\"n\":\(n)}".utf8))
            let got = try clientOpener.open(try hostSealer.seal(down))
            XCTAssertEqual(got.type, StreamMessageType.hostInfo.rawValue)
            XCTAssertEqual(got.payload, Data("{\"n\":\(n)}".utf8))
            let up = StreamMessage.hello(requestedCodec: .hevc)
            XCTAssertEqual(try hostOpener.open(try clientSealer.seal(up)).type, StreamMessageType.hello.rawValue)
        }

        // A second connection gets different keys even with the same long-term keys.
        let host2 = try HostHandshake(identityKey: hostKey.publicKey.x963Representation, capabilities: [], name: "Host")
        let client2 = try ClientHandshake(challengePayload: host2.challenge.payload,
                                          deviceKey: deviceKey.publicKey.x963Representation,
                                          capabilities: [], name: "Pad", sign: AuthSignature.signer(deviceKey))
        XCTAssertNotEqual(raw(try client2.sessionKeys().hostToClient), raw(clientKeys.hostToClient))
    }
}
