import Foundation

/// Clamshell's own RFB 3.8 server. It listens on loopback only; the pf
/// redirect (see Redirect.swift) is what makes it answer on port 5900.
///
/// The same server code runs in the Clamshell app (the user's session) and in
/// the login-window agent, whichever owns the screen; the agent exits when a
/// user logs in, and the app keeps retrying to bind until the port is free.
///
/// Security: only type 30 (Apple Remote Desktop authentication) is offered, so
/// there is no password-only VNC and no "none". The password is checked
/// against the Mac's own accounts. The Screen Sharing switch gates every new
/// client and ends open ones.
final class RFBServer {
    struct Options {
        var port: UInt16
        var serverName = "Clamshell"
        /// Longest a client may take over the handshake and login, in all
        /// (each read also times out after this long).
        var handshakeTimeout: TimeInterval = 20
        var maxClients = 8
        var failureDelay: TimeInterval = 1
        /// Most clients one address may have mid-handshake at once, so one
        /// peer can neither fill every slot nor try many passwords in parallel.
        var perPeerPending = 3
    }

    static let offReason = "Remote access is turned off on this Mac."
    static let tooManyReason = "Too many failed attempts. Try again in a minute."

    let options: Options
    let authenticator: RFBAuthenticator
    let source: RFBFrameSource
    let limiter: RFBRateLimiter
    /// A new input sink per client, or nil where input cannot be injected.
    let makeInput: () -> RFBInputSink?
    /// Whether the Screen Sharing switch is on.
    let enabled: () -> Bool
    /// Told when a client is let in (true) and when it leaves (false).
    var sessionObserver: ((AnyObject, Bool) -> Void)?
    var log: (String) -> Void = { clog($0) }

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var sessions: [ObjectIdentifier: RFBSession] = [:]
    /// Accepted but not yet logged in.
    private var pending: [ObjectIdentifier: RFBSession] = [:]
    private var stopped = false
    private var switchObserver: NSObjectProtocol?

    init(options: Options, authenticator: RFBAuthenticator, source: RFBFrameSource,
         limiter: RFBRateLimiter = RFBRateLimiter(),
         makeInput: @escaping () -> RFBInputSink?, enabled: @escaping () -> Bool) {
        self.options = options
        self.authenticator = authenticator
        self.source = source
        self.limiter = limiter
        self.makeInput = makeInput
        self.enabled = enabled
    }

    deinit { stop() }

    /// The port in use (useful when started with port 0).
    private(set) var boundPort: UInt16 = 0

    /// Binds 127.0.0.1 and starts accepting. false when the port is taken.
    func start() -> Bool {
        lock.lock()
        guard listenFD < 0 else { lock.unlock(); return true }
        stopped = false
        lock.unlock()

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = options.port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); return false }
        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        boundPort = UInt16(bigEndian: actual.sin_port)

        lock.lock()
        listenFD = fd
        lock.unlock()

        switchObserver = NotificationCenter.default.addObserver(
            forName: RemoteAccessSwitch.didChange, object: nil, queue: nil) { [weak self] _ in
            guard let self, !self.enabled() else { return }
            self.log("RFB: the Screen Sharing switch is off; dropping open sessions")
            self.dropAll()
        }
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "clamshell.rfb.accept"
        thread.start()
        log("RFB: listening on 127.0.0.1:\(boundPort)")
        return true
    }

    /// Keeps trying to bind (the other process that owns the port may be
    /// about to exit), on a background thread. Returns at once.
    func startWhenPossible(retryEvery: TimeInterval = 3) {
        let thread = Thread { [weak self] in
            var logged = false
            while let self {
                self.lock.lock(); let done = self.stopped || self.listenFD >= 0; self.lock.unlock()
                if done { return }
                if self.start() { return }
                if !logged { self.log("RFB: port \(self.options.port) is busy; will keep trying"); logged = true }
                Thread.sleep(forTimeInterval: retryEvery)
            }
        }
        thread.name = "clamshell.rfb.bind"
        lock.lock(); stopped = false; lock.unlock()
        thread.start()
    }

    func stop() {
        lock.lock()
        stopped = true
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if let o = switchObserver { NotificationCenter.default.removeObserver(o); switchObserver = nil }
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd) }
        dropAll()
    }

    /// Closes every open client, and any still logging in.
    func dropAll() {
        lock.lock()
        let open = Array(sessions.values) + Array(pending.values)
        lock.unlock()
        for s in open { s.terminate() }
    }

    var clientCount: Int { lock.lock(); defer { lock.unlock() }; return sessions.count }

    private func acceptLoop(_ fd: Int32) {
        while true {
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let c = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &len) }
            }
            if c < 0 {
                lock.lock(); let over = stopped || listenFD != fd; lock.unlock()
                if over { return }
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            var yes: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(c, SOL_SOCKET, SO_KEEPALIVE, &yes, socklen_t(MemoryLayout<Int32>.size))
            var one: Int32 = 1
            setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            let session = RFBSession(server: self, fd: c, peer: Self.peerName(c))
            lock.lock()
            let full = sessions.count + pending.count >= options.maxClients
                || pending.values.filter({ $0.peer == session.peer }).count >= options.perPeerPending
            if !full { pending[ObjectIdentifier(session)] = session }
            lock.unlock()
            if full { close(c); continue }
            let t = Thread { session.run() }
            t.name = "clamshell.rfb.session"
            t.stackSize = 1 << 21
            t.start()
        }
    }

    static func peerName(_ fd: Int32) -> String {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &len) }
        }
        guard ok == 0 else { return "unknown" }
        var a = addr.sin_addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }

    fileprivate func admit(_ s: RFBSession) {
        lock.lock(); pending[ObjectIdentifier(s)] = nil; sessions[ObjectIdentifier(s)] = s; lock.unlock()
    }
    fileprivate func gone(_ s: RFBSession) {
        lock.lock(); sessions[ObjectIdentifier(s)] = nil; pending[ObjectIdentifier(s)] = nil; lock.unlock()
    }
}

/// One client, on its own thread.
final class RFBSession {
    private let server: RFBServer
    private let fd: Int32
    fileprivate let peer: String
    // Lock order: writeLock, then stateLock. The fd is closed holding both, and
    // every write and shutdown first checks `closed`, so neither can reach a
    // number the system has since handed to another connection.
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var closed = false

    // Update state, guarded by stateLock.
    private var wantsUpdate = false
    private var requestIncremental = true
    private var request = RFBFramebufferTracker.Rect(x: 0, y: 0, w: 0, h: 0)
    private var format = RFBPixelFormat.standard
    private var encodings: [Int32] = []

    init(server: RFBServer, fd: Int32, peer: String) {
        self.server = server
        self.fd = fd
        self.peer = peer
    }

    /// Ends the session from any thread: blocked reads and writes return.
    func terminate() {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !closed else { return }
        closed = true
        shutdown(fd, SHUT_RDWR)
    }

    private func closeSocket() {
        writeLock.lock(); stateLock.lock()
        closed = true
        close(fd)
        stateLock.unlock(); writeLock.unlock()
    }

    private var isClosed: Bool { stateLock.lock(); defer { stateLock.unlock() }; return closed }

    // MARK: socket helpers

    private func read(_ n: Int) -> [UInt8]? {
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
    private func write(_ bytes: [UInt8]) -> Bool {
        writeLock.lock(); defer { writeLock.unlock() }
        if isClosed { return false }
        var sent = 0
        while sent < bytes.count {
            let r = bytes.withUnsafeBytes { Foundation.write(fd, $0.baseAddress! + sent, bytes.count - sent) }
            if r > 0 { sent += r } else if r < 0 && errno == EINTR { continue } else { return false }
        }
        return true
    }

    private func setTimeout(_ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private func failure(_ reason: String) {
        var m = RFBWire.u32(1)
        m += reasonBytes(reason)
        write(m)
    }

    /// A length-prefixed reason string.
    private func reasonBytes(_ reason: String) -> [UInt8] {
        let text = Array(reason.utf8)
        var m = RFBWire.u32(UInt32(text.count))
        m += text
        return m
    }

    /// "No security types", then why: the way a refusal before login is told.
    private func refuse(_ reason: String) {
        var m: [UInt8] = [0]
        m += reasonBytes(reason)
        write(m)
    }

    // MARK: handshake

    func run() {
        var admitted = false
        var input: RFBInputSink?
        var sourceHeld = false
        // The handshake deadline is for the whole login, not each read: a
        // client trickling bytes cannot hold a slot past it.
        let deadline = DispatchWorkItem { [weak self] in self?.terminate() }
        defer {
            deadline.cancel()
            if sourceHeld { server.source.releaseFrames() }
            if let input { input.releaseAll() }
            if admitted { server.sessionObserver?(self, false) }
            closeSocket()
            server.gone(self)
            if admitted { server.log("RFB: client \(peer) left") }
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + server.options.handshakeTimeout, execute: deadline)
        setTimeout(server.options.handshakeTimeout)
        guard write(Array(RFB.version.utf8)), let hello = read(12),
              let minor = RFB.minorVersion(hello), minor >= 7 else { return }

        // Switch off: say so and stop, before any login is offered.
        if !server.enabled() {
            refuse(RFBServer.offReason)
            server.log("RFB: refused \(peer): the Screen Sharing switch is off")
            return
        }
        if !server.limiter.allowed(peer: peer) {
            refuse(RFBServer.tooManyReason)
            server.log("RFB: refused \(peer): too many failed logins")
            return
        }

        // Only Apple Remote Desktop authentication is on offer.
        guard write([1, RFBARD.securityType]), let choice = read(1) else { return }
        guard choice[0] == RFBARD.securityType else { failure("Unsupported security type."); return }

        let keys = RFBARD.makeServerKeys()
        guard write(RFBARD.serverHello(keys)),
              let reply = read(128 + RFBARD.keyLength) else { return }
        let cipher = Array(reply[0..<128]), clientPublic = Array(reply[128...])
        var ok = false
        if let key = RFBARD.aesKey(peerPublic: clientPublic, secret: keys.secret),
           let cred = RFBARD.decryptCredentials(cipher, key: key) {
            ok = server.authenticator.verify(user: cred.user, password: cred.password)
        }
        if !ok {
            server.limiter.recordFailure(peer: peer)
            Thread.sleep(forTimeInterval: server.options.failureDelay)
            failure("Authentication failed.")
            server.log("RFB: login failed from \(peer)")
            return
        }
        // The switch could have been turned off while the client typed.
        guard server.enabled() else { failure(RFBServer.offReason); return }
        server.limiter.recordSuccess(peer: peer)
        guard write(RFBWire.u32(0)), read(1) != nil else { return }   // result, then ClientInit

        guard server.source.acquireFrames() else {
            server.log("RFB: no screen to share for \(peer)")
            return
        }
        sourceHeld = true
        let size = server.source.size
        let name = Array(server.options.serverName.utf8)
        var serverInit = RFBWire.u16(UInt16(size.width)) + RFBWire.u16(UInt16(size.height))
        serverInit += RFBPixelFormat.standard.bytes
        serverInit += RFBWire.u32(UInt32(name.count))
        serverInit += name
        guard write(serverInit) else { return }
        deadline.cancel()
        guard !isClosed else { return }   // the deadline passed just now

        admitted = true
        server.admit(self)
        server.sessionObserver?(self, true)
        server.log("RFB: client \(peer) connected")
        input = server.makeInput()
        setTimeout(0)

        let keyboard = input.map { RFBKeyboard(sink: $0) }
        let pointer = input.map { RFBPointer(sink: $0, width: size.width, height: size.height) }
        let updater = Thread { [weak self] in self?.updateLoop(size: size, pointer: pointer) }
        updater.name = "clamshell.rfb.updates"
        updater.start()
        messageLoop(keyboard: keyboard, pointer: pointer)
        terminate()
    }

    // MARK: client messages

    private func messageLoop(keyboard: RFBKeyboard?, pointer: RFBPointer?) {
        while !isClosed {
            guard let t = read(1) else { return }
            switch t[0] {
            case 0: // SetPixelFormat
                guard let b = read(19), let f = RFBPixelFormat.parse(Array(b[3...])), f.isSupported else { return }
                // Everything already sent is in the old format: send it all again.
                stateLock.lock(); format = f; resetTracker = true; stateLock.unlock()
            case 2: // SetEncodings
                guard let h = read(3) else { return }
                let n = Int(RFBWire.readU16(h, 1))
                guard n <= 1024, let b = read(n * 4) else { return }
                let list = (0..<n).map { Int32(bitPattern: RFBWire.readU32(b, $0 * 4)) }
                stateLock.lock(); encodings = list; stateLock.unlock()
            case 3: // FramebufferUpdateRequest
                guard let b = read(9) else { return }
                stateLock.lock()
                request = RFBFramebufferTracker.Rect(x: Int(RFBWire.readU16(b, 1)), y: Int(RFBWire.readU16(b, 3)),
                                                     w: Int(RFBWire.readU16(b, 5)), h: Int(RFBWire.readU16(b, 7)))
                requestIncremental = b[0] != 0
                wantsUpdate = true
                stateLock.unlock()
            case 4: // KeyEvent
                guard let b = read(7) else { return }
                keyboard?.key(keysym: RFBWire.readU32(b, 3), down: b[0] != 0)
            case 5: // PointerEvent
                guard let b = read(5) else { return }
                pointer?.event(mask: b[0], x: Int(RFBWire.readU16(b, 1)), y: Int(RFBWire.readU16(b, 3)))
            case 6: // ClientCutText: read and ignore (clipboard sharing is not offered)
                guard let h = read(7) else { return }
                let n = Int(RFBWire.readU32(h, 3))
                guard n <= 1 << 20, read(n) != nil else { return }
            default:
                return // an unknown message cannot be skipped
            }
        }
    }

    // MARK: updates

    private var resetTracker = false

    private func updateLoop(size: (width: Int, height: Int), pointer: RFBPointer?) {
        var tracker = RFBFramebufferTracker(width: size.width, height: size.height)
        var announced = size
        let deflater = RFBDeflater()
        while !isClosed {
            Thread.sleep(forTimeInterval: 0.02)
            stateLock.lock()
            let want = wantsUpdate, req = request, incremental = requestIncremental
            let fmt = format, encs = encodings
            let reset = resetTracker
            resetTracker = false
            stateLock.unlock()
            if reset { tracker.reset(width: announced.width, height: announced.height) }
            guard want else { continue }

            let current = server.source.size
            if current != announced {
                // The display changed size. Clients that know DesktopSize are
                // told; the others cannot be, so they are let go.
                guard encs.contains(RFBEncoding.desktopSize) else { server.log("RFB: display size changed; closing \(peer)"); terminate(); return }
                announced = current
                tracker = RFBFramebufferTracker(width: current.width, height: current.height)
                pointer?.resize(width: current.width, height: current.height)
                var msg: [UInt8] = [0, 0]
                msg += RFBWire.u16(1)
                msg += RFBWire.u16(0) + RFBWire.u16(0)
                msg += RFBWire.u16(UInt16(current.width)) + RFBWire.u16(UInt16(current.height))
                msg += RFBWire.i32(RFBEncoding.desktopSize)
                guard write(msg) else { terminate(); return }
                stateLock.lock(); wantsUpdate = false; stateLock.unlock()
                continue
            }

            let region = RFBFramebufferTracker.Rect(
                x: min(req.x, announced.width), y: min(req.y, announced.height),
                w: min(req.w, announced.width - min(req.x, announced.width)),
                h: min(req.h, announced.height - min(req.y, announced.height)))
            if !incremental { tracker.invalidate(region) }
            var message: [UInt8]?
            server.source.withLatestFrame { frame in
                let rects = tracker.changes(in: frame, region: region)
                guard !rects.isEmpty else { return }
                let useZRLE = encs.contains(RFBEncoding.zrle)
                var body: [UInt8] = []
                for r in rects {
                    body += RFBWire.u16(UInt16(r.x)) + RFBWire.u16(UInt16(r.y))
                    body += RFBWire.u16(UInt16(r.w)) + RFBWire.u16(UInt16(r.h))
                    if useZRLE, let z = RFBEncoding.zrleRect(frame, x: r.x, y: r.y, w: r.w, h: r.h, format: fmt, deflater: deflater) {
                        body += RFBWire.i32(RFBEncoding.zrle) + z
                    } else {
                        body += RFBWire.i32(RFBEncoding.raw)
                        body += RFBEncoding.rawRect(frame, x: r.x, y: r.y, w: r.w, h: r.h, format: fmt)
                    }
                    tracker.commit(r, frame: frame)
                }
                var m: [UInt8] = [0, 0]
                m += RFBWire.u16(UInt16(rects.count))
                m += body
                message = m
            }
            guard let message else { continue }   // nothing changed yet: keep waiting
            stateLock.lock(); wantsUpdate = false; stateLock.unlock()
            guard write(message) else { terminate(); return }
        }
    }
}

enum RFB {
    static let version = "RFB 003.008\n"

    /// The minor version in a client's "RFB 003.xxx\n", or nil.
    static func minorVersion(_ hello: [UInt8]) -> Int? {
        guard hello.count == 12, let s = String(bytes: hello, encoding: .ascii),
              s.hasPrefix("RFB 003."), s.hasSuffix("\n"),
              let minor = Int(s.dropFirst(8).dropLast()) else { return nil }
        return minor
    }
}
