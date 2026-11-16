import Foundation
import CryptoKit

// The client's side of one connection, as a state machine with no socket, no
// clock and no storage in it (PROTOCOL.md "Client rules"). The caller feeds it
// events (the socket opened, a message arrived, a timer ran out, the user
// answered, the app wants to send) and does what the returned actions say. One
// value is one connection attempt; the next attempt is a new value.
// Compiled into the Mac package, where `swift test` runs it, and the iOS app.

enum FlowTimer: Equatable {
    /// Waiting for AUTH_CHALLENGE after the socket opened (2 s, or 10 s).
    case challenge
    /// Waiting for the first AUTH_RESULT after the response was sent (15 s).
    case result
    /// Waiting for the next AUTH_RESULT while the host says `pending` (60 s).
    case pending
}

/// What carries over from one attempt to the next.
struct FlowCarry: Equatable {
    /// Seconds to wait for a challenge: 2, or 10 after a late challenge.
    var challengeWait: Double = ClientAuthFlow.challengeWait
    /// The wait before the next try after `busy` (or a second `timeout`).
    var busyDelay: Double = ClientAuthFlow.busyFirstDelay
    /// True once a `timeout` was answered with an immediate reconnect.
    var timeoutRetried = false
}

enum FlowEnd: Equatable {
    /// Close and do not connect again unless the user asks.
    case stop
    /// Close; the caller's own backoff decides when to try again.
    case failure
    /// Close and connect again after this many seconds, carrying this.
    case reconnect(after: Double, carry: FlowCarry)
}

/// What the screen shows. Values only: no key, signature or message content.
enum FlowState: Equatable {
    case connecting
    /// The host said `pending`: the owner has to approve this device on the Mac.
    case waitingForApproval(hostName: String, hostFingerprint: String,
                            deviceName: String, deviceFingerprint: String)
    /// Rule 12: the host let this device in without asking.
    case confirmHost(hostName: String, fingerprint: String)
    /// Rule 4.
    case changedIdentity(address: String, savedFingerprint: String, nowFingerprint: String)
    /// Rule 5.
    case didNotIdentify(hostName: String)
    /// Rule 6: asks whether to connect with no proof of who answers.
    case askUnverified(address: String)
    case denied(hostName: String)
    case invalid(hostName: String)
    case busy(retryIn: Int)
    case connected(verified: Bool, hostName: String)
    case failed(String)
}

enum FlowAction: Equatable {
    /// Bytes for the socket, already framed.
    case send(Data)
    case startTimer(FlowTimer, Double)
    case cancelTimer(FlowTimer)
    case state(FlowState)
    /// An inner message for the app (never HOST_INFO, which the flow keeps).
    case deliver(type: UInt8, payload: Data)
    case change(KnownHostsChange)
    /// What the host offers. Empty until `accepted` is verified and again when
    /// the connection ends.
    case hostCapabilities(StreamCapabilities)
    /// Close the socket now. The flow lives on, waiting for the user's answer
    /// (rule 12); the caller must not report that close back as `socketClosed`.
    case close(String)
    /// The connection is over; the reason is for the log (no secrets in it).
    case end(FlowEnd, String)
}

struct ClientAuthConfig {
    /// The device's 65-byte public key.
    var deviceKey: Data
    var sign: AuthSigner
    var deviceName: String
    var fallbackDeviceName = "iPad"
    var capabilities: StreamCapabilities = ClientAuthFlow.defaultCapabilities
    var appName = "ios"
    var appVersion: String
    /// The WebSocket URL actually dialled.
    var dialledURL: String
    /// A whole HELLO message (framed). Called when HELLO is sent.
    var makeHello: () -> Data
    /// For tests: response extensions, a fixed ephemeral key and a fixed nonce.
    /// The app sends no extension and uses random values (nil).
    var extensions: [AuthExtension] = []
    var ephemeral: P256.KeyAgreement.PrivateKey?
    var nonce: Data?

    init(deviceKey: Data, sign: @escaping AuthSigner, deviceName: String, appVersion: String,
         dialledURL: String, makeHello: @escaping () -> Data) {
        self.deviceKey = deviceKey
        self.sign = sign
        self.deviceName = deviceName
        self.appVersion = appVersion
        self.dialledURL = dialledURL
        self.makeHello = makeHello
    }
}

struct ClientAuthFlow {
    static let challengeWait: Double = 2
    static let lateChallengeWait: Double = 10
    static let resultWait: Double = 15
    static let pendingWait: Double = 60
    static let busyFirstDelay: Double = 15
    static let busyMaxDelay: Double = 120
    /// The bits the iOS app really honours today. Bits 4 to 6 stay 0.
    static let defaultCapabilities: StreamCapabilities = [.relativeMouse, .textInput, .extraButtons]

    private enum Phase {
        case idle
        case awaitingChallenge
        case askingUnverified
        /// HELLO went out in the clear (rule 6).
        case clearSession
        case awaitingResult
        case pending
        /// Rule 12: closed, waiting for the user.
        case askingHost
        case secure
        case ended
    }

    private let config: ClientAuthConfig
    private let known: KnownHosts
    private let carry: FlowCarry
    private let address: String?
    private let standing: AddressStanding

    private var phase = Phase.idle
    private var handshake: ClientHandshake?
    private var waitingShown = false
    private var bound = false
    private var sealer: SecureSealer?
    private var opener: SecureOpener?
    private var capsPublished = false

    init(config: ClientAuthConfig, known: KnownHosts, carry: FlowCarry = FlowCarry()) {
        self.config = config
        self.known = known
        self.carry = carry
        let a = KnownHosts.normalizeAddress(config.dialledURL)
        address = a
        standing = a.map { known.standing(of: $0) } ?? .unknown
    }

    var deviceName: String {
        let cleaned = AuthWire.cleanName(config.deviceName)
        return cleaned.isEmpty ? config.fallbackDeviceName : cleaned
    }

    var deviceFingerprint: String { DeviceIdentity.fingerprint(ofPublicKey: config.deviceKey) }

    /// True while the connection is up with the host's key verified.
    var isSecure: Bool { phase == .secure }
    var isEnded: Bool { phase == .ended }

    // MARK: Events

    /// The socket opened. Nothing is sent: the host speaks first.
    mutating func opened() -> [FlowAction] {
        guard phase == .idle else { return [] }
        guard address != nil else { return fail("the address cannot be used") }
        phase = .awaitingChallenge
        return [.state(.connecting), .startTimer(.challenge, carry.challengeWait)]
    }

    /// The socket closed or failed from the other side or the network.
    mutating func socketClosed() -> [FlowAction] {
        guard phase != .ended, phase != .askingHost else { return [] }
        return finish(.failure, "the connection closed", state: nil)
    }

    mutating func timerFired(_ timer: FlowTimer) -> [FlowAction] {
        switch (timer, phase) {
        case (.challenge, .awaitingChallenge):
            return challengeTimedOut()
        case (.result, .awaitingResult):
            return fail("the host did not answer")
        case (.pending, .pending):
            return finish(.reconnect(after: 0, carry: carry), "no result for 60 s", state: .connecting)
        default:
            return []
        }
    }

    /// The user answered the question the state asks (`askUnverified` or `confirmHost`).
    mutating func answered(_ yes: Bool) -> [FlowAction] {
        switch phase {
        case .askingUnverified:
            guard yes, let address else { return finish(.stop, "user declined", state: nil) }
            phase = .clearSession
            return [.change(.allowUnverified(address: address)),
                    .send(config.makeHello()),
                    .hostCapabilities([]),
                    .state(.connected(verified: false, hostName: ""))]
        case .askingHost:
            guard yes, let h = handshake, let address else { return finish(.stop, "user declined", state: nil) }
            phase = .ended
            return [.change(.recordVerified(key: h.hostIdentityKey, name: h.hostName, address: address)),
                    .end(.reconnect(after: 0, carry: FlowCarry()), "host confirmed by the user")]
        default:
            return []
        }
    }

    /// One message from the host: its type byte and payload.
    mutating func received(type: UInt8, payload: Data) -> [FlowAction] {
        switch phase {
        case .idle, .ended, .askingHost:
            return []
        case .awaitingChallenge, .askingUnverified:
            guard type == StreamMessageType.authChallenge.rawValue else {
                return fail("message before the challenge")
            }
            return handleChallenge(payload)
        case .clearSession:
            if type == StreamMessageType.authChallenge.rawValue {
                // A host that does speak auth, only slower than we waited.
                var next = carry
                next.challengeWait = Self.lateChallengeWait
                return finish(.reconnect(after: 0, carry: next), "challenge after a clear HELLO", state: .connecting)
            }
            if type == StreamMessageType.authResult.rawValue || type == StreamMessageType.secure.rawValue
                || type == StreamMessageType.authResponse.rawValue {
                return fail("unexpected message in a clear session")
            }
            return [.deliver(type: type, payload: payload)]
        case .awaitingResult, .pending:
            guard type == StreamMessageType.authResult.rawValue else {
                return fail("message before the result")
            }
            return handleResult(payload)
        case .secure:
            guard type == StreamMessageType.secure.rawValue else { return fail("clear message after accepted") }
            return handleSecure(payload)
        }
    }

    /// The app wants to send one whole framed message. Returns the bytes for
    /// the socket. Before `accepted` is verified nothing the app sends goes
    /// out: it is dropped, never queued. In an unverified clear session it
    /// goes as it is. Sealing happens here, in call order, so the caller must
    /// put the returned bytes on the wire in call order.
    mutating func send(_ message: Data) -> [FlowAction] {
        switch phase {
        case .clearSession:
            return [.send(message)]
        case .secure:
            do {
                guard var s = sealer else { return [] }
                let sealed = try s.sealMessage(message)
                sealer = s
                return [.send(sealed)]
            } catch {
                return fail("could not seal a message")
            }
        default:
            return []
        }
    }

    // MARK: Challenge

    private mutating func challengeTimedOut() -> [FlowAction] {
        if case let .host(id) = standing {
            let name = known.host(id: id)?.name ?? ""
            return finish(.stop, "a saved host did not identify itself", state: .didNotIdentify(hostName: name))
        }
        guard let address else { return fail("the address cannot be used") }
        if standing == .unknownAllowed {
            phase = .clearSession
            return [.send(config.makeHello()), .hostCapabilities([]),
                    .state(.connected(verified: false, hostName: ""))]
        }
        phase = .askingUnverified
        return [.state(.askUnverified(address: address))]
    }

    private mutating func handleChallenge(_ payload: Data) -> [FlowAction] {
        guard let challenge = try? AuthChallenge.decode(payload),
              DeviceIdentity.isValidPublicKey(challenge.hello.identityKey) else {
            return fail("the challenge is not valid")
        }
        let id = DeviceIdentity.id(ofPublicKey: challenge.hello.identityKey)
        if case let .host(savedId) = standing, savedId != id {
            let saved = DeviceIdentity.fingerprint(ofId: savedId)
            return finish(.stop, "identity changed", state: .changedIdentity(
                address: address ?? "", savedFingerprint: saved,
                nowFingerprint: DeviceIdentity.fingerprint(ofId: id)))
        }
        guard let h = try? ClientHandshake(challengePayload: payload, deviceKey: config.deviceKey,
                                           capabilities: config.capabilities, name: deviceName,
                                           extensions: config.extensions,
                                           ephemeral: config.ephemeral ?? P256.KeyAgreement.PrivateKey(),
                                           nonce: config.nonce ?? AuthWire.randomBytes(AuthWire.nonceBytes),
                                           sign: config.sign) else {
            return fail("could not answer the challenge")
        }
        handshake = h
        phase = .awaitingResult
        return [.cancelTimer(.challenge),
                .send(StreamMessage.frame(type: .authResponse, payload: h.response)),
                .startTimer(.result, Self.resultWait),
                .state(.connecting)]
    }

    // MARK: Result

    private mutating func handleResult(_ payload: Data) -> [FlowAction] {
        guard let h = handshake, let status = try? h.status(ofResult: payload) else {
            return fail("a result did not verify")
        }
        var actions: [FlowAction] = [.cancelTimer(.result), .cancelTimer(.pending)]
        let hostKnown = known.host(id: h.hostId) != nil
        // A verified result proves the host holds the key in the challenge.
        if hostKnown, !bound, let address {
            bound = true
            if standing != .host(id: h.hostId) {
                actions.append(.change(.bind(hostId: h.hostId, address: address)))
            }
        }
        let name = h.hostName
        switch status {
        case .pending:
            phase = .pending
            waitingShown = true
            actions.append(.startTimer(.pending, Self.pendingWait))
            actions.append(.state(.waitingForApproval(hostName: name, hostFingerprint: h.hostFingerprint,
                                                      deviceName: deviceName, deviceFingerprint: deviceFingerprint)))
            return actions
        case .accepted:
            if waitingShown || hostKnown {
                guard let address else { return fail("the address cannot be used") }
                actions.append(.change(.recordVerified(key: h.hostIdentityKey, name: name, address: address)))
                return actions + startSession(h)
            }
            // Rule 12: let in without being asked, by a host not met before.
            phase = .askingHost
            return actions + [.close("a host not met before let this device in; asking the user"),
                              .state(.confirmHost(hostName: name, fingerprint: h.hostFingerprint))]
        case .denied:
            return actions + finish(.stop, "denied", state: .denied(hostName: name))
        case .invalid:
            return actions + finish(.stop, "invalid", state: .invalid(hostName: name))
        case .busy:
            return actions + retryActions(afterBusy: true)
        case .timeout:
            if !carry.timeoutRetried {
                var next = carry
                next.timeoutRetried = true
                return actions + finish(.reconnect(after: 0, carry: next), "timeout", state: .connecting)
            }
            return actions + retryActions(afterBusy: false)
        }
    }

    private mutating func retryActions(afterBusy: Bool) -> [FlowAction] {
        var next = carry
        let delay = carry.busyDelay
        next.busyDelay = min(delay * 2, Self.busyMaxDelay)
        return finish(.reconnect(after: delay, carry: next), afterBusy ? "busy" : "timeout again",
                      state: .busy(retryIn: Int(delay)))
    }

    // MARK: Session

    private mutating func startSession(_ h: ClientHandshake) -> [FlowAction] {
        do {
            let keys = try h.sessionKeys()
            var s = SecureSealer(key: keys.clientToHost)
            opener = SecureOpener(key: keys.hostToClient)
            let hello = try s.sealMessage(config.makeHello())
            let info = try s.sealMessage(StreamMessage.frame(type: .clientInfo, payload: clientInfoJSON()))
            sealer = s
            phase = .secure
            capsPublished = true
            return [.hostCapabilities(h.hostCapabilities),
                    .state(.connected(verified: true, hostName: h.hostName)),
                    .send(hello), .send(info)]
        } catch {
            return fail("could not start the encrypted session")
        }
    }

    private func clientInfoJSON() -> Data {
        var obj: [String: Any] = ["app": config.appName, "version": config.appVersion]
        if let url = Self.cleanURL(config.dialledURL) { obj["url"] = url }
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// The URL without user info, query or fragment, as the spec wants it.
    static func cleanURL(_ text: String) -> String? {
        guard var c = URLComponents(string: text) else { return nil }
        c.user = nil; c.password = nil; c.query = nil; c.fragment = nil
        return c.string
    }

    private mutating func handleSecure(_ payload: Data) -> [FlowAction] {
        guard var o = opener else { return fail("no session") }
        let inner: (type: UInt8, payload: Data)
        do { inner = try o.open(payload) } catch { return fail("a SECURE message did not open") }
        opener = o
        if inner.type == StreamMessageType.hostInfo.rawValue {
            guard let h = handshake else { return [] }
            let urls = Self.hostInfoURLs(inner.payload)
            return urls.isEmpty ? [] : [.change(.hints(hostId: h.hostId, urls: urls))]
        }
        return [.deliver(type: inner.type, payload: inner.payload)]
    }

    /// Every URL HOST_INFO lists, with sane caps on how much is read. The
    /// store applies the spec's per-URL limits.
    static func hostInfoURLs(_ payload: Data) -> [String] {
        guard payload.count <= 64 * 1024,
              let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let displays = obj["displays"] as? [[String: Any]] else { return [] }
        var out: [String] = []
        for d in displays.prefix(8) {
            for u in (d["urls"] as? [Any] ?? []).prefix(32) {
                if let s = u as? String { out.append(s) }
            }
        }
        return out
    }

    // MARK: Ending

    private mutating func fail(_ reason: String) -> [FlowAction] {
        finish(.failure, reason, state: .failed(reason))
    }

    private mutating func finish(_ end: FlowEnd, _ reason: String, state shown: FlowState?) -> [FlowAction] {
        phase = .ended
        var actions: [FlowAction] = [.cancelTimer(.challenge), .cancelTimer(.result), .cancelTimer(.pending)]
        if capsPublished {
            capsPublished = false
            actions.append(.hostCapabilities([]))
        }
        if let shown { actions.append(.state(shown)) }
        actions.append(.end(end, reason))
        return actions
    }
}
