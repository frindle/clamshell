import Foundation
import Network

// The control connection between two paired machines (PROTOCOL.md "Peer
// link"): one WebSocket on port 5910, advertised and found over Bonjour,
// authenticated with the challenge/response in PeerIdentity.swift. Both
// sides run a listener and a browser; whichever connects first wins, so the
// roles "server" and "client" below only describe who accepted the TCP
// connection, not who is controlling whom.
//
// Everything after authentication is just framed messages handed to
// `onMessage` (input, clipboard, files, handoff) — this class owns transport
// and identity, nothing feature-specific. All mutable state lives on `queue`;
// callbacks are delivered on `queue` too (callers hop to main as needed).

enum PeerLinkState: Equatable {
    case idle
    case connecting(String)
    case handshaking(String)
    case linked(PeerInfo, screenWidth: UInt32, screenHeight: UInt32)
    case failed(String)

    var isLinked: Bool { if case .linked = self { return true }; return false }
}

struct DiscoveredPeer: Equatable {
    let name: String
    let id: String?         // from the TXT record, when the peer advertised one
    let endpoint: NWEndpoint
    static func == (a: DiscoveredPeer, b: DiscoveredPeer) -> Bool { a.name == b.name && a.id == b.id }
}

final class PeerLink {
    let identity: PeerIdentity
    let trust: PeerTrustStore
    let localName: String
    private let port: UInt16
    /// Size of the primary screen in this host's input units (points on the
    /// Mac, pixels on Windows) — what a controlling peer scales deltas by.
    private let screenSize: () -> (UInt32, UInt32)

    let queue = DispatchQueue(label: "clamshell.peer")
    private var listener: NWListener?
    private var browser: NWBrowser?

    private var connection: NWConnection?
    private var parser: StreamMessageParser?
    private var handshake: Handshake?
    private var handshakeTimeout: DispatchWorkItem?
    private(set) var state: PeerLinkState = .idle
    private(set) var discovered: [DiscoveredPeer] = []
    /// Current pairing PIN — regenerated after every successful pairing so a
    /// PIN read off the screen is single-use.
    private(set) var pairingPIN = PeerIdentity.randomPIN()

    var onStateChange: ((PeerLinkState) -> Void)?
    var onDiscoveredChange: (([DiscoveredPeer]) -> Void)?
    /// Post-authentication messages (never the 0x40–0x42 handshake types).
    var onMessage: ((StreamMessageType, Data) -> Void)?

    private struct Handshake {
        enum Role { case server, client }
        let role: Role
        let ourNonce: Data          // the nonce we issued (server) or sent in HELLO (client)
        let pin: String?            // client: PIN typed by the user; server: PIN in force at accept
        let label: String
    }

    init(identity: PeerIdentity, trust: PeerTrustStore, localName: String,
         port: UInt16 = peerLinkDefaultPort, screenSize: @escaping () -> (UInt32, UInt32)) {
        self.identity = identity
        self.trust = trust
        self.localName = localName
        self.port = port
        self.screenSize = screenSize
    }

    // MARK: - Listening / advertising

    /// `advertise: false` skips Bonjour (loopback selftests; two listeners in
    /// one process would otherwise fight over the same service name).
    func startListening(advertise: Bool = true) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        if advertise {
            var txt = NWTXTRecord()
            txt["id"] = identity.id
            txt["name"] = localName
            txt["v"] = String(peerProtocolVersion)
            listener.service = NWListener.Service(name: localName, type: peerServiceType, txtRecord: txt)
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.queue.async { self?.accept(conn) }
        }
        listener.stateUpdateHandler = { state in clog("PEER: listener \(state)") }
        listener.start(queue: queue)
        self.listener = listener
        clog("PEER: listening on \(port) as \"\(localName)\" (\(identity.id.prefix(12))…)")
    }

    func startBrowsing() {
        let browser = NWBrowser(for: .bonjour(type: peerServiceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            var found: [DiscoveredPeer] = []
            for r in results {
                guard case .service(let name, _, _, _) = r.endpoint else { continue }
                var id: String?
                if case .bonjour(let txt) = r.metadata { id = txt["id"] }
                if id == self.identity.id { continue } // ourselves
                found.append(DiscoveredPeer(name: name, id: id, endpoint: r.endpoint))
            }
            self.discovered = found.sorted { $0.name < $1.name }
            self.onDiscoveredChange?(self.discovered)
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let e) = state { clog("PEER: browser failed: \(e)") }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stop(completion: @escaping () -> Void = {}) {
        queue.async { [self] in
            browser?.cancel(); browser = nil
            dropConnection(reason: nil)
            if let l = listener {
                l.stateUpdateHandler = { state in if case .cancelled = state { completion() } }
                l.cancel()
            } else {
                completion()
            }
            listener = nil
        }
    }

    // MARK: - Connecting out

    /// Bonjour results are `.service` endpoints, and a WebSocket NWConnection
    /// needs a URL endpoint to build its HTTP upgrade (a bare host:port
    /// connect dies with ECONNABORTED — seen live in peer-link-selftest). So
    /// first open a plain TCP connection to the service to learn the
    /// resolved address, then dial the WebSocket by URL.
    func connect(to peer: DiscoveredPeer, pin: String?) {
        queue.async { [self] in
            setState(.connecting(peer.name))
            let probe = NWConnection(to: peer.endpoint, using: .tcp)
            probe.stateUpdateHandler = { [weak self] st in
                guard let self else { return }
                switch st {
                case .ready:
                    defer { probe.cancel() }
                    guard case .hostPort(let host, let port)? = probe.currentPath?.remoteEndpoint else {
                        self.queue.async { self.setState(.failed("could not resolve \(peer.name)")) }
                        return
                    }
                    var h = "\(host)"
                    if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) } // strip IPv6 scope
                    self.queue.async { self.connect(host: h, port: port.rawValue, pin: pin, label: peer.name) }
                case .failed(let e):
                    self.queue.async { self.setState(.failed("resolve \(peer.name): \(e)")) }
                case .waiting(let e):
                    clog("PEER: resolving \(peer.name): \(e)")
                default: break
                }
            }
            probe.start(queue: queue)
        }
    }

    func connect(host: String, port: UInt16, pin: String?, label: String? = nil) {
        let bracketed = host.contains(":") ? "[\(host)]" : host
        guard let url = URL(string: "ws://\(bracketed):\(port)/") else { return }
        connect(endpoint: .url(url), label: label ?? "\(host):\(port)", pin: pin)
    }

    private func connect(endpoint: NWEndpoint, label: String, pin: String?) {
        queue.async { [self] in
            dropConnection(reason: nil)
            let params = NWParameters.tcp
            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = true
            params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            let conn = NWConnection(to: endpoint, using: params)
            handshake = Handshake(role: .client, ourNonce: PeerIdentity.randomNonce(), pin: pin, label: label)
            setState(.connecting(label))
            attach(conn)
            armHandshakeTimeout()
        }
    }

    func disconnect() {
        queue.async { [self] in dropConnection(reason: "disconnected") ; setState(.idle) }
    }

    // MARK: - Connection plumbing (on `queue`)

    private func accept(_ conn: NWConnection) {
        if let existing = connection, case .linked = state {
            // A trusted peer reconnecting replaces its own old session; a
            // second machine gets told we're busy after it identifies.
            clog("PEER: incoming connection while linked — replacing")
            existing.cancel()
        } else if connection != nil {
            dropConnection(reason: nil)
        }
        handshake = Handshake(role: .server, ourNonce: PeerIdentity.randomNonce(), pin: pairingPIN, label: "incoming")
        setState(.handshaking("incoming"))
        attach(conn)
        armHandshakeTimeout()
    }

    private func attach(_ conn: NWConnection) {
        connection = conn
        let parser = StreamMessageParser()
        parser.onMessage = { [weak self] type, payload in self?.handle(type: type, payload: payload, from: conn) }
        self.parser = parser
        conn.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            self.queue.async {
                guard self.connection === conn else { return }
                switch st {
                case .ready:
                    self.receiveLoop(conn)
                    if let h = self.handshake, h.role == .server {
                        self.rawSend(StreamMessage.peerChallenge(nonce: h.ourNonce))
                    } else if let h = self.handshake {
                        self.setState(.handshaking(h.label))
                    }
                case .failed(let e):
                    self.dropConnection(reason: "connection failed: \(e)")
                case .cancelled:
                    self.dropConnection(reason: "connection closed")
                case .waiting(let e):
                    clog("PEER: waiting: \(e)")
                default: clog("PEER: connection \(st)")
                }
            }
        }
        conn.start(queue: queue)
        // receiveMessage is only issued once .ready: on a WebSocket
        // NWConnection a receive queued while still preparing aborts the
        // connection with ECONNABORTED (seen live in peer-link-selftest).
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, complete, error in
            guard let self, self.connection === conn else { return }
            if let data, !data.isEmpty { self.parser?.feed(data) }
            if self.parser?.corrupt == true { self.dropConnection(reason: "corrupt stream"); return }
            if error != nil || (complete && data == nil) {
                self.dropConnection(reason: "peer disconnected (\(error.map(String.init(describing:)) ?? "eof"), complete=\(complete), bytes=\(data?.count ?? -1))"); return
            }
            self.receiveLoop(conn)
        }
    }

    private func armHandshakeTimeout() {
        handshakeTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.handshake != nil else { return }
            self.dropConnection(reason: "handshake timed out")
        }
        handshakeTimeout = work
        queue.asyncAfter(deadline: .now() + 15, execute: work)
    }

    private func dropConnection(reason: String?) {
        handshakeTimeout?.cancel(); handshakeTimeout = nil
        handshake = nil
        parser = nil
        if let c = connection {
            c.stateUpdateHandler = nil
            c.cancel()
            connection = nil
        }
        if let reason {
            clog("PEER: \(reason)")
            if case .idle = state {} else { setState(.failed(reason)) }
        }
    }

    private func setState(_ s: PeerLinkState) {
        state = s
        onStateChange?(s)
    }

    // MARK: - Handshake (on `queue`)

    private func handle(type: StreamMessageType, payload: Data, from conn: NWConnection) {
        guard connection === conn else { return }
        switch type {
        case .peerChallenge:
            guard let h = handshake, h.role == .client, payload.count == PeerLimits.nonceSize else {
                dropConnection(reason: "unexpected CHALLENGE"); return
            }
            let (w, hgt) = screenSize()
            let proof = h.pin.map { PeerIdentity.pinProof(pin: $0, nonce: payload, publicKey: identity.publicKey) }
            rawSend(StreamMessage.peerHello(publicKey: identity.publicKey, clientNonce: h.ourNonce,
                                            signature: identity.sign(nonce: payload), pinProof: proof,
                                            name: localName, screenWidth: w, screenHeight: hgt))
        case .peerHello:
            guard let h = handshake, h.role == .server else { dropConnection(reason: "unexpected HELLO"); return }
            guard let hello = PeerParse.hello(payload) else {
                refuse(.version, reason: "malformed HELLO"); return
            }
            guard PeerIdentity.verify(signature: hello.signature, nonce: h.ourNonce, publicKey: hello.publicKey) else {
                refuse(.badSignature, reason: "HELLO bad signature"); return
            }
            var usedPin: String?
            if !trust.isTrusted(publicKey: hello.publicKey) {
                guard let proof = hello.pinProof else {
                    refuse(.untrusted, reason: "untrusted peer \(hello.name) (no PIN)"); return
                }
                guard let pin = h.pin, PeerIdentity.verifyPinProof(proof, pin: pin, nonce: h.ourNonce, publicKey: hello.publicKey) else {
                    refuse(.badPin, reason: "wrong PIN from \(hello.name)"); return
                }
                usedPin = pin
                clog("PEER: paired with \(hello.name) via PIN")
            }
            let (w, hgt) = screenSize()
            let proof = usedPin.map { PeerIdentity.pinProof(pin: $0, nonce: hello.clientNonce, publicKey: identity.publicKey) }
            rawSend(StreamMessage.peerHelloAck(status: .ok, publicKey: identity.publicKey,
                                               signature: identity.sign(nonce: hello.clientNonce), pinProof: proof,
                                               name: localName, screenWidth: w, screenHeight: hgt))
            finishHandshake(publicKey: hello.publicKey, name: hello.name, paired: usedPin != nil,
                            screen: (hello.screenWidth, hello.screenHeight))
        case .peerHelloAck:
            guard let h = handshake, h.role == .client else { dropConnection(reason: "unexpected HELLO_ACK"); return }
            guard let ack = PeerParse.helloAck(payload) else { dropConnection(reason: "malformed HELLO_ACK"); return }
            guard ack.status == .ok else { dropConnection(reason: "peer refused: \(Self.describe(ack.status))"); return }
            guard PeerIdentity.verify(signature: ack.signature, nonce: h.ourNonce, publicKey: ack.publicKey) else {
                dropConnection(reason: "HELLO_ACK bad signature"); return
            }
            var paired = false
            if !trust.isTrusted(publicKey: ack.publicKey) {
                // We typed a PIN for *them*; they must prove they know it too,
                // or we'd be trusting whoever answered on that port.
                guard let pin = h.pin, let proof = ack.pinProof,
                      PeerIdentity.verifyPinProof(proof, pin: pin, nonce: h.ourNonce, publicKey: ack.publicKey) else {
                    dropConnection(reason: "peer \(ack.name) did not prove the PIN"); return
                }
                paired = true
            }
            finishHandshake(publicKey: ack.publicKey, name: ack.name, paired: paired,
                            screen: (ack.screenWidth, ack.screenHeight))
        default:
            guard handshake == nil, state.isLinked else { dropConnection(reason: "message before authentication"); return }
            onMessage?(type, payload)
        }
    }

    /// Refusal ACKs must reach the wire before the socket closes, or the
    /// client only ever sees EOF and can't tell "wrong PIN" from a dead peer.
    private func refuse(_ status: PeerHelloStatus, reason: String) {
        let conn = connection
        rawSend(StreamMessage.peerHelloAck(status: status)) { [weak self] in
            guard let self, self.connection === conn else { return }
            self.dropConnection(reason: reason)
        }
    }

    private func finishHandshake(publicKey: Data, name: String, paired: Bool, screen: (UInt32, UInt32)) {
        handshakeTimeout?.cancel(); handshakeTimeout = nil
        handshake = nil
        if paired {
            pairingPIN = PeerIdentity.randomPIN()
        }
        trust.trust(publicKey: publicKey, name: name)
        let info = PeerInfo(id: PeerIdentity.peerId(for: publicKey), name: name, publicKey: publicKey, pairedAt: Date())
        clog("PEER: linked with \(name) (\(info.id.prefix(12))…) screen \(screen.0)x\(screen.1)")
        setState(.linked(info, screenWidth: screen.0, screenHeight: screen.1))
    }

    private static func describe(_ s: PeerHelloStatus) -> String {
        switch s {
        case .ok: return "ok"
        case .untrusted: return "not paired — enter that machine's pairing PIN"
        case .badPin: return "wrong PIN"
        case .badSignature: return "signature rejected"
        case .busy: return "peer is linked to another machine"
        case .version: return "protocol version mismatch"
        }
    }

    // MARK: - Sending

    /// Post-auth send. `completion` fires when the bytes have been handed to
    /// the transport — file transfer paces itself on it.
    func send(_ data: Data, completion: (() -> Void)? = nil) {
        queue.async { [self] in
            guard state.isLinked else { completion?(); return }
            rawSend(data, completion: completion)
        }
    }

    private func rawSend(_ data: Data, completion: (() -> Void)? = nil) {
        guard let conn = connection else { completion?(); return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "msg", metadata: [metadata])
        conn.send(content: data, contentContext: context, isComplete: true,
                  completion: .contentProcessed { [weak self] error in
            self?.queue.async {
                completion?()
                if error != nil, self?.connection === conn { self?.dropConnection(reason: "send failed") }
            }
        })
    }
}
