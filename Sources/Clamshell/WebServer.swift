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

    /// Non-nil when dual display mode is on: the point sizes of virtual
    /// displays A and B. Drives the "/" picker page and the /display-a and
    /// /display-b cropped views. nil keeps the classic single-display flow.
    var dualPresets: (a: DisplayPreset, b: DisplayPreset)?

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

        // Dual display mode: picker at "/", cropped per-display views.
        if let dual = dualPresets {
            switch path {
            case "/":
                send(conn, status: "200 OK", contentType: "text/html; charset=utf-8",
                     body: Data(Self.pickerPage(dual: dual).utf8))
                return
            case "/display-a":
                send(conn, status: "200 OK", contentType: "text/html; charset=utf-8",
                     body: Data(Self.cropPage(dual: dual, slot: .a, wsPort: wsPort.rawValue).utf8))
                return
            case "/display-b":
                send(conn, status: "200 OK", contentType: "text/html; charset=utf-8",
                     body: Data(Self.cropPage(dual: dual, slot: .b, wsPort: wsPort.rawValue).utf8))
                return
            default:
                break // static noVNC assets below
            }
        }

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

    // MARK: - Dual display pages

    /// Landing page when dual mode is on: pick which virtual display to view.
    static func pickerPage(dual: (a: DisplayPreset, b: DisplayPreset)) -> String {
        """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Clamshell — Dual Display</title>
        <style>
        body{font-family:-apple-system,sans-serif;background:#111;color:#eee;margin:0;
             display:flex;flex-direction:column;align-items:center;justify-content:center;
             min-height:100vh;gap:1.5em;text-align:center}
        a{display:block;background:#2a6df4;color:#fff;text-decoration:none;
          padding:1em 2em;border-radius:12px;font-size:1.3em;min-width:16em}
        small{color:#999;max-width:34em;padding:0 1em}
        </style></head><body>
        <h1>Clamshell — Dual Display Mode</h1>
        <a href="/display-a">Display A — \(dual.a.name) (\(dual.a.pointsWide)×\(dual.a.pointsHigh))</a>
        <a href="/display-b">Display B — \(dual.b.name) (\(dual.b.pointsWide)×\(dual.b.pointsHigh))</a>
        <small>Open each link in its own browser window (e.g. one on the iPad screen,
        one on the external monitor). The views assume the Mac is collapsed in dual
        display mode; otherwise the crop geometry won't match.</small>
        </body></html>
        """
    }

    /// A minimal noVNC-core page showing only one virtual display's region of
    /// the spanning Screen Sharing framebuffer. Display A sits at x=0, B at
    /// x=A.width (CollapseCoordinator.positionSideBySide), so the crop is a
    /// fixed pan of noVNC's clipped viewport. Vendored noVNC files are used
    /// untouched; only rfb._display's public-shaped pan/size methods are
    /// reached into (input mapping stays correct because Display.absX/absY
    /// account for the viewport offset).
    static func cropPage(dual: (a: DisplayPreset, b: DisplayPreset), slot: VirtualSlot, wsPort: UInt16) -> String {
        """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Clamshell — Display \(slot.rawValue)</title>
        <style>
        html,body{margin:0;background:#000}
        #screen{overflow:hidden;background:#000}
        #status{color:#888;font-family:-apple-system,sans-serif;padding:1em}
        </style></head><body>
        <div id="status">Connecting to Display \(slot.rawValue)…</div>
        <div id="screen"></div>
        <script type="module">
        import RFB from '/core/rfb.js';

        // Virtual display sizes in points; the framebuffer unit (px per point)
        // is derived at runtime so it works whether Screen Sharing serves the
        // desktop in pixels (HiDPI 2x) or points.
        const A = {w: \(dual.a.pointsWide), h: \(dual.a.pointsHigh)};
        const B = {w: \(dual.b.pointsWide), h: \(dual.b.pointsHigh)};
        const IS_B = \(slot == .b);
        const wsUrl = location.protocol === 'https:'
            ? 'wss://' + location.host + '/websockify'
            : 'ws://' + location.hostname + ':\(wsPort)';

        const screen = document.getElementById('screen');
        const status = document.getElementById('status');
        let rfb = null;

        function layout() {
            if (!rfb || !rfb._display || rfb._display.width === 0) { return; }
            const d = rfb._display;
            const unit = d.width / (A.w + B.w); // px per point across the spanning desktop
            const w = Math.round((IS_B ? B.w : A.w) * unit);
            const h = Math.round((IS_B ? B.h : A.h) * unit);
            const x = IS_B ? Math.round(A.w * unit) : 0;
            screen.style.width = w + 'px';
            screen.style.height = h + 'px';
            // iPadOS scales the page so the region fills the screen edge-to-edge.
            document.querySelector('meta[name=viewport]').content = 'width=' + w;
            d.viewportChangeSize(w, h);
            // viewportChangePos is delta-based; absX(0) is the current offset.
            d.viewportChangePos(x - d.absX(0), 0 - d.absY(0));
        }

        function connect() {
            rfb = new RFB(screen, wsUrl, {});
            rfb.clipViewport = true;
            rfb.addEventListener('credentialsrequired', () => {
                rfb.sendCredentials({password: prompt('VNC password')});
            });
            rfb.addEventListener('connect', () => {
                status.style.display = 'none';
                layout();
            });
            rfb.addEventListener('disconnect', () => {
                status.style.display = 'block';
                status.textContent = 'Disconnected — reconnecting…';
                setTimeout(connect, 2000);
            });
        }
        connect();
        // Re-assert crop geometry if the framebuffer changes size (collapse /
        // restore while the page is open). Idempotent, so a cheap poll is fine.
        setInterval(layout, 2000);
        </script></body></html>
        """
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
