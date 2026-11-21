import Foundation
import CryptoKit
import CommonCrypto
import OpenDirectory

/// Modular exponentiation for the Diffie-Hellman step of Apple Remote Desktop
/// authentication, by Montgomery multiplication on 32-bit limbs. The modulus
/// must be odd (a prime here).
struct MontgomeryModulus {
    let n: [UInt32]
    let limbs: Int
    let byteLength: Int
    private let n0inv: UInt32
    private let r2: [UInt32]
    private let one: [UInt32]

    init?(bigEndian bytes: [UInt8]) {
        guard let first = bytes.firstIndex(where: { $0 != 0 }) else { return nil }
        let trimmed = Array(bytes[first...])
        guard trimmed.last.map({ $0 & 1 == 1 }) == true else { return nil }
        byteLength = trimmed.count
        limbs = (trimmed.count + 3) / 4
        n = Self.limbsFromBigEndian(trimmed, count: (trimmed.count + 3) / 4)
        // -n^-1 mod 2^32 by Newton iteration.
        var x = n[0]
        for _ in 0..<5 { x = x &* (2 &- n[0] &* x) }
        n0inv = 0 &- x
        // R mod n and R^2 mod n by repeated doubling.
        var v = [UInt32](repeating: 0, count: limbs)
        v[0] = 1
        func double(_ x: inout [UInt32], _ n: [UInt32], _ limbs: Int) {
            var carry: UInt32 = 0
            for i in 0..<limbs {
                let t = x[i]
                x[i] = (t << 1) | carry
                carry = t >> 31
            }
            if carry != 0 || Self.compare(x, n) >= 0 { Self.subtract(&x, n) }
        }
        for _ in 0..<(32 * limbs) { double(&v, n, limbs) }
        one = v
        for _ in 0..<(32 * limbs) { double(&v, n, limbs) }
        r2 = v
    }

    static func limbsFromBigEndian(_ bytes: [UInt8], count: Int) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: count)
        for (i, byte) in bytes.reversed().enumerated() where i / 4 < count {
            out[i / 4] |= UInt32(byte) << UInt32(8 * (i % 4))
        }
        return out
    }

    static func compare(_ a: [UInt32], _ b: [UInt32]) -> Int {
        var i = a.count - 1
        while i >= 0 {
            if a[i] != b[i] { return a[i] > b[i] ? 1 : -1 }
            i -= 1
        }
        return 0
    }

    static func subtract(_ a: inout [UInt32], _ b: [UInt32]) {
        var borrow: Int64 = 0
        for i in 0..<a.count {
            var d = Int64(a[i]) - Int64(b[i]) - borrow
            if d < 0 { d += 1 << 32; borrow = 1 } else { borrow = 0 }
            a[i] = UInt32(truncatingIfNeeded: d)
        }
    }

    private func montMul(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        let L = limbs
        var t = [UInt32](repeating: 0, count: L + 2)
        for i in 0..<L {
            var carry: UInt64 = 0
            let bi = UInt64(b[i])
            for j in 0..<L {
                let s = UInt64(t[j]) + UInt64(a[j]) * bi + carry
                t[j] = UInt32(truncatingIfNeeded: s)
                carry = s >> 32
            }
            let s1 = UInt64(t[L]) + carry
            t[L] = UInt32(truncatingIfNeeded: s1)
            t[L + 1] = UInt32(truncatingIfNeeded: s1 >> 32)
            let m = UInt64(t[0] &* n0inv)
            var c2 = (UInt64(t[0]) + m * UInt64(n[0])) >> 32
            if L > 1 {
                for j in 1..<L {
                    let s = UInt64(t[j]) + m * UInt64(n[j]) + c2
                    t[j - 1] = UInt32(truncatingIfNeeded: s)
                    c2 = s >> 32
                }
            }
            let s2 = UInt64(t[L]) + c2
            t[L - 1] = UInt32(truncatingIfNeeded: s2)
            t[L] = t[L + 1] &+ UInt32(truncatingIfNeeded: s2 >> 32)
        }
        var r = Array(t[0..<L])
        if t[L] != 0 || Self.compare(r, n) >= 0 { Self.subtract(&r, n) }
        return r
    }

    /// base^exponent mod n, all big endian. The base is taken as given (the
    /// caller checks its range); the result is `byteLength` bytes.
    func power(base: [UInt8], exponent: [UInt8]) -> [UInt8] {
        let b = Self.limbsFromBigEndian(base, count: limbs)
        let baseM = montMul(b, r2)
        var result = one
        for byte in exponent {
            for bit in stride(from: 7, through: 0, by: -1) {
                result = montMul(result, result)
                if (byte >> UInt8(bit)) & 1 == 1 { result = montMul(result, baseM) }
            }
        }
        var plain = [UInt32](repeating: 0, count: limbs)
        plain[0] = 1
        let out = montMul(result, plain)
        var bytes = [UInt8]()
        for limb in out.reversed() {
            bytes.append(UInt8(limb >> 24)); bytes.append(UInt8((limb >> 16) & 0xFF))
            bytes.append(UInt8((limb >> 8) & 0xFF)); bytes.append(UInt8(limb & 0xFF))
        }
        return Array(bytes.suffix(byteLength))
    }
}

/// Apple Remote Desktop authentication (RFB security type 30): a
/// Diffie-Hellman exchange, then the username and password sent as 128 bytes
/// of AES-128 (ECB) under the MD5 of the shared secret.
enum RFBARD {
    static let securityType: UInt8 = 30
    static let generator: UInt16 = 2
    /// RFC 2409 second Oakley group (1024 bit), a safe prime.
    static let prime: [UInt8] = hex(
        "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74"
        + "020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437"
        + "4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED"
        + "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE65381FFFFFFFFFFFFFFFF")
    static let modulus = MontgomeryModulus(bigEndian: prime)!
    static var keyLength: Int { modulus.byteLength }
    /// Secret exponent size: 256 bits is ample for a 1024-bit group and keeps
    /// the exchange fast.
    static let exponentBytes = 32

    static func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    struct ServerKeys {
        let secret: [UInt8]
        let publicKey: [UInt8]
    }

    static func makeServerKeys(secret: [UInt8]? = nil) -> ServerKeys {
        let s = secret ?? (0..<exponentBytes).map { _ in UInt8.random(in: 0...255) }
        return ServerKeys(secret: s, publicKey: modulus.power(base: [UInt8(generator)], exponent: s))
    }

    /// The Diffie-Hellman message the server sends after the client picks type 30.
    static func serverHello(_ keys: ServerKeys) -> [UInt8] {
        RFBWire.u16(generator) + RFBWire.u16(UInt16(keyLength)) + prime + keys.publicKey
    }

    /// The peer's public value must be strictly between 1 and p-1.
    static func validPublic(_ value: [UInt8]) -> Bool {
        guard value.count == keyLength else { return false }
        let v = MontgomeryModulus.limbsFromBigEndian(value, count: modulus.limbs)
        var one = [UInt32](repeating: 0, count: modulus.limbs); one[0] = 1
        var pMinusOne = modulus.n
        MontgomeryModulus.subtract(&pMinusOne, one)
        return MontgomeryModulus.compare(v, one) > 0 && MontgomeryModulus.compare(v, pMinusOne) < 0
    }

    static func aesKey(peerPublic: [UInt8], secret: [UInt8]) -> [UInt8]? {
        guard validPublic(peerPublic) else { return nil }
        let shared = modulus.power(base: peerPublic, exponent: secret)
        return Array(Insecure.MD5.hash(data: Data(shared)))
    }

    private static func ecb(_ op: Int, _ key: [UInt8], _ input: [UInt8]) -> [UInt8]? {
        guard key.count == 16, input.count == 128 else { return nil }
        var out = [UInt8](repeating: 0, count: 128)
        var moved = 0
        let status = CCCrypt(CCOperation(op), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                             key, 16, nil, input, 128, &out, 128, &moved)
        return status == kCCSuccess && moved == 128 ? out : nil
    }

    /// The 128-byte client reply: 64 bytes of username, 64 of password, each
    /// ended by a NUL and padded with random bytes.
    static func encryptCredentials(user: String, password: String, key: [UInt8]) -> [UInt8]? {
        var block = (0..<128).map { _ in UInt8.random(in: 0...255) }
        for (offset, text) in [(0, user), (64, password)] {
            let bytes = Array(text.utf8.prefix(63))
            for (i, b) in bytes.enumerated() { block[offset + i] = b }
            block[offset + bytes.count] = 0
        }
        return ecb(kCCEncrypt, key, block)
    }

    static func decryptCredentials(_ cipher: [UInt8], key: [UInt8]) -> (user: String, password: String)? {
        guard let plain = ecb(kCCDecrypt, key, cipher) else { return nil }
        func field(_ r: Range<Int>) -> String? {
            let bytes = plain[r].prefix(while: { $0 != 0 })
            return String(bytes: bytes, encoding: .utf8)
        }
        guard let user = field(0..<64), let password = field(64..<128) else { return nil }
        return (user, password)
    }
}

/// Checks a username and password. Never logs or keeps the password.
protocol RFBAuthenticator {
    func verify(user: String, password: String) -> Bool
}

/// The Mac's own accounts, through OpenDirectory: the check Screen Sharing
/// does. Works from the user session and from the login window (as root).
struct OpenDirectoryAuthenticator: RFBAuthenticator {
    func verify(user: String, password: String) -> Bool {
        guard !user.isEmpty, !password.isEmpty, user.count <= 255 else { return false }
        do {
            let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication))
            let record = try node.record(withRecordType: kODRecordTypeUsers, name: user, attributes: nil)
            try record.verifyPassword(password)
            return true
        } catch {
            return false
        }
    }
}

/// Slows password guessing. Each failure is remembered for a window; a peer
/// with too many, or the whole server with too many, is refused until the
/// window passes. Peers are whatever address the connection came from.
final class RFBRateLimiter {
    private let lock = NSLock()
    private let now: () -> TimeInterval
    private let perPeerLimit: Int
    private let globalLimit: Int
    private let window: TimeInterval
    private var failures: [String: [TimeInterval]] = [:]
    private var all: [TimeInterval] = []

    init(perPeerLimit: Int = 3, globalLimit: Int = 20, window: TimeInterval = 60,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.perPeerLimit = perPeerLimit
        self.globalLimit = globalLimit
        self.window = window
        self.now = now
    }

    private func prune(_ t: TimeInterval) {
        all.removeAll { t - $0 > window }
        for (k, v) in failures {
            let kept = v.filter { t - $0 <= window }
            if kept.isEmpty { failures[k] = nil } else { failures[k] = kept }
        }
    }

    func allowed(peer: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let t = now()
        prune(t)
        return (failures[peer]?.count ?? 0) < perPeerLimit && all.count < globalLimit
    }

    func recordFailure(peer: String) {
        lock.lock(); defer { lock.unlock() }
        let t = now()
        prune(t)
        failures[peer, default: []].append(t)
        all.append(t)
    }

    func recordSuccess(peer: String) {
        lock.lock(); defer { lock.unlock() }
        failures[peer] = nil
    }
}
