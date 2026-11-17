import CryptoKit
import Foundation
import Network

// The door in front of a stream listener (PROTOCOL.md, "Device authentication
// and encrypted session"). Every connection the listener accepts becomes a
// StreamLink and stays with the StreamGate until it closes. The server behind
// the gate is handed a link only once the device has been let in, and from
// then on sees nothing but that link's session messages. Until then a
// connection can start nothing: no collapse, no capture, no input, no
// clipboard.
//
// Everything here runs on the listener's serial queue.

/// One client connection, from the listener handing it over until it closes.
final class StreamLink {
    enum Phase: Equatable {
        /// Sent the challenge. Only an AUTH_RESPONSE is read.
        case awaitingResponse
        /// Proved its key; the user has not decided yet. Nothing is read.
        case pending
        /// Let in, with an encrypted session.
        case accepted
        /// Let in without a handshake, on a host with approval off.
        case open
        case closed
    }

    let conn: NWConnection
    fileprivate(set) var phase: Phase = .awaitingResponse
    /// The device behind a waiting or accepted link; nil for a clear one.
    fileprivate(set) var device: VerifiedDevice?
    /// Where the connection came from. A label for the logs and the approval
    /// prompt, never a reason to trust.
    fileprivate(set) var address = ""

    fileprivate var parser = StreamMessageParser(maxPayload: StreamGate.handshakeMaxPayload)
    fileprivate var handshake: HostHandshake?
    fileprivate var sealer: SecureSealer?
    fileprivate var opener: SecureOpener?
    fileprivate var unanswered: HostAuth.Unanswered?
    fileprivate var deadline: DispatchWorkItem?
    fileprivate var pendingTimer: DispatchSourceTimer?
    fileprivate var pendingResult: Data?
    fileprivate var waitingToken: HostAuth.Waiting?
    fileprivate var countedAsSession = false
    fileprivate var bytesWhilePending = 0
    fileprivate var lastWaitingList: Data?
    fileprivate var toldClientInfo = false

    fileprivate init(conn: NWConnection) { self.conn = conn }
}

final class StreamGate {
    /// Before a device is let in, the only message read is an AUTH_RESPONSE.
    static let handshakeMaxPayload = AuthWire.maxResponseBytes
    /// The largest message a client may send in a session.
    static let sessionMaxPayload = 4 << 20
    /// What a waiting connection may send in all before it is closed. None of
    /// it is read.
    static let pendingByteBudget = 64 << 10
    static let maxDecisionBytes = 1024
    static let maxClientInfoBytes = 2048

    /// The link was let in and is this listener's client from now on.
    var onAdmit: (StreamLink) -> Void = { _ in }
    /// A session message from a link that was let in.
    var onMessage: (StreamLink, StreamMessageType, Data) -> Void = { _, _, _ in }
    /// The link is gone, whatever phase it was in.
    var onClose: (StreamLink) -> Void = { _ in }
    /// Which display this listener serves, for HOST_INFO. Nil for a window.
    var displayIndex: Int?

    private let auth: HostAuth
    private let queue: DispatchQueue
    private let label: String
    private var links: [StreamLink] = []
    private var observers: [NSObjectProtocol] = []
    /// Headers of the upgrade requests, waiting for their connections.
    let upgradeHeaders = UpgradeHeaders()

    init(auth: HostAuth, queue: DispatchQueue, label: String) {
        self.auth = auth
        self.queue = queue
        self.label = label
        let changed: (Notification) -> Void = { [weak self] _ in
            guard let self else { return }
            self.queue.async { [weak self] in self?.reconcile() }
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: DeviceTrustStore.didChange, object: auth.store, queue: nil, using: changed),
            center.addObserver(forName: HostAuth.approvalDidChange, object: auth, queue: nil, using: changed),
        ]
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        for link in links {
            // Give back what the link was counted for, so the host does not
            // go on showing a device as connected or waiting.
            release(link)
            link.conn.cancel()
        }
    }

    // MARK: - A new connection

    func accept(_ conn: NWConnection) {
        let link = StreamLink(conn: conn)
        links.append(link)
        attachParser(to: link)
        // Counted from here, not from the WebSocket upgrade, so a connection
        // that never finishes the upgrade cannot sit open either.
        // The address group shares out room; an inbound connection's endpoint
        // is its peer, known before the connection is ready.
        link.address = Self.remoteAddress(of: conn)
        countUnanswered(link)
        let deadline = DispatchWorkItem { [weak self, weak link] in
            guard let self, let link, link.phase == .awaitingResponse else { return }
            self.finish(link, .timeout, why: "no answer to the challenge")
        }
        link.deadline = deadline
        queue.asyncAfter(deadline: .now() + auth.responseDeadline, execute: deadline)
        conn.stateUpdateHandler = { [weak self, weak link] state in
            guard let self, let link else { return }
            switch state {
            case .ready: self.begin(link)
            case .failed(let error): self.close(link, why: "connection failed (\(error))")
            case .cancelled: self.close(link, why: "connection cancelled")
            default: break
            }
        }
        conn.start(queue: queue)
    }

    private func countUnanswered(_ link: StreamLink) {
        link.unanswered = auth.addUnanswered(group: AddressGroup.of(link.address)) { [weak self, weak link] in
            self?.queue.async {
                guard let self, let link, link.phase == .awaitingResponse else { return }
                self.close(link, why: "too many connections had not answered the challenge")
            }
        }
    }

    private func attachParser(to link: StreamLink) {
        link.parser.onMessage = { [weak self, weak link] type, payload in
            guard let self, let link else { return }
            self.received(link, type, payload)
        }
        link.parser.onUnknown = { [weak self, weak link] _ in
            guard let self, let link, link.phase == .accepted else { return }
            self.close(link, why: "a message that was not SECURE arrived on an encrypted session")
        }
    }

    private func begin(_ link: StreamLink) {
        guard link.phase == .awaitingResponse, link.handshake == nil else { return }
        let peer = Self.remoteAddress(of: link.conn)
        let counted = AddressGroup.of(link.address)
        link.address = ClientAddress.resolve(peer: peer, headers: upgradeHeaders.take(), trusted: auth.trustedProxies)
        if AddressGroup.of(link.address) != counted, let token = link.unanswered {
            // Behind a proxy: count the connection in its own group instead.
            auth.removeUnanswered(token)
            countUnanswered(link)
        }
        var capabilities: StreamCapabilities = [.relativeMouse, .textInput, .extraButtons, .deviceApproval, .fileTransfer]
        if auth.requireApproval { capabilities.insert(.approvalRequired) }
        do {
            let handshake = try HostHandshake(identityKey: auth.identity.publicKey,
                                              capabilities: capabilities, name: auth.hostName)
            link.handshake = handshake
            write(StreamMessage.frame(type: .authChallenge, payload: handshake.challenge.payload), to: link)
        } catch {
            close(link, why: "could not build the challenge (\(error))")
            return
        }
        receive(link)
    }

    // MARK: - Reading

    private func receive(_ link: StreamLink) {
        link.conn.receiveMessage { [weak self, weak link] data, _, complete, error in
            guard let self, let link, link.phase != .closed else { return }
            if let data, !data.isEmpty { self.feed(link, data) }
            guard link.phase != .closed else { return }
            if error != nil || (complete && data == nil) {
                self.close(link, why: "client disconnected (\(error.map(String.init(describing:)) ?? "eof"))")
                return
            }
            self.receive(link)
        }
    }

    private func feed(_ link: StreamLink, _ data: Data) {
        switch link.phase {
        case .pending:
            // Nothing a waiting device sends is read; it only counts against
            // what the connection may send before it is closed.
            link.bytesWhilePending += data.count
            if link.bytesWhilePending > Self.pendingByteBudget {
                close(link, why: "sent too much while waiting for approval")
            }
        case .awaitingResponse, .accepted, .open:
            link.parser.feed(data)
            if link.parser.corrupt, link.phase != .closed {
                close(link, why: "a message was larger than this connection may send")
            }
        case .closed:
            break
        }
    }

    /// One whole message from the wire. The phase is read afresh for each
    /// message, because one WebSocket message can carry several.
    private func received(_ link: StreamLink, _ type: StreamMessageType, _ payload: Data) {
        switch link.phase {
        case .awaitingResponse:
            if type == .authResponse {
                answered(link, payload)
            } else if type == .hello, !auth.requireApproval {
                openInTheClear(link)
                if link.phase == .open { onMessage(link, type, payload) }
            }
            // Anything else is ignored and starts nothing.
        case .pending, .closed:
            break
        case .accepted:
            guard type == .secure else {
                close(link, why: "a message that was not SECURE arrived on an encrypted session")
                return
            }
            let inner: (type: UInt8, payload: Data)
            do {
                guard let opened = try link.opener?.open(payload) else { throw AuthError.decryptFailed }
                inner = opened
            } catch {
                close(link, why: "a SECURE message could not be opened (\(error))")
                return
            }
            // An inner type this build does not know is skipped, as any
            // unknown type is.
            guard let innerType = StreamMessageType(rawValue: inner.type) else { return }
            switch innerType {
            case .deviceDecision: decided(link, inner.payload)
            case .clientInfo: clientInfo(link, inner.payload)
            default: onMessage(link, innerType, inner.payload)
            }
        case .open:
            onMessage(link, type, payload)
        }
    }

    // MARK: - The handshake

    private func answered(_ link: StreamLink, _ payload: Data) {
        guard let handshake = link.handshake else { return }
        let device: VerifiedDevice
        do {
            device = try handshake.verify(responsePayload: payload)
        } catch {
            finish(link, .invalid, response: payload, why: "bad answer to the challenge (\(error))")
            return
        }
        link.deadline?.cancel()
        link.deadline = nil
        if let token = link.unanswered {
            auth.removeUnanswered(token)
            link.unanswered = nil
        }
        link.device = device
        let who = "\(device.fingerprint) (\(DeviceTrustStore.storedName(device.name))) from \(link.address.isEmpty ? "an unknown address" : link.address)"

        guard auth.requireApproval else {
            auth.store.noteConnected(id: device.id, name: device.name, address: link.address)
            admit(link, device)
            return
        }
        let group = AddressGroup.of(link.address)
        let answer = auth.store.ask(publicKey: device.publicKey, name: device.name, address: link.address,
                                    group: group,
                                    hasOpenConnection: { [auth] id in auth.hasWaitingConnection(deviceId: id) })
        switch answer {
        case .trusted:
            admit(link, device)
        case .denied:
            finish(link, .denied, response: device.response, why: "\(who) is denied")
        case .busy:
            finish(link, .busy, why: "\(who) asked while the waiting list was full")
        case .waiting:
            let token = auth.admitWaitingConnection(deviceId: device.id, group: group) { [weak self, weak link] in
                self?.queue.async {
                    guard let self, let link, link.phase == .pending else { return }
                    self.finish(link, .busy, why: "its place went to a connection from an address group with fewer waiting")
                }
            }
            guard let token else {
                // Turned away: an earlier waiting link from the same device is
                // left as it was (it is still a waiting connection that proved
                // the key), so a refused newcomer never costs the device both.
                finish(link, .busy, why: "\(who) asked while too many connections were waiting")
                return
            }
            // One waiting connection per device on a listener: both proved
            // they hold the key, so the newer takes the place of the older, but
            // only now that the newer one has its place.
            for earlier in links where earlier !== link && earlier.phase == .pending && earlier.device?.id == device.id {
                finish(earlier, .busy, why: "\(who) connected again on this listener")
            }
            link.waitingToken = token
            wait(link, device)
            clog("DEVICES: \(who) is waiting for approval")
        }
    }

    private func wait(_ link: StreamLink, _ device: VerifiedDevice) {
        guard let handshake = link.handshake,
              let result = try? handshake.result(.pending, response: device.response, sign: auth.identity.sign) else {
            close(link, why: "could not sign the result")
            return
        }
        let message = StreamMessage.frame(type: .authResult, payload: result)
        link.phase = .pending
        link.pendingResult = message
        write(message, to: link)

        // Said again every so often, which also keeps a tunnel from idling
        // the socket out.
        let every = max(0.05, auth.pendingRepeat)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + every, repeating: every)
        timer.setEventHandler { [weak self, weak link] in
            guard let self, let link, link.phase == .pending, let message = link.pendingResult else { return }
            self.write(message, to: link)
        }
        timer.resume()
        link.pendingTimer = timer

        let deadline = DispatchWorkItem { [weak self, weak link] in
            guard let self, let link, link.phase == .pending else { return }
            self.finish(link, .timeout, why: "nobody decided in time; the device stays on the waiting list")
        }
        link.deadline = deadline
        queue.asyncAfter(deadline: .now() + auth.approvalTimeout, execute: deadline)
    }

    /// Lets the device in: `accepted`, then the encrypted session.
    private func admit(_ link: StreamLink, _ device: VerifiedDevice) {
        guard link.phase == .awaitingResponse || link.phase == .pending,
              let handshake = link.handshake else { return }
        let wasPending = link.phase == .pending
        let keys: SessionKeys
        let result: Data
        do {
            keys = try handshake.sessionKeys(with: device)
            result = try handshake.result(.accepted, response: device.response, sign: auth.identity.sign)
        } catch {
            finish(link, .invalid, response: device.response, why: "could not start the session (\(error))")
            return
        }
        release(link)
        write(StreamMessage.frame(type: .authResult, payload: result), to: link)
        link.sealer = SecureSealer(key: keys.hostToClient)
        link.opener = SecureOpener(key: keys.clientToHost)
        link.handshake = nil
        link.pendingResult = nil
        if wasPending {
            // Whatever the device sent while it waited was never read; start
            // clean rather than in the middle of it.
            link.parser = StreamMessageParser(maxPayload: Self.sessionMaxPayload)
            attachParser(to: link)
        } else {
            link.parser.maxPayload = Self.sessionMaxPayload
        }
        link.phase = .accepted
        auth.sessionOpened(deviceId: device.id)
        link.countedAsSession = true
        let trusted = auth.store.isTrusted(device.id)
        clog("DEVICES: \(label): let in \(device.fingerprint) (\(DeviceTrustStore.storedName(device.name))) from \(link.address)\(trusted ? "" : " — not on the trusted list; device approval is off")")

        onAdmit(link)
        guard link.phase == .accepted else { return }
        // HOST_INFO is the first message of the encrypted session.
        let info = auth.directory.hostInfo(name: auth.hostName, hostId: auth.identity.id,
                                           display: displayIndex, includeReported: trusted)
        send(StreamMessage.frame(type: .hostInfo, payload: info), to: link)
        sendWaitingList(to: link, evenIfUnchanged: false)
    }

    /// A host with approval off serves a client that never answers the
    /// challenge the way hosts before 0.12 did.
    private func openInTheClear(_ link: StreamLink) {
        guard link.phase == .awaitingResponse, !auth.requireApproval else { return }
        release(link)
        link.handshake = nil
        link.parser.maxPayload = Self.sessionMaxPayload
        link.phase = .open
        auth.sessionOpened(deviceId: nil)
        link.countedAsSession = true
        clog("STREAM: \(label): clear session from \(link.address) — device approval is off")
        onAdmit(link)
    }

    private func finish(_ link: StreamLink, _ status: AuthStatus, response: Data = Data(), why: String) {
        guard link.phase != .closed else { return }
        let result = link.handshake.flatMap { try? $0.result(status, response: response, sign: auth.identity.sign) }
        close(link, why: "\(status): \(why)",
              lastWords: result.map { StreamMessage.frame(type: .authResult, payload: $0) })
    }

    // MARK: - Sending

    /// Sends one framed session message to a link that was let in: sealed on
    /// an encrypted session, as it is on a clear one. A link that is not in
    /// is sent nothing.
    func send(_ framed: Data, to link: StreamLink, completion: ((NWError?) -> Void)? = nil) {
        switch link.phase {
        case .accepted:
            do {
                // Sealed and written in one step on the queue, so the wire
                // order is the counter order.
                guard let sealed = try link.sealer?.sealMessage(framed) else { throw AuthError.malformed }
                write(sealed, to: link, completion: completion)
            } catch {
                close(link, why: "could not encrypt a message (\(error))")
            }
        case .open:
            write(framed, to: link, completion: completion)
        case .awaitingResponse, .pending, .closed:
            break
        }
    }

    private func write(_ data: Data, to link: StreamLink, completion: ((NWError?) -> Void)? = nil) {
        link.conn.send(content: data, contentContext: Self.binaryMessage(), isComplete: true,
                       completion: .contentProcessed { error in completion?(error) })
    }

    private static func binaryMessage() -> NWConnection.ContentContext {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        return NWConnection.ContentContext(identifier: "msg", metadata: [metadata])
    }

    // MARK: - Closing

    func close(_ link: StreamLink, why: String, lastWords: Data? = nil) {
        guard link.phase != .closed else { return }
        let was = link.phase
        release(link)
        link.phase = .closed
        link.handshake = nil
        link.sealer = nil
        link.opener = nil
        link.pendingResult = nil
        links.removeAll { $0 === link }
        let conn = link.conn
        if let lastWords {
            // Let the result reach the client before the socket goes.
            conn.send(content: lastWords, contentContext: Self.binaryMessage(), isComplete: true,
                      completion: .contentProcessed { _ in conn.cancel() })
            queue.asyncAfter(deadline: .now() + 5) { conn.cancel() }
        } else {
            conn.cancel()
        }
        let who = link.device.map { " \($0.fingerprint)" } ?? ""
        clog("STREAM: \(label): closed a connection (\(was))\(who) from \(link.address.isEmpty ? "an unknown address" : link.address) — \(why)")
        onClose(link)
    }

    /// Closes every connection, let in or not. For a listener that is going away.
    func closeAll(why: String) {
        for link in links { close(link, why: why) }
    }

    private func release(_ link: StreamLink) {
        link.deadline?.cancel()
        link.deadline = nil
        link.pendingTimer?.cancel()
        link.pendingTimer = nil
        if let token = link.unanswered {
            auth.removeUnanswered(token)
            link.unanswered = nil
        }
        if let token = link.waitingToken {
            auth.releaseWaiting(token)
            link.waitingToken = nil
        }
        if link.countedAsSession {
            auth.sessionClosed(deviceId: link.device?.id)
            link.countedAsSession = false
        }
    }

    // MARK: - When the device list or the setting changes

    private func reconcile() {
        let approval = auth.requireApproval
        for link in links {
            switch link.phase {
            case .pending:
                guard let device = link.device else { continue }
                guard approval else {
                    admit(link, device)
                    continue
                }
                switch auth.store.state(of: device.id) {
                case .trusted?: admit(link, device)
                case .denied?: finish(link, .denied, response: device.response, why: "\(device.fingerprint) was denied")
                case .waiting?: break
                case nil: finish(link, .timeout, why: "\(device.fingerprint) is no longer on the waiting list")
                }
            case .accepted:
                if approval, let device = link.device, !auth.store.isTrusted(device.id) {
                    close(link, why: "it is no longer trusted")
                }
            case .open:
                if approval { close(link, why: "device approval was turned on") }
            case .awaitingResponse, .closed:
                break
            }
        }
        for link in links where link.phase == .accepted {
            sendWaitingList(to: link, evenIfUnchanged: false)
        }
    }

    // MARK: - Approving from a trusted device

    /// DEVICE_PENDING, for a trusted device that can show the approval prompt.
    private func sendWaitingList(to link: StreamLink, evenIfUnchanged: Bool) {
        guard link.phase == .accepted, let device = link.device,
              device.capabilities.contains(.deviceApproval), auth.store.isTrusted(device.id) else { return }
        let devices: [[String: Any]] = auth.store.waiting().map {
            ["id": $0.id, "name": $0.name, "fingerprint": $0.fingerprint,
             "firstSeen": Int($0.firstSeen), "address": $0.address]
        }
        guard let json = try? JSONSerialization.data(withJSONObject: ["devices": devices],
                                                     options: [.sortedKeys]) else { return }
        if !evenIfUnchanged {
            if json == link.lastWaitingList { return }
            // Nothing was waiting and nothing is: there is nothing to say.
            if link.lastWaitingList == nil, devices.isEmpty { return }
        }
        link.lastWaitingList = json
        send(StreamMessage.frame(type: .devicePending, payload: json), to: link)
    }

    /// DEVICE_DECISION. Honoured only from a device that is trusted right
    /// now, and only for a device that is still waiting.
    private func decided(_ link: StreamLink, _ payload: Data) {
        guard let device = link.device, device.capabilities.contains(.deviceApproval),
              auth.store.isTrusted(device.id) else {
            clog("DEVICES: ignored a decision from a device that is not trusted")
            return
        }
        guard payload.count <= Self.maxDecisionBytes,
              let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let id = object["id"] as? String, DeviceIdentity.isWellFormedId(id),
              let word = object["decision"] as? String, word == "approve" || word == "deny" else {
            clog("DEVICES: ignored a malformed decision from \(device.fingerprint)")
            return
        }
        switch auth.store.decideRelayed(id: id, word == "approve" ? .approve : .deny, by: device.id) {
        case .applied(let record):
            clog("DEVICES: \(record.fingerprint) (\(record.name)) was \(word == "approve" ? "approved" : "denied") from device \(device.fingerprint) (\(DeviceTrustStore.storedName(device.name)))")
        case .unchanged:
            clog("DEVICES: a decision from \(device.fingerprint) changed nothing: that device is not waiting")
        case .relayerNotTrusted:
            // Revoked since the check above, by another process: nothing was
            // changed, and its session ends the way a revoke ends it.
            clog("DEVICES: ignored a decision from \(device.fingerprint): it is no longer trusted")
            close(link, why: "it is no longer trusted")
            return
        }
        sendWaitingList(to: link, evenIfUnchanged: true)
    }

    // MARK: - CLIENT_INFO

    private func clientInfo(_ link: StreamLink, _ payload: Data) {
        guard let device = link.device, payload.count <= Self.maxClientInfoBytes,
              let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else { return }
        if !link.toldClientInfo {
            link.toldClientInfo = true
            let app = AuthWire.cleanName((object["app"] as? String) ?? "")
            let version = AuthWire.cleanName((object["version"] as? String) ?? "")
            clog("STREAM: \(label): \(device.fingerprint) is \(app.isEmpty ? "an unnamed client" : app) \(version)")
        }
        // Only a device the user approved may teach the host an address, and
        // only for the display it is connected to.
        guard let url = object["url"] as? String, let display = displayIndex,
              auth.store.isTrusted(device.id) else { return }
        auth.directory.report(url: url, display: display)
    }

    // MARK: -

    static func remoteAddress(of conn: NWConnection) -> String {
        guard case let .hostPort(host, _) = conn.currentPath?.remoteEndpoint ?? conn.endpoint else { return "" }
        var text: String
        switch host {
        case .ipv4(let address): text = "\(address)"
        case .ipv6(let address): text = "\(address)"
        case .name(let name, _): text = name
        @unknown default: text = "\(host)"
        }
        // Drop the interface scope ("%en0") and the IPv4-in-IPv6 prefix.
        if let scope = text.firstIndex(of: "%") { text = String(text[..<scope]) }
        if text.lowercased().hasPrefix("::ffff:"), text.contains(".") { text = String(text.dropFirst(7)) }
        return text
    }
}
