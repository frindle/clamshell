import Foundation
import CryptoKit

/// A small RFB 3.8 client with ARD authentication, used by the unit tests and
/// by `clamshell rfb-selftest` to drive the server over a real socket.
final class RFBClient {
    struct Rect { var x: Int, y: Int, w: Int, h: Int, encoding: Int32, pixels: [(UInt8, UInt8, UInt8)]? }
    struct ServerInit { var width: Int, height: Int, format: RFBPixelFormat, name: String }

    private let fd: Int32
    private let inflater = RFBInflater()
    var format = RFBPixelFormat.standard

    init?(port: UInt16, timeout: TimeInterval = 10) {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else { close(fd); return nil }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close(fd) }
    func disconnect() { shutdown(fd, SHUT_RDWR) }

    func read(_ n: Int) -> [UInt8]? {
        if n == 0 { return [] }
        var buf = [UInt8](repeating: 0, count: n)
        var got = 0
        while got < n {
            let r = buf.withUnsafeMutableBytes { Foundation.read(fd, $0.baseAddress! + got, n - got) }
            if r > 0 { got += r } else if r < 0 && errno == EINTR { continue } else { return nil }
        }
        return buf
    }

    @discardableResult
    func write(_ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let r = bytes.withUnsafeBytes { Foundation.write(fd, $0.baseAddress! + sent, bytes.count - sent) }
            if r > 0 { sent += r } else if r < 0 && errno == EINTR { continue } else { return false }
        }
        return true
    }

    /// True once the server has closed the connection (or nothing more comes).
    func sawEOF() -> Bool { read(1) == nil }

    /// Exchanges versions and reads the security types. A zero count means the
    /// server refused, with `reason`.
    func negotiate(clientVersion: String = RFB.version) -> (types: [UInt8], reason: String?)? {
        guard let v = read(12), RFB.minorVersion(v) != nil, write(Array(clientVersion.utf8)),
              let count = read(1) else { return nil }
        if count[0] == 0 {
            guard let l = read(4), let r = read(Int(RFBWire.readU32(l, 0))) else { return nil }
            return ([], String(decoding: r, as: UTF8.self))
        }
        guard let types = read(Int(count[0])) else { return nil }
        return (types, nil)
    }

    /// Chooses type 30 and logs in. On failure, `reason` is the server's text.
    func authenticate(user: String, password: String) -> (ok: Bool, reason: String?)? {
        guard write([RFBARD.securityType]), let head = read(4) else { return nil }
        let keyLen = Int(RFBWire.readU16(head, 2))
        guard keyLen == RFBARD.keyLength, let rest = read(keyLen * 2) else { return nil }
        let serverPublic = Array(rest[keyLen...])
        let mine = RFBARD.makeServerKeys()
        guard let key = RFBARD.aesKey(peerPublic: serverPublic, secret: mine.secret),
              let cipher = RFBARD.encryptCredentials(user: user, password: password, key: key),
              write(cipher + mine.publicKey), let result = read(4) else { return nil }
        if RFBWire.readU32(result, 0) == 0 { return (true, nil) }
        guard let l = read(4), let r = read(Int(RFBWire.readU32(l, 0))) else { return (false, nil) }
        return (false, String(decoding: r, as: UTF8.self))
    }

    func initialise() -> ServerInit? {
        guard write([1]), let h = read(24),
              let f = RFBPixelFormat.parse(Array(h[4..<20])),
              let n = read(Int(RFBWire.readU32(h, 20))) else { return nil }
        format = f
        return ServerInit(width: Int(RFBWire.readU16(h, 0)), height: Int(RFBWire.readU16(h, 2)),
                          format: f, name: String(decoding: n, as: UTF8.self))
    }

    func setPixelFormat(_ f: RFBPixelFormat) {
        write([0, 0, 0, 0] + f.bytes)
        format = f
    }

    func setEncodings(_ list: [Int32]) {
        write([2, 0] + RFBWire.u16(UInt16(list.count)) + list.flatMap { RFBWire.i32($0) })
    }

    func requestUpdate(incremental: Bool, x: Int, y: Int, w: Int, h: Int) {
        write([3, incremental ? 1 : 0] + RFBWire.u16(UInt16(x)) + RFBWire.u16(UInt16(y))
              + RFBWire.u16(UInt16(w)) + RFBWire.u16(UInt16(h)))
    }

    func key(_ keysym: UInt32, down: Bool) { write([4, down ? 1 : 0, 0, 0] + RFBWire.u32(keysym)) }
    func pointer(mask: UInt8, x: Int, y: Int) { write([5, mask] + RFBWire.u16(UInt16(x)) + RFBWire.u16(UInt16(y))) }

    /// Reads one server message, which must be a FramebufferUpdate.
    func readUpdate() -> [Rect]? {
        guard let h = read(4), h[0] == 0 else { return nil }
        var rects: [Rect] = []
        for _ in 0..<Int(RFBWire.readU16(h, 2)) {
            guard let r = read(12) else { return nil }
            let x = Int(RFBWire.readU16(r, 0)), y = Int(RFBWire.readU16(r, 2))
            let w = Int(RFBWire.readU16(r, 4)), hh = Int(RFBWire.readU16(r, 6))
            let enc = Int32(bitPattern: RFBWire.readU32(r, 8))
            switch enc {
            case RFBEncoding.raw:
                guard let d = read(w * hh * format.pixelSize) else { return nil }
                var px: [(UInt8, UInt8, UInt8)] = []
                px.reserveCapacity(w * hh)
                for i in 0..<(w * hh) {
                    let o = i * format.pixelSize
                    px.append(format.channels(of: format.readValue(d[o..<(o + format.pixelSize)])))
                }
                rects.append(Rect(x: x, y: y, w: w, h: hh, encoding: enc, pixels: px))
            case RFBEncoding.zrle:
                guard let l = read(4), let z = read(Int(RFBWire.readU32(l, 0))),
                      let px = RFBEncoding.decodeZRLE(l + z, w: w, h: hh, format: format, inflater: inflater) else { return nil }
                rects.append(Rect(x: x, y: y, w: w, h: hh, encoding: enc, pixels: px))
            case RFBEncoding.desktopSize:
                rects.append(Rect(x: x, y: y, w: w, h: hh, encoding: enc, pixels: nil))
            default:
                return nil
            }
        }
        return rects
    }
}

/// `clamshell rfb-selftest`: the server on a scratch loopback port, a client
/// through the handshake and ARD login, and a decoded framebuffer update.
enum RFBSelfTest {
    private struct FixedAuthenticator: RFBAuthenticator {
        func verify(user: String, password: String) -> Bool { user == "selftest" && password == "selftest-pass" }
    }

    static func run(out: (String) -> Void = { print($0) }) -> Bool {
        let w = 150, h = 90
        func color(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            (UInt8(x % 256), UInt8(y % 256), UInt8((x / 8 + y / 8) % 2 == 0 ? 200 : 40))
        }
        let source = RFBStaticFrameSource(width: w, height: h, fill: color)
        let server = RFBServer(options: .init(port: 0, failureDelay: 0), authenticator: FixedAuthenticator(),
                               source: source, makeInput: { nil }, enabled: { true })
        server.log = { _ in }
        guard server.start() else { out("rfb-selftest: could not bind a scratch port"); return false }
        defer { server.stop() }

        func check(_ ok: Bool, _ what: String) -> Bool { out("rfb-selftest: \(what): \(ok ? "ok" : "FAILED")"); return ok }

        guard let c = RFBClient(port: server.boundPort), let sec = c.negotiate() else {
            return check(false, "connect and version")
        }
        guard check(sec.types == [RFBARD.securityType], "only ARD (type 30) is offered") else { return false }
        guard let login = c.authenticate(user: "selftest", password: "selftest-pass"), check(login.ok, "ARD login") else { return false }
        guard let info = c.initialise(), check(info.width == w && info.height == h, "ServerInit \(info.width)x\(info.height)")
        else { return false }
        c.setEncodings([RFBEncoding.zrle, RFBEncoding.raw])
        c.requestUpdate(incremental: false, x: 0, y: 0, w: w, h: h)
        guard let rects = c.readUpdate(), !rects.isEmpty else { return check(false, "framebuffer update") }
        var matches = true
        for r in rects {
            guard let px = r.pixels else { matches = false; continue }
            for yy in 0..<r.h { for xx in 0..<r.w where px[yy * r.w + xx] != color(r.x + xx, r.y + yy) { matches = false } }
        }
        let allZRLE = rects.allSatisfy { $0.encoding == RFBEncoding.zrle }
        guard check(matches && allZRLE, "ZRLE update decodes to the served pixels") else { return false }

        guard let bad = RFBClient(port: server.boundPort), bad.negotiate() != nil,
              let denied = bad.authenticate(user: "selftest", password: "wrong"),
              check(!denied.ok, "a wrong password is refused") else { return false }
        return true
    }
}
