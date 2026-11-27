import AppKit
import Foundation
import Network

/// Serves Clamshell's own browser client (Resources/webclient) over HTTP and
/// bridges its WebSocket to the native stream servers. Nothing here depends on
/// Apple's Screen Sharing: the lock screen and login window are carried by the
/// same native stream.
///
///   http://<mac>:5901/client  -> ws://<mac>:5906..5908 -> local stream servers
final class WebServer {
    let httpPort: NWEndpoint.Port = 5901

    /// Specific LAN IPs to bind to; empty = all interfaces. Multiple entries
    /// mean "these interfaces and no others" (e.g. Ethernet + Tailscale but
    /// not Wi-Fi) — one listener per address, since an NWListener binds a
    /// single local endpoint.
    var bindHosts: [String] = []

    /// The secret every /clipboard request must carry. There is always one:
    /// a server starts with a random token of its own, and setting an empty
    /// one makes another. The menu-bar app keeps its token in the
    /// preferences (`defaults write com.frindle.clamshell clipboardToken
    /// <secret>`) so a page that was open before a relaunch goes on working.
    ///
    /// The pages this server hands out carry the token, so it keeps out
    /// what never loaded one: another website open in the same browser, or
    /// a script that only knows the address. It does not keep out anyone
    /// who can load a page.
    var clipboardToken: String = WebServer.newClipboardToken() {
        didSet { if clipboardToken.isEmpty { clipboardToken = WebServer.newClipboardToken() } }
    }

    /// 16 random bytes as 32 hex characters.
    static func newClipboardToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in
            String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator))
        }.joined()
    }

    /// The value of the query item called `name` in a request target,
    /// percent-decoded. nil when there is no such item, when it has no `=`,
    /// or when its value is not valid percent-encoding.
    static func queryValue(named name: String, in target: String) -> String? {
        var rest = Substring(target)
        if let hash = rest.firstIndex(of: "#") { rest = rest[..<hash] }
        guard let mark = rest.firstIndex(of: "?") else { return nil }
        for item in rest[rest.index(after: mark)...].split(separator: "&") {
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, pair[0] == name else { continue }
            return String(pair[1]).removingPercentEncoding
        }
        return nil
    }

    /// The credential of the `Authorization: Bearer …` header in a request
    /// head. Only that header counts: the word "Bearer" anywhere else in the
    /// request means nothing.
    static func bearer(in head: String) -> String? {
        let scheme = "bearer "
        for line in head.split(separator: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "authorization" else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard value.count > scheme.count, value.prefix(scheme.count).lowercased() == scheme else { return nil }
            return value.dropFirst(scheme.count).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Whether two tokens are the same bytes. The time it takes depends on
    /// their length, not on where they differ. Nothing equals an empty token.
    static func sameToken(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard !x.isEmpty, x.count == y.count else { return false }
        var difference: UInt8 = 0
        for i in x.indices { difference |= x[i] ^ y[i] }
        return difference == 0
    }

    /// Whether a request carries exactly `token`, as its `token` query item
    /// or as a bearer credential.
    static func carriesToken(_ token: String, target: String, head: String) -> Bool {
        if let presented = queryValue(named: "token", in: target), sameToken(presented, token) { return true }
        if let presented = bearer(in: head), sameToken(presented, token) { return true }
        return false
    }

    /// The token as it is written into a page: percent-encoded down to
    /// letters, digits and `-._~`, so whatever the user chose as a secret it
    /// cannot end a script string or an HTML attribute.
    static func encodedToken(_ token: String) -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return token.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    static let clipboardTokenMetaName = "clamshell-clipboard-token"

    /// The web client's page with the token in a `<meta>` tag at the end of
    /// its head, where client.js reads it. A page with no head is returned
    /// as it is.
    static func withClipboardToken(_ page: Data, token: String) -> Data {
        guard let end = page.range(of: Data("</head>".utf8)) else { return page }
        let tag = "<meta name=\"\(clipboardTokenMetaName)\" content=\"\(encodedToken(token))\">"
        var out = page
        out.insert(contentsOf: Data(tag.utf8), at: end.lowerBound)
        return out
    }

    /// The app build, so a new version replaces the worker's cache.
    static var serviceWorkerBuild: String {
        let info = Bundle.main.infoDictionary
        let v = (info?["CFBundleShortVersionString"] as? String) ?? "dev"
        let b = (info?["CFBundleVersion"] as? String) ?? "0"
        let raw = "\(v)-\(b)"
        return String(raw.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" }.map(Character.init))
    }

    /// Kill switch: `defaults write com.frindle.clamshell webClientOfflineShell -bool NO`.
    static var offlineShellEnabled: Bool {
        UserDefaults.standard.object(forKey: "webClientOfflineShell") as? Bool ?? true
    }

    /// sw.js with its two placeholders filled in. A disabled shell makes the worker remove itself.
    static func serviceWorkerScript(_ js: Data, build: String, enabled: Bool) -> Data {
        var text = String(decoding: js, as: UTF8.self)
        text = text.replacingOccurrences(of: "'__BUILD__'", with: "'\(build)'")
        text = text.replacingOccurrences(of: "'__KILL__'", with: "'\(enabled ? "false" : "true")'")
        return Data(text.utf8)
    }

    static let unlockTerminalMetaName = "clamshell-unlock-terminal-url"

    /// The https address of the browser SSH terminal that unlocks the disk after a power cut
    /// (`defaults write com.frindle.clamshell unlockTerminalURL <https-url>`). Empty when unset or
    /// not https. The page shows an "Unlock disk" link to it while the Mac does not answer.
    static var unlockTerminalURL: String {
        let v = (UserDefaults.standard.string(forKey: "unlockTerminalURL") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return v.lowercased().hasPrefix("https://") ? v : ""
    }

    /// The page with the unlock link's address in a `<meta>` tag; unchanged when `url` is empty.
    static func withUnlockTerminalURL(_ page: Data, url: String) -> Data {
        guard !url.isEmpty, let end = page.range(of: Data("</head>".utf8)) else { return page }
        let tag = "<meta name=\"\(unlockTerminalMetaName)\" content=\"\(encodedToken(url))\">"
        var out = page
        out.insert(contentsOf: Data(tag.utf8), at: end.lowerBound)
        return out
    }

    /// The address to advertise in URLs: the first bound IP if set, else the
    /// first LAN IPv4.
    var displayHost: String {
        bindHosts.first ?? Self.lanIPv4s().first?.ip ?? "localhost"
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

    private var httpListeners: [NWListener] = []
    private var streamBridgeListeners: [NWListener] = []
    private let queue = DispatchQueue(label: "clamshell.web")
    private var streamBridgeSessions = 0

    /// Browser-facing WS bridge ports for the /client web streaming client —
    /// one per display, each proxying to the matching local StreamServer WS
    /// port below. Network.framework's server-side WS listener doesn't expose
    /// the handshake's request path for routing (the handshake is consumed
    /// internally), so path-based routing like "/stream/a" on a single port
    /// isn't available — a dedicated port per display sidesteps that and
    /// mirrors StreamServer's own "base port + display index" convention.
    private static let streamBridgePorts: [NWEndpoint.Port] = [5906, 5907, 5908]
    private static let streamTargetPorts: [UInt16] = [streamDefaultPort, streamDefaultPort + 1, streamDefaultPort + 2]

    private(set) var isRunning = false

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        LANTLS.reload() // inert unless a cert and key are configured (README "LAN TLS")
        startTLSWatch()
        do {
            try startHTTP()
            try startStreamBridges()
            isRunning = true
            let bound = bindHosts.isEmpty ? "all interfaces" : bindHosts.joined(separator: ", ")
            clog("web access ON: http\(LANTLS.identity != nil ? "s" : "")://\(displayHost):\(httpPort) (bound to \(bound))")
        } catch {
            clog("web access failed to start: \(error)")
            stop()
        }
    }

    /// Every 6 hours, reload the TLS identity if the certificate or key file
    /// changed (a renewed wildcard) or the TLS config appeared or went away,
    /// by restarting the listeners. Main queue.
    private var tlsWatch: Timer?
    private func startTLSWatch() {
        tlsWatch?.invalidate()
        tlsWatch = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            guard let self, self.isRunning, LANTLS.needsReload() else { return }
            clog("LAN TLS: certificate or configuration changed — restarting the web listeners")
            self.stop()
            self.start()
        }
    }

    func stop() {
        tlsWatch?.invalidate()
        tlsWatch = nil
        rebindWork?.cancel()
        rebindWork = nil
        rebindAttempts = 0
        closeListeners()
        isRunning = false
        clog("web access OFF")
    }

    private func closeListeners() {
        readyListeners = 0
        for l in httpListeners { l.cancel() }
        httpListeners = []
        for l in streamBridgeListeners { l.cancel() }
        streamBridgeListeners = []
    }

    // A port that is still held by another process (the login-window agent
    // on its way out, or the previous instance during an update relaunch)
    // fails the bind *after* start() returns, on the listener's state
    // handler. Without this the server sat there "ON" with a dead port.
    private var rebindWork: DispatchWorkItem?
    private var rebindAttempts = 0
    private static let maxRebindAttempts = 8

    private var readyListeners = 0 // main queue

    private func watch(_ listener: NWListener) {
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                // Once every listener is bound, the earlier failures are history:
                // reset the counter so a later, unrelated failure gets a full
                // set of retries. Counting all of them stops a listener that
                // keeps failing from being reset by its healthy siblings.
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.readyListeners += 1
                    let total = self.httpListeners.count + self.streamBridgeListeners.count
                    if self.readyListeners >= total, self.rebindWork == nil { self.rebindAttempts = 0 }
                }
            case .failed(let error):
                clog("web access: a listener failed (\(error))")
                DispatchQueue.main.async { self?.scheduleRebind() }
            default:
                break
            }
        }
    }

    /// Main queue. Closes every listener, waits for the ports to be released,
    /// then starts again. Gives up after `maxRebindAttempts` in a row.
    private func scheduleRebind() {
        guard isRunning, rebindWork == nil else { return }
        guard rebindAttempts < Self.maxRebindAttempts else {
            clog("web access: still can't bind after \(rebindAttempts) tries — giving up (toggle Web Access to retry)")
            return
        }
        rebindAttempts += 1
        let attempt = rebindAttempts
        let attemptsSoFar = rebindAttempts
        closeListeners()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.rebindWork = nil
            guard self.isRunning else { return }
            clog("web access: rebinding (try \(attempt) of \(Self.maxRebindAttempts))")
            self.isRunning = false
            self.start()
            // start() calls stop() if it throws, which zeroes the counter;
            // keep counting so a permanently busy port can't loop forever.
            self.rebindAttempts = attemptsSoFar
        }
        rebindWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    // MARK: - HTTP static server

    /// One listener when binding all interfaces, else one per selected IP.
    /// `makeParams` is a factory because NWParameters is a reference type —
    /// each listener needs its own requiredLocalEndpoint.
    private func makeListeners(port: NWEndpoint.Port,
                               makeParams: () -> NWParameters) throws -> [NWListener] {
        guard !bindHosts.isEmpty else { return [try NWListener(using: makeParams(), on: port)] }
        return try bindHosts.map { host in
            let params = makeParams()
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)
            return try NWListener(using: params)
        }
    }

    private func startHTTP() throws {
        let listeners = try makeListeners(port: httpPort) { LANTLS.parameters() }
        for listener in listeners {
            listener.newConnectionHandler = { [weak self] conn in
                conn.start(queue: self?.queue ?? .global())
                self?.receiveRequest(conn, buffer: Data())
            }
            watch(listener)
            listener.start(queue: queue)
        }
        httpListeners = listeners
    }

    private func receiveRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, error in
            guard let self, error == nil, let data else { conn.cancel(); return }
            var buf = buffer
            buf.append(data)
            if let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(data: buf[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
                // POST bodies (clipboard): read Content-Length bytes past the
                // headers. GETs have no Content-Length, so their flow is
                // unchanged (body arrives empty).
                let contentLength = Self.contentLength(in: head)
                guard contentLength <= 1_048_576 else {
                    self.send(conn, status: "413 Payload Too Large", contentType: "text/plain",
                              body: Data("too large".utf8))
                    return
                }
                let bodySoFar = buf[headerEnd.upperBound...]
                if bodySoFar.count < contentLength {
                    self.receiveRequest(conn, buffer: buf) // keep reading until the body is complete
                    return
                }
                self.respond(conn, requestHead: head, body: Data(bodySoFar.prefix(contentLength)))
            } else if buf.count < 65536 {
                self.receiveRequest(conn, buffer: buf)
            } else {
                conn.cancel()
            }
        }
    }

    private static func contentLength(in head: String) -> Int {
        for line in head.split(separator: "\r\n").dropFirst() {
            let lower = line.lowercased()
            guard lower.hasPrefix("content-length:") else { continue }
            return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return 0
    }

    /// The header lines of a request head as (name, value) pairs.
    static func headerFields(in head: String) -> [(name: String, value: String)] {
        head.split(separator: "\r\n").dropFirst().compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                    line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
    }

    private func respond(_ conn: NWConnection, requestHead: String, body: Data) {
        let requestLine = requestHead.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            send(conn, status: "405 Method Not Allowed", contentType: "text/plain", body: Data("nope".utf8))
            return
        }
        let path = String(parts[1].split(separator: "?").first ?? "/")

        // Clipboard bridge. Every request needs the token, as the `token`
        // query item or a bearer credential, and it has to be the whole
        // token: this reads the Mac's clipboard and replaces it, and without
        // the token any website open in a browser that can reach this server
        // could post to it.
        if path == "/clipboard" {
            guard Self.carriesToken(clipboardToken, target: String(parts[1]), head: requestHead) else {
                send(conn, status: "401 Unauthorized", contentType: "text/plain", body: Data("token required".utf8))
                return
            }
            handleClipboard(conn, method: String(parts[0]), body: body)
            return
        }

        // Phone approval: the one-time link from the push notification. GET shows
        // a page and decides nothing; the decision is a POST (PROTOCOL.md).
        if path.hasPrefix(PhoneApprovalService.pathPrefix) {
            let headers = Self.headerFields(in: requestHead)
            var peer = ""
            if case .hostPort(let host, _)? = conn.currentPath?.remoteEndpoint {
                peer = "\(host)".split(separator: "%").first.map(String.init) ?? ""
            }
            let client = ClientAddress.resolve(peer: peer, headers: headers, trusted: HostAuth.storedTrustedProxies())
            let publicOrigin = PhoneApprovalConfig.origin(
                UserDefaults.standard.string(forKey: PhoneApprovalConfig.baseURLKey) ?? "")
            let reply = PhoneApproval.shared.handle(method: String(parts[0]), path: path, headers: headers,
                                                    body: body, client: client, allowedOrigin: publicOrigin)
            send(conn, status: reply.status, contentType: "text/html; charset=utf-8", body: reply.body,
                 extraHeaders: reply.headers)
            return
        }

        guard parts[0] == "GET" else {
            send(conn, status: "405 Method Not Allowed", contentType: "text/plain", body: Data("nope".utf8))
            return
        }

        // Web streaming client: serves Resources/webclient at /client.
        if path == "/client" || path == "/client/" {
            guard let root = Self.webclientRoot,
                  let html = try? Data(contentsOf: root.appendingPathComponent("index.html")) else {
                send(conn, status: "500 Internal Server Error", contentType: "text/plain",
                     body: Data("web client resources missing from bundle".utf8))
                return
            }
            send(conn, status: "200 OK", contentType: "text/html; charset=utf-8",
                 body: Self.withUnlockTerminalURL(Self.withClipboardToken(html, token: clipboardToken), url: Self.unlockTerminalURL))
            return
        }
        if path == "/client/sw.js" {
            // The offline-shell worker: build and kill switch filled in here, and allowed to
            // control /client (a worker under /client/ may not claim the page at /client otherwise).
            guard let root = Self.webclientRoot,
                  let js = try? Data(contentsOf: root.appendingPathComponent("sw.js")) else {
                send(conn, status: "404 Not Found", contentType: "text/plain", body: Data("not found".utf8))
                return
            }
            send(conn, status: "200 OK", contentType: "application/javascript",
                 body: Self.serviceWorkerScript(js, build: Self.serviceWorkerBuild, enabled: Self.offlineShellEnabled),
                 extraHeaders: ["Service-Worker-Allowed: /client"])
            return
        }
        if path.hasPrefix("/client/") {
            guard let root = Self.webclientRoot,
                  let fileURL = Self.resolveSafely(root: root, relativePath: String(path.dropFirst("/client/".count))),
                  let fileBody = try? Data(contentsOf: fileURL) else {
                send(conn, status: "404 Not Found", contentType: "text/plain", body: Data("not found".utf8))
                return
            }
            send(conn, status: "200 OK", contentType: Self.contentType(for: fileURL.pathExtension), body: fileBody)
            return
        }

        if path == "/" {
            // Land directly in Clamshell's own client.
            let head = "HTTP/1.1 302 Found\r\nLocation: /client\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in conn.cancel() })
            return
        }

        send(conn, status: "404 Not Found", contentType: "text/plain", body: Data("not found".utf8))
    }

    // MARK: - Clipboard bridge

    /// GET returns the Mac clipboard as {"text","changeCount"}; POST sets it
    /// from {"text"}. Reached only with the token (see `respond`), which
    /// anyone who can load a page from this server has.
    private func handleClipboard(_ conn: NWConnection, method: String, body: Data) {
        switch method {
        case "GET":
            var text = ""
            var count = 0
            DispatchQueue.main.sync {
                text = NSPasteboard.general.string(forType: .string) ?? ""
                count = NSPasteboard.general.changeCount
            }
            let json = (try? JSONSerialization.data(withJSONObject: ["text": text, "changeCount": count]))
                ?? Data("{}".utf8)
            send(conn, status: "200 OK", contentType: "application/json", body: json)
        case "POST":
            guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let text = obj["text"] as? String else {
                send(conn, status: "400 Bad Request", contentType: "text/plain", body: Data("expected {\"text\": ...}".utf8))
                return
            }
            DispatchQueue.main.sync {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            send(conn, status: "200 OK", contentType: "application/json", body: Data("{\"ok\":true}".utf8))
        default:
            send(conn, status: "405 Method Not Allowed", contentType: "text/plain", body: Data("nope".utf8))
        }
    }

    private func send(_ conn: NWConnection, status: String, contentType: String, body: Data, extraHeaders: [String] = []) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        for h in extraHeaders { head += "\(h)\r\n" }
        head += "Content-Length: \(body.count)\r\n"
        if !extraHeaders.contains(where: { $0.lowercased().hasPrefix("cache-control:") }) { head += "Cache-Control: no-cache\r\n" }
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        conn.send(content: payload, completion: .contentProcessed { _ in conn.cancel() })
    }

    /// The web streaming client's static assets, bundled as a SwiftPM
    /// resource (package.sh copies the resource bundle into Contents/Resources).
    static var webclientRoot: URL? {
        Bundle.module.url(forResource: "webclient", withExtension: nil)
    }

    /// Resolves `relativePath` against `root`, refusing traversal by checking
    /// the fully resolved path stays inside the root (catches percent-encoded
    /// ".." and symlinks, unlike string-stripping). Used by the web client's
    /// static file server.
    static func resolveSafely(root: URL, relativePath: String) -> URL? {
        let decoded = relativePath.removingPercentEncoding ?? relativePath
        let fileURL = root.appendingPathComponent(decoded).standardizedFileURL
        let rootPath = root.resolvingSymlinksInPath().path
        guard fileURL.resolvingSymlinksInPath().path.hasPrefix(rootPath + "/") else { return nil }
        return fileURL
    }

    static func contentType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "application/javascript"
        case "css": return "text/css"
        case "json": return "application/json"
        case "webmanifest": return "application/manifest+json"
        case "png": return "image/png"
        case "svg": return "image/svg+xml"
        case "ico": return "image/x-icon"
        case "woff", "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }

    // MARK: - WebSocket → StreamServer WS bridge (web streaming client)

    /// One listener per display (see `streamBridgePorts`'s doc comment for
    /// why a single path-routed port isn't viable), each proxying binary WS
    /// messages to the matching local StreamServer WS listener.
    private func startStreamBridges() throws {
        var listeners: [NWListener] = []
        for (i, port) in Self.streamBridgePorts.enumerated() {
            let targetPort = Self.streamTargetPorts[i]
            // The browser's upgrade request says who is behind a tunnel (see
            // ClientAddress); the bridge reads it when the browser leg is ready.
            let upgradeHeaders = UpgradeHeaders()
            let ls = try makeListeners(port: port) {
                let wsParams = LANTLS.parameters()
                let wsOptions = NWProtocolWebSocket.Options()
                wsOptions.autoReplyPing = true
                wsOptions.setClientRequestHandler(queue) { _, headers in
                    upgradeHeaders.record(headers)
                    return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
                }
                wsParams.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
                return wsParams
            }
            for listener in ls {
                listener.newConnectionHandler = { [weak self] browserWS in
                    self?.streamBridge(browserWS, toPort: targetPort, upgradeHeaders: upgradeHeaders)
                }
                watch(listener)
                listener.start(queue: queue)
            }
            listeners += ls
        }
        streamBridgeListeners = listeners
    }

    /// Browser WS (accepted on a `streamBridgePorts` listener) <-> a WS
    /// *client* connection this process dials to StreamServer's own WS
    /// listener on 127.0.0.1. Both ends speak binary WS messages since StreamServer natively
    /// speaks NWProtocolWebSocket rather than raw TCP — Network.framework
    /// performs the client-side WS handshake automatically when a connection
    /// is created with WS options in its parameters, same as any WS client.
    ///
    /// FIXED 2026-08-08 (was: KNOWN BUG dated the same day). The previous
    /// `inner` leg dialed StreamServer with a raw `NWConnection` in WS-client
    /// role, which got stuck at `.preparing` and aborted with
    /// `POSIXErrorCode(53)` on every attempt -- a same-process dual-WS-role
    /// (one `NWProtocolWebSocket` stack as listener-accepted server, another
    /// as outbound client) issue that never got root-caused. `StreamSelfTest`
    /// already proves a working client transport against the exact same kind
    /// of `NWListener` WS server: `URLSession.shared.webSocketTask`, "the
    /// same one the iPad uses" per its own comment. Swapping `inner` to that
    /// avoids the broken combination entirely instead of debugging
    /// Network.framework's dual-role loopback behavior further.
    private func streamBridge(_ browserWS: NWConnection, toPort targetPort: UInt16, upgradeHeaders: UpgradeHeaders) {
        // The inner leg is dialled once the browser leg is ready, so the
        // address found in the browser's upgrade request can go with it.
        var innerTask: URLSessionWebSocketTask?

        // Upgrade headers go to a connection only when they surely belong to
        // it (see `UpgradeHeaders`): this one is counted from here until it is
        // ready, or until it closes without getting there.
        upgradeHeaders.connectionAccepted()
        var readyReached = false
        var closed = false
        let close: () -> Void = { [weak self] in
            guard !closed else { return }
            closed = true
            if !readyReached {
                upgradeHeaders.connectionClosedBeforeReady()
                readyReached = true
            }
            browserWS.cancel()
            innerTask?.cancel(with: .goingAway, reason: nil)
            self?.streamBridgeSessions = max(0, (self?.streamBridgeSessions ?? 1) - 1)
            clog("browser stream session closed")
        }

        // Not counted separately: the stream
        // server collapses to the size the client reports in HELLO. Counting it
        // also collapsed to the default preset first, and the rebuild a moment
        // later raced WindowServer, so mirroring failed and the virtual display
        // stayed an extra screen beside the real one. The stream server also
        // restores when its client has been gone for a while.
        streamBridgeSessions += 1
        clog("browser stream session opened -> 127.0.0.1:\(targetPort)")

        func pumpBrowserToInner(_ inner: URLSessionWebSocketTask) {
            browserWS.receiveMessage { data, context, isComplete, error in
                if let error { clog("stream bridge: browserWS.receiveMessage error: \(error)") }
                guard error == nil else { close(); return }
                if let data, !data.isEmpty {
                    inner.send(.data(data)) { sendErr in
                        if let sendErr { clog("stream bridge: inner.send error: \(sendErr)") }
                        if sendErr != nil { close() } else { pumpBrowserToInner(inner) }
                    }
                } else {
                    pumpBrowserToInner(inner)
                }
            }
        }
        func pumpInnerToBrowser(_ inner: URLSessionWebSocketTask) {
            inner.receive { result in
                switch result {
                case .failure(let error):
                    clog("stream bridge: inner.receive error: \(error)")
                    close()
                case .success(let message):
                    guard case .data(let data) = message, !data.isEmpty else { pumpInnerToBrowser(inner); return }
                    let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
                    let ctx = NWConnection.ContentContext(identifier: "toBrowser", metadata: [meta])
                    browserWS.send(content: data, contentContext: ctx, completion: .contentProcessed { sendErr in
                        if let sendErr { clog("stream bridge: browserWS.send error: \(sendErr)") }
                        if sendErr != nil { close() } else { pumpInnerToBrowser(inner) }
                    })
                }
            }
        }

        browserWS.stateUpdateHandler = { state in
            clog("stream bridge: browserWS state -> \(state)")
            if case .failed(let err) = state { clog("stream bridge: browserWS failed: \(err)"); close() }
            if case .cancelled = state { close() }
            if case .ready = state, innerTask == nil, !closed {
                // Same rule as the stream server's: headers count only from a
                // trusted proxy. The result goes on to the stream server in
                // X-Forwarded-For, where this relay (127.0.0.1) is trusted.
                readyReached = true
                let peer = StreamGate.remoteAddress(of: browserWS)
                let client = upgradeHeaders.bindAtReady().map {
                    ClientAddress.resolve(peer: peer, headers: $0, trusted: HostAuth.storedTrustedProxies())
                } ?? peer
                var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(targetPort)")!)
                if !client.isEmpty { request.setValue(client, forHTTPHeaderField: "X-Forwarded-For") }
                let inner = URLSession.shared.webSocketTask(with: request)
                inner.maximumMessageSize = 64 << 20
                innerTask = inner
                inner.resume()
                pumpBrowserToInner(inner)
                pumpInnerToBrowser(inner)
            }
        }

        browserWS.start(queue: queue)
    }

    // MARK: - Host lock state

    /// Whether the login session's screen is locked right now.
    static func hostLocked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Int == 1
    }
}
