import Foundation
import Network

/// Browser-based remote desktop: serves the vendored noVNC client over HTTP
/// and bridges WebSocket frames to the Mac's own Screen Sharing service
/// (localhost:5900). No transport is reimplemented — screensharingd does the
/// VNC work; this is a static file server plus a byte pump.
///
///   http://<mac>:5901  → noVNC UI → ws://<mac>:5902 → tcp://127.0.0.1:5900
///
/// Requires "VNC viewers may control screen with password" enabled in the
/// Mac's Screen Sharing settings (noVNC speaks standard VNC auth, not
/// Apple's proprietary auth).
final class WebServer {
    let httpPort: NWEndpoint.Port = 5901
    let wsPort: NWEndpoint.Port = 5902

    /// Specific LAN IP to bind to, or nil for all interfaces.
    var bindHost: String?

    /// The address to advertise in URLs: the bind IP if set, else the
    /// first LAN IPv4.
    var displayHost: String {
        bindHost ?? Self.lanIPv4s().first?.ip ?? "localhost"
    }

    /// Non-loopback IPv4 addresses with their interface names (en0, en1…).
    static func lanIPv4s() -> [(name: String, ip: String)] {
        var result: [(String, String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                result.append((String(cString: ifa.ifa_name), String(cString: host)))
            }
        }
        return result
    }

    /// Fires on the main queue when the count of live browser sessions
    /// transitions between zero and non-zero.
    var onSessionChange: ((Bool) -> Void)?

    private var httpListener: NWListener?
    private var wsListener: NWListener?
    private let queue = DispatchQueue(label: "clamshell.web")
    private var activeSessions = 0

    private(set) var isRunning = false

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        do {
            try startHTTP()
            try startWS()
            isRunning = true
            clog("web access ON: http://\(displayHost):\(httpPort) (ws bridge :\(wsPort), bound to \(bindHost ?? "all interfaces"))")
        } catch {
            clog("web access failed to start: \(error)")
            stop()
        }
    }

    func stop() {
        httpListener?.cancel(); httpListener = nil
        wsListener?.cancel(); wsListener = nil
        isRunning = false
        clog("web access OFF")
    }

    // MARK: - HTTP static server (noVNC assets)

    private func makeListener(_ base: NWParameters, port: NWEndpoint.Port) throws -> NWListener {
        if let host = bindHost {
            base.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)
            return try NWListener(using: base)
        }
        return try NWListener(using: base, on: port)
    }

    private func startHTTP() throws {
        let listener = try makeListener(.tcp, port: httpPort)
        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: self?.queue ?? .global())
            self?.receiveRequest(conn, buffer: Data())
        }
        listener.start(queue: queue)
        httpListener = listener
    }

    private func receiveRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, error in
            guard let self, error == nil, let data else { conn.cancel(); return }
            var buf = buffer
            buf.append(data)
            if let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(data: buf[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
                self.respond(conn, requestHead: head)
            } else if buf.count < 65536 {
                self.receiveRequest(conn, buffer: buf)
            } else {
                conn.cancel()
            }
        }
    }

    private func respond(_ conn: NWConnection, requestHead: String) {
        let requestLine = requestHead.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            send(conn, status: "405 Method Not Allowed", contentType: "text/plain", body: Data("nope".utf8))
            return
        }
        var path = String(parts[1].split(separator: "?").first ?? "/")
        if path == "/" {
            // Land directly in a connected, sensibly-configured session.
            //
            // Behind an HTTPS reverse proxy (Cloudflare Tunnel sends
            // X-Forwarded-Proto), the page must use same-origin wss:// —
            // browsers block plain ws:// from an https page, and the :5902
            // port isn't reachable through the tunnel. noVNC's defaults
            // (port 443, path "websockify", encrypt on for https) are
            // exactly right, so omit the port override and let the proxy
            // route /websockify to the WS bridge.
            let proxiedHTTPS = requestHead.lowercased().contains("x-forwarded-proto: https")
            let redirect = proxiedHTTPS
                ? "/vnc.html?autoconnect=true&resize=remote&reconnect=true"
                : "/vnc.html?autoconnect=true&resize=remote&port=\(wsPort)&reconnect=true"
            let head = "HTTP/1.1 302 Found\r\nLocation: \(redirect)\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in conn.cancel() })
            return
        }

        // Resolve against the vendored noVNC tree; refuse traversal.
        path = path.replacingOccurrences(of: "..", with: "")
        guard let root = Self.novncRoot else {
            send(conn, status: "500 Internal Server Error", contentType: "text/plain",
                 body: Data("noVNC resources missing from bundle".utf8))
            return
        }
        let fileURL = root.appendingPathComponent(String(path.dropFirst()))
        guard let body = try? Data(contentsOf: fileURL) else {
            send(conn, status: "404 Not Found", contentType: "text/plain", body: Data("not found".utf8))
            return
        }
        send(conn, status: "200 OK", contentType: Self.contentType(for: fileURL.pathExtension), body: body)
    }

    private func send(_ conn: NWConnection, status: String, contentType: String, body: Data) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-cache\r\nConnection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        conn.send(content: payload, completion: .contentProcessed { _ in conn.cancel() })
    }

    static var novncRoot: URL? {
        // SwiftPM resource bundle (works for both bare binary and .app —
        // package.sh copies the bundle into Contents/Resources).
        Bundle.module.url(forResource: "novnc", withExtension: nil)
    }

    static func contentType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "application/javascript"
        case "css": return "text/css"
        case "json": return "application/json"
        case "png": return "image/png"
        case "svg": return "image/svg+xml"
        case "ico": return "image/x-icon"
        case "woff", "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }

    // MARK: - WebSocket → VNC bridge

    private func startWS() throws {
        let wsParams = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        wsParams.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let listener = try makeListener(wsParams, port: wsPort)
        listener.newConnectionHandler = { [weak self] ws in
            self?.bridge(ws)
        }
        listener.start(queue: queue)
        wsListener = listener
    }

    private func bridge(_ ws: NWConnection) {
        let vnc = NWConnection(host: "127.0.0.1", port: 5900, using: .tcp)
        var closed = false
        let close: () -> Void = { [weak self] in
            guard !closed else { return }
            closed = true
            ws.cancel()
            vnc.cancel()
            self?.sessionEnded()
        }

        sessionStarted()
        clog("browser VNC session opened")

        ws.stateUpdateHandler = { state in
            if case .failed = state { close() }
            if case .cancelled = state { close() }
        }
        vnc.stateUpdateHandler = { state in
            if case .failed = state { close() }
            if case .cancelled = state { close() }
        }

        func pumpWSToVNC() {
            ws.receiveMessage { data, _, _, error in
                guard error == nil else { close(); return }
                if let data, !data.isEmpty {
                    vnc.send(content: data, completion: .contentProcessed { sendErr in
                        if sendErr != nil { close() } else { pumpWSToVNC() }
                    })
                } else {
                    pumpWSToVNC()
                }
            }
        }
        func pumpVNCToWS() {
            vnc.receive(minimumIncompleteLength: 1, maximumLength: 262144) { data, _, isComplete, error in
                guard error == nil, !isComplete else { close(); return }
                if let data, !data.isEmpty {
                    let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
                    let ctx = NWConnection.ContentContext(identifier: "vnc", metadata: [meta])
                    ws.send(content: data, contentContext: ctx, completion: .contentProcessed { sendErr in
                        if sendErr != nil { close() } else { pumpVNCToWS() }
                    })
                } else {
                    pumpVNCToWS()
                }
            }
        }

        ws.start(queue: queue)
        vnc.start(queue: queue)
        pumpWSToVNC()
        pumpVNCToWS()
    }

    private func sessionStarted() {
        activeSessions += 1
        if activeSessions == 1 {
            DispatchQueue.main.async { self.onSessionChange?(true) }
        }
    }

    private func sessionEnded() {
        activeSessions = max(0, activeSessions - 1)
        clog("browser VNC session closed (\(activeSessions) remaining)")
        if activeSessions == 0 {
            DispatchQueue.main.async { self.onSessionChange?(false) }
        }
    }
}
