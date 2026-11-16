import Foundation
import CryptoKit

// Device authentication and the encrypted session — PROTOCOL.md "Device
// authentication and encrypted session". Foundation and CryptoKit only:
// compiled into the Mac host and the iOS ClamshellViewer client.
//
// Nothing here touches a socket, a clock or a key store. A caller hands in
// the signing function for its long-term key, so the same code serves a key
// kept in a file, in the keychain or in the Secure Enclave.
// `tests/vectors/auth-v1.json` pins every byte this file produces.

// MARK: - Status and errors

enum AuthStatus: UInt8 {
    case accepted = 0
    case pending = 1
    case denied = 2
    case invalid = 3
    case busy = 4
    case timeout = 5

    /// After any other status the host closes the connection.
    var keepsConnection: Bool { self == .accepted || self == .pending }
    /// The host may never have seen a response for these, so their signature
    /// always covers an empty one.
    var signsEmptyResponse: Bool { self == .busy || self == .timeout }
}

enum AuthError: Error, Equatable {
    case malformed
    case unsupportedVersion
    case invalidKey
    case badSignature
    case counterExhausted
    case decryptFailed
    /// The decrypted message was itself SECURE or one of the AUTH messages.
    case forbiddenInnerMessage
}

// MARK: - Wire helpers

/// One `type(1) len(2 BE) value` record. Version 1 defines none; type 0x01 is
/// reserved for an account-signed device certificate.
struct AuthExtension: Equatable {
    let type: UInt8
    let value: Data
}

/// Reads fields off the front of a payload, refusing to run past its end.
struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    var remaining: Int { data.endIndex - offset }
    var atEnd: Bool { remaining == 0 }

    mutating func byte() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func bytes(_ count: Int) -> Data? {
        guard count >= 0, remaining >= count else { return nil }
        defer { offset += count }
        return data.subdata(in: offset ..< offset + count)
    }

    mutating func uint16() -> UInt16? { bytes(2)?.beUInt16(at: 0) }
    mutating func uint32() -> UInt32? { bytes(4)?.beUInt32(at: 0) }
}

enum AuthWire {
    static let version: UInt8 = 1
    static let keyBytes = 65
    static let nonceBytes = 32
    static let signatureBytes = 64
    static let maxNameBytes = 64
    static let tagBytes = 16
    /// The largest AUTH_RESPONSE payload a host reads.
    static let maxResponseBytes = 4096
    /// A side closes the connection before its counter could pass this.
    static let counterLimit: UInt64 = 1 << 48

    static let clientContext = Data("clamshell-auth-v1/client".utf8) + Data([0])
    static let hostContext = Data("clamshell-auth-v1/host".utf8) + Data([0])
    static let sessionInfo = Data("clamshell-session-v1".utf8)

    /// `L(x)`: the 4-byte big-endian length of x, then x.
    static func prefixed(_ x: Data) -> Data {
        var d = Data(capacity: 4 + x.count)
        d.appendBE(UInt32(x.count))
        d.append(x)
        return d
    }

    static func clientSignatureInput(challenge: Data, responseBody: Data) -> Data {
        clientContext + prefixed(challenge) + prefixed(responseBody)
    }

    static func hostSignatureInput(challenge: Data, response: Data, resultBody: Data) -> Data {
        hostContext + prefixed(challenge) + prefixed(response) + prefixed(resultBody)
    }

    static func transcriptHash(challenge: Data, response: Data) -> Data {
        Data(SHA256.hash(data: prefixed(challenge) + prefixed(response)))
    }

    static func randomBytes(_ count: Int) -> Data {
        SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }

    static func encodeExtensions(_ list: [AuthExtension]) throws -> Data {
        var d = Data()
        for e in list {
            guard e.value.count <= Int(UInt16.max) else { throw AuthError.malformed }
            d.append(e.type)
            d.appendBE(UInt16(e.value.count))
            d.append(e.value)
        }
        guard d.count <= Int(UInt16.max) else { throw AuthError.malformed }
        return d
    }

    /// Records fill the block exactly: one that runs past the end makes the
    /// whole message malformed. Unknown types are kept for the caller to skip.
    static func decodeExtensions(_ block: Data) throws -> [AuthExtension] {
        var out: [AuthExtension] = []
        var r = ByteReader(block)
        while !r.atEnd {
            guard let type = r.byte(), let length = r.uint16(), let value = r.bytes(Int(length)) else {
                throw AuthError.malformed
            }
            out.append(AuthExtension(type: type, value: value))
        }
        return out
    }

    /// A name as it is shown: no control characters, no invisible formatting
    /// characters (the bidirectional overrides among them), no space at either
    /// end, and at most 64 bytes of UTF-8 without splitting a character.
    static func cleanName(_ raw: String) -> String {
        var kept = String.UnicodeScalarView()
        for u in raw.unicodeScalars {
            switch u.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned, .privateUse:
                continue
            default:
                kept.append(u)
            }
        }
        let trimmed = String(kept).trimmingCharacters(in: .whitespaces)
        var out = String.UnicodeScalarView()
        var bytes = 0
        for u in trimmed.unicodeScalars {
            let n = String(u).utf8.count
            if bytes + n > maxNameBytes { break }
            bytes += n
            out.append(u)
        }
        return String(out).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Ids and keys

enum DeviceIdentity {
    /// Lowercase hex SHA-256 of the 65-byte public key.
    static func id(ofPublicKey key: Data) -> String {
        SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
    }

    /// `AB12-CD34-EF56-7890`: the first 16 characters of an id, upper case, in
    /// fours. This is what people compare.
    static func fingerprint(ofId id: String) -> String {
        let head = Array(id.uppercased().prefix(16))
        return stride(from: 0, to: head.count, by: 4)
            .map { String(head[$0 ..< min($0 + 4, head.count)]) }
            .joined(separator: "-")
    }

    static func fingerprint(ofPublicKey key: Data) -> String {
        fingerprint(ofId: id(ofPublicKey: key))
    }

    /// A 65-byte uncompressed point (`0x04 ‖ X ‖ Y`) that is on the curve.
    static func isValidPublicKey(_ key: Data) -> Bool {
        guard key.count == AuthWire.keyBytes, key.first == 0x04 else { return false }
        return (try? P256.Signing.PublicKey(x963Representation: key)) != nil
    }
}

/// Signs with a long-term key: 64 raw bytes `r ‖ s`, ECDSA over SHA-256 of the
/// input.
typealias AuthSigner = (Data) throws -> Data

enum AuthSignature {
    static func verify(_ signature: Data, over input: Data, publicKey: Data) -> Bool {
        guard signature.count == AuthWire.signatureBytes,
              DeviceIdentity.isValidPublicKey(publicKey),
              let key = try? P256.Signing.PublicKey(x963Representation: publicKey),
              let parsed = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
        return key.isValidSignature(parsed, for: input)
    }

    static func signer(_ key: P256.Signing.PrivateKey) -> AuthSigner {
        { input in try key.signature(for: input).rawRepresentation }
    }
}

// MARK: - Handshake payloads

/// The fields AUTH_CHALLENGE and AUTH_RESPONSE share, in wire order.
struct AuthHello: Equatable {
    var capabilities: StreamCapabilities
    var nonce: Data
    var ephemeralKey: Data
    var identityKey: Data
    /// As sent. Use `displayName` wherever a person will read it.
    var name: String
    var extensions: [AuthExtension]

    var displayName: String { AuthWire.cleanName(name) }

    static func == (a: AuthHello, b: AuthHello) -> Bool {
        a.capabilities.rawValue == b.capabilities.rawValue && a.nonce == b.nonce
            && a.ephemeralKey == b.ephemeralKey && a.identityKey == b.identityKey
            && a.name == b.name && a.extensions == b.extensions
    }

    func encoded() throws -> Data {
        guard nonce.count == AuthWire.nonceBytes,
              ephemeralKey.count == AuthWire.keyBytes,
              identityKey.count == AuthWire.keyBytes else { throw AuthError.malformed }
        let nameBytes = Data(name.utf8)
        guard nameBytes.count <= AuthWire.maxNameBytes else { throw AuthError.malformed }
        let ext = try AuthWire.encodeExtensions(extensions)
        var d = Data(capacity: 170 + nameBytes.count + ext.count)
        d.append(AuthWire.version)
        d.appendBE(capabilities.rawValue)
        d.append(nonce)
        d.append(ephemeralKey)
        d.append(identityKey)
        d.append(UInt8(nameBytes.count))
        d.append(nameBytes)
        d.appendBE(UInt16(ext.count))
        d.append(ext)
        return d
    }

    /// Reads the shared fields and leaves the reader at whatever follows them.
    static func decode(_ r: inout ByteReader) throws -> AuthHello {
        guard let version = r.byte() else { throw AuthError.malformed }
        guard version == AuthWire.version else { throw AuthError.unsupportedVersion }
        guard let caps = r.uint32(),
              let nonce = r.bytes(AuthWire.nonceBytes),
              let ephemeral = r.bytes(AuthWire.keyBytes),
              let identity = r.bytes(AuthWire.keyBytes),
              let nameLength = r.byte(), Int(nameLength) <= AuthWire.maxNameBytes,
              let nameBytes = r.bytes(Int(nameLength)),
              let extLength = r.uint16(),
              let ext = r.bytes(Int(extLength)) else { throw AuthError.malformed }
        return AuthHello(capabilities: StreamCapabilities(rawValue: caps),
                         nonce: nonce, ephemeralKey: ephemeral, identityKey: identity,
                         name: String(decoding: nameBytes, as: UTF8.self),
                         extensions: try AuthWire.decodeExtensions(ext))
    }
}

struct AuthChallenge {
    let hello: AuthHello
    /// The payload exactly as it crossed the wire: both signatures cover it.
    let payload: Data

    static func decode(_ payload: Data) throws -> AuthChallenge {
        var r = ByteReader(payload)
        let hello = try AuthHello.decode(&r)
        guard r.atEnd else { throw AuthError.malformed }
        return AuthChallenge(hello: hello, payload: payload)
    }
}

struct AuthResponse {
    let hello: AuthHello
    /// The payload without its trailing signature.
    let body: Data
    let signature: Data
    let payload: Data

    /// Layout only. Nothing is trusted until the keys and signature are checked.
    static func decode(_ payload: Data) throws -> AuthResponse {
        var r = ByteReader(payload)
        let hello = try AuthHello.decode(&r)
        guard r.remaining == AuthWire.signatureBytes,
              let signature = r.bytes(AuthWire.signatureBytes) else { throw AuthError.malformed }
        return AuthResponse(hello: hello,
                            body: payload.subdata(in: payload.startIndex ..< payload.endIndex - AuthWire.signatureBytes),
                            signature: signature, payload: payload)
    }
}

struct AuthResult {
    let status: AuthStatus
    let extensions: [AuthExtension]
    let body: Data
    let signature: Data

    static func body(status: AuthStatus, extensions: [AuthExtension] = []) throws -> Data {
        let ext = try AuthWire.encodeExtensions(extensions)
        var d = Data([status.rawValue])
        d.appendBE(UInt16(ext.count))
        d.append(ext)
        return d
    }

    static func decode(_ payload: Data) throws -> AuthResult {
        var r = ByteReader(payload)
        guard let raw = r.byte(), let status = AuthStatus(rawValue: raw),
              let extLength = r.uint16(), let ext = r.bytes(Int(extLength)),
              r.remaining == AuthWire.signatureBytes,
              let signature = r.bytes(AuthWire.signatureBytes) else { throw AuthError.malformed }
        return AuthResult(status: status, extensions: try AuthWire.decodeExtensions(ext),
                          body: payload.subdata(in: payload.startIndex ..< payload.endIndex - AuthWire.signatureBytes),
                          signature: signature)
    }
}

// MARK: - Session keys

struct SessionKeys {
    let hostToClient: SymmetricKey
    let clientToHost: SymmetricKey
    let transcriptHash: Data

    static func derive(sharedSecret: SharedSecret, hostNonce: Data, clientNonce: Data,
                       challenge: Data, response: Data) -> SessionKeys {
        let th = AuthWire.transcriptHash(challenge: challenge, response: response)
        let okm = sharedSecret.hkdfDerivedSymmetricKey(using: SHA256.self,
                                                       salt: hostNonce + clientNonce,
                                                       sharedInfo: AuthWire.sessionInfo + th,
                                                       outputByteCount: 64)
        let bytes = okm.withUnsafeBytes { Data($0) }
        return SessionKeys(hostToClient: SymmetricKey(data: bytes.subdata(in: 0 ..< 32)),
                           clientToHost: SymmetricKey(data: bytes.subdata(in: 32 ..< 64)),
                           transcriptHash: th)
    }
}

// MARK: - SECURE

enum SecureFrame {
    /// `0x00000000 ‖ u64be(counter)`.
    static func nonce(_ counter: UInt64) -> Data {
        var d = Data(count: 4)
        d.appendBE(counter)
        return d
    }

    /// SECURE and the three AUTH messages never travel inside SECURE.
    static func isForbiddenInner(_ type: UInt8) -> Bool {
        type == StreamMessageType.secure.rawValue
            || type == StreamMessageType.authChallenge.rawValue
            || type == StreamMessageType.authResponse.rawValue
            || type == StreamMessageType.authResult.rawValue
    }
}

/// Encrypts one direction. The counter is not sent, so whoever owns this must
/// put messages on the wire in the order they were sealed.
struct SecureSealer {
    private let key: SymmetricKey
    private(set) var counter: UInt64

    init(key: SymmetricKey, counter: UInt64 = 0) {
        self.key = key
        self.counter = counter
    }

    /// The SECURE payload (ciphertext ‖ tag) for one whole inner message.
    mutating func seal(_ inner: Data) throws -> Data {
        guard counter < AuthWire.counterLimit else { throw AuthError.counterExhausted }
        guard inner.count >= 5, Int(inner.beUInt32(at: 1)) == inner.count - 5,
              let type = inner.first, !SecureFrame.isForbiddenInner(type) else {
            throw AuthError.forbiddenInnerMessage
        }
        let box = try AES.GCM.seal(inner, using: key,
                                   nonce: try AES.GCM.Nonce(data: SecureFrame.nonce(counter)))
        counter += 1
        return box.ciphertext + box.tag
    }

    /// The same, framed as a SECURE message ready to send.
    mutating func sealMessage(_ inner: Data) throws -> Data {
        StreamMessage.frame(type: .secure, payload: try seal(inner))
    }
}

/// Decrypts the other direction. Any error means the connection is closed.
struct SecureOpener {
    private let key: SymmetricKey
    private(set) var counter: UInt64

    init(key: SymmetricKey, counter: UInt64 = 0) {
        self.key = key
        self.counter = counter
    }

    /// The inner message of one SECURE payload: its type byte and its payload.
    mutating func open(_ payload: Data) throws -> (type: UInt8, payload: Data) {
        guard counter < AuthWire.counterLimit else { throw AuthError.counterExhausted }
        guard payload.count >= AuthWire.tagBytes else { throw AuthError.decryptFailed }
        let split = payload.endIndex - AuthWire.tagBytes
        let inner: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: SecureFrame.nonce(counter)),
                                            ciphertext: payload.subdata(in: payload.startIndex ..< split),
                                            tag: payload.subdata(in: split ..< payload.endIndex))
            inner = try AES.GCM.open(box, using: key)
        } catch {
            throw AuthError.decryptFailed
        }
        counter += 1
        guard inner.count >= 5, Int(inner.beUInt32(at: 1)) == inner.count - 5 else { throw AuthError.malformed }
        let type = inner[inner.startIndex]
        guard !SecureFrame.isForbiddenInner(type) else { throw AuthError.forbiddenInnerMessage }
        return (type, inner.subdata(in: inner.startIndex + 5 ..< inner.endIndex))
    }
}

// MARK: - Host side

/// A device whose response passed every check. That proves it holds the key
/// it showed; whether the key is trusted is the caller's question.
struct VerifiedDevice {
    let id: String
    let publicKey: Data
    /// Cleaned for display.
    let name: String
    let capabilities: StreamCapabilities
    let extensions: [AuthExtension]
    /// The whole AUTH_RESPONSE payload as received.
    let response: Data
    fileprivate let nonce: Data
    fileprivate let ephemeral: P256.KeyAgreement.PublicKey

    var fingerprint: String { DeviceIdentity.fingerprint(ofId: id) }
}

/// The host's half of one connection's handshake.
struct HostHandshake {
    let challenge: AuthChallenge
    private let ephemeral: P256.KeyAgreement.PrivateKey

    init(identityKey: Data, capabilities: StreamCapabilities, name: String,
         extensions: [AuthExtension] = [],
         ephemeral: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey(),
         nonce: Data = AuthWire.randomBytes(AuthWire.nonceBytes)) throws {
        guard DeviceIdentity.isValidPublicKey(identityKey) else { throw AuthError.invalidKey }
        let hello = AuthHello(capabilities: capabilities, nonce: nonce,
                              ephemeralKey: ephemeral.publicKey.x963Representation,
                              identityKey: identityKey, name: AuthWire.cleanName(name),
                              extensions: extensions)
        self.challenge = AuthChallenge(hello: hello, payload: try hello.encoded())
        self.ephemeral = ephemeral
    }

    /// The version, then that both client keys are valid curve points, then
    /// the signature.
    func verify(responsePayload: Data) throws -> VerifiedDevice {
        guard responsePayload.count <= AuthWire.maxResponseBytes else { throw AuthError.malformed }
        let response = try AuthResponse.decode(responsePayload)
        guard DeviceIdentity.isValidPublicKey(response.hello.identityKey),
              response.hello.ephemeralKey.count == AuthWire.keyBytes,
              response.hello.ephemeralKey.first == 0x04,
              let clientEphemeral = try? P256.KeyAgreement.PublicKey(x963Representation: response.hello.ephemeralKey) else {
            throw AuthError.invalidKey
        }
        let input = AuthWire.clientSignatureInput(challenge: challenge.payload, responseBody: response.body)
        guard AuthSignature.verify(response.signature, over: input, publicKey: response.hello.identityKey) else {
            throw AuthError.badSignature
        }
        return VerifiedDevice(id: DeviceIdentity.id(ofPublicKey: response.hello.identityKey),
                              publicKey: response.hello.identityKey,
                              name: response.hello.displayName,
                              capabilities: response.hello.capabilities,
                              extensions: response.hello.extensions,
                              response: responsePayload,
                              nonce: response.hello.nonce,
                              ephemeral: clientEphemeral)
    }

    /// A signed AUTH_RESULT payload. `response` is the AUTH_RESPONSE payload
    /// this answers, exactly as received; it is left out of the signature for
    /// `busy` and `timeout`.
    func result(_ status: AuthStatus, response: Data, extensions: [AuthExtension] = [],
                sign: AuthSigner) throws -> Data {
        let body = try AuthResult.body(status: status, extensions: extensions)
        let covered = status.signsEmptyResponse ? Data() : response
        let signature = try sign(AuthWire.hostSignatureInput(challenge: challenge.payload,
                                                             response: covered, resultBody: body))
        guard signature.count == AuthWire.signatureBytes else { throw AuthError.badSignature }
        return body + signature
    }

    func sessionKeys(with device: VerifiedDevice) throws -> SessionKeys {
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: device.ephemeral)
        return SessionKeys.derive(sharedSecret: shared, hostNonce: challenge.hello.nonce,
                                  clientNonce: device.nonce, challenge: challenge.payload,
                                  response: device.response)
    }
}

// MARK: - Client side

/// The client's half: reads the challenge, builds the signed response, checks
/// each result against the host key the challenge named.
struct ClientHandshake {
    let challenge: AuthChallenge
    /// The AUTH_RESPONSE payload to send.
    let response: Data
    private let nonce: Data
    private let ephemeral: P256.KeyAgreement.PrivateKey
    private let hostEphemeral: P256.KeyAgreement.PublicKey

    var hostIdentityKey: Data { challenge.hello.identityKey }
    var hostId: String { DeviceIdentity.id(ofPublicKey: challenge.hello.identityKey) }
    var hostFingerprint: String { DeviceIdentity.fingerprint(ofId: hostId) }
    var hostName: String { challenge.hello.displayName }
    var hostCapabilities: StreamCapabilities { challenge.hello.capabilities }

    /// Throws for a challenge of another version or with a key that is not a
    /// valid curve point: either is a failed connection.
    init(challengePayload: Data, deviceKey: Data, capabilities: StreamCapabilities, name: String,
         extensions: [AuthExtension] = [],
         ephemeral: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey(),
         nonce: Data = AuthWire.randomBytes(AuthWire.nonceBytes),
         sign: AuthSigner) throws {
        let challenge = try AuthChallenge.decode(challengePayload)
        guard DeviceIdentity.isValidPublicKey(challenge.hello.identityKey),
              challenge.hello.ephemeralKey.count == AuthWire.keyBytes,
              challenge.hello.ephemeralKey.first == 0x04,
              let hostEphemeral = try? P256.KeyAgreement.PublicKey(x963Representation: challenge.hello.ephemeralKey),
              DeviceIdentity.isValidPublicKey(deviceKey) else { throw AuthError.invalidKey }
        let hello = AuthHello(capabilities: capabilities, nonce: nonce,
                              ephemeralKey: ephemeral.publicKey.x963Representation,
                              identityKey: deviceKey, name: AuthWire.cleanName(name),
                              extensions: extensions)
        let body = try hello.encoded()
        let signature = try sign(AuthWire.clientSignatureInput(challenge: challengePayload, responseBody: body))
        guard signature.count == AuthWire.signatureBytes else { throw AuthError.badSignature }
        self.challenge = challenge
        self.response = body + signature
        self.nonce = nonce
        self.ephemeral = ephemeral
        self.hostEphemeral = hostEphemeral
    }

    /// The status of an AUTH_RESULT whose signature verifies against the
    /// challenge's host key. One that does not verify is a failed connection,
    /// whatever its status says.
    func status(ofResult payload: Data) throws -> AuthStatus {
        let result = try AuthResult.decode(payload)
        let covered = result.status.signsEmptyResponse ? Data() : response
        let input = AuthWire.hostSignatureInput(challenge: challenge.payload, response: covered,
                                                resultBody: result.body)
        guard AuthSignature.verify(result.signature, over: input, publicKey: hostIdentityKey) else {
            throw AuthError.badSignature
        }
        return result.status
    }

    func sessionKeys() throws -> SessionKeys {
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: hostEphemeral)
        return SessionKeys.derive(sharedSecret: shared, hostNonce: challenge.hello.nonce,
                                  clientNonce: nonce, challenge: challenge.payload, response: response)
    }
}
