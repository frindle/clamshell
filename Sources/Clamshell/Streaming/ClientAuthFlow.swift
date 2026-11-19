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
    /// Close; this address reached a different saved Mac than the one picked,
    /// or (with `fallsThrough`) a host whose key is not the saved one or that
    /// did not identify itself; the last state says which.
    /// The caller tries the picked Mac's next saved address at once, and uses
    /// its own back-off after the last one.
    case nextAddress
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
    /// The saved Mac the user picked, when the caller knows it. When it is nil
    /// the saved Mac the dialled address belonged to is taken as the pick.
    var expectedHostId: String?
    /// True when the caller chose this address itself from the saved Mac's
    /// list (not the one the user picked) and has another one to try after it.
    /// An unknown key or no challenge there ends the attempt with
    /// `nextAddress` instead of `stop`: the state still tells what was wrong,
    /// the caller decides when to show it. The pin is not weakened: nothing is
    /// answered or sent to that host and nothing is saved.
    var fallsThrough = false
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
            guard yes, let h = handshake, address != nil else { return finish(.stop, "user declined", state: nil) }
            phase = .ended
            return [.change(.recordVerified(key: h.hostIdentityKey, name: h.hostName, address: config.dialledURL)),
                    .end(.reconnect(after: 0, carry: FlowCarry()), "host confirmed by the user")]
        default:
            return []
        }
    }

    /// One message from the host: its type byte and payload.
    mutating func received(type: UInt8, payload: Data) -> [FlowAction] {
        switch phase {
        case .idle:
            // The host speaks first, and the socket's "open" and its first
            // message are two separate callbacks with no promised order. A
            // challenge that is handed over first counts as the open: it is
            // answered, never dropped (a dropped challenge from a saved host
            // would end as "did not identify itself" 2 s later). Anything else
            // before the open is still ignored.
            guard type == StreamMessageType.authChallenge.rawValue else { return [] }
            let open = opened()
            guard phase == .awaitingChallenge else { return open }
            return open + handleChallenge(payload)
        case .ended, .askingHost:
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
            return finish(config.fallsThrough ? .nextAddress : .stop,
                          "a saved host did not identify itself", state: .didNotIdentify(hostName: name))
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
        // Rule 4, unless the key that answered is another saved Mac's: that one
        // passes its own pin, and the result step below decides what to do
        // (the address moves, and the attempt ends so the next address is tried).
        if case let .host(savedId) = standing, savedId != id, known.host(id: id) == nil {
            let saved = DeviceIdentity.fingerprint(ofId: savedId)
            return finish(config.fallsThrough ? .nextAddress : .stop, "identity changed", state: .changedIdentity(
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
                // The dialled URL, not the bare address: a tunnel's display path
                // is kept with the address so a later fallback reaches the same display.
                actions.append(.change(.bind(hostId: h.hostId, address: config.dialledURL)))
            }
        }
        let name = h.hostName
        // A different saved Mac answered at an address that was another saved
        // Mac's. It passes its own pin, so it is not a success for the one
        // picked: the address has moved (the change above), and this attempt
        // ends so the caller can try the picked Mac's next address.
        var picked = config.expectedHostId
        if picked == nil, case let .host(id) = standing { picked = id }
        if hostKnown, let picked, picked != h.hostId, known.host(id: picked) != nil {
            let now = known.host(id: h.hostId)?.name ?? name
            let text = "This address now reaches \(now)"
            return actions + finish(.nextAddress, "the address reached a different saved Mac", state: .failed(text))
        }
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
                guard address != nil else { return fail("the address cannot be used") }
                actions.append(.change(.recordVerified(key: h.hostIdentityKey, name: name, address: config.dialledURL)))
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

/// An alarm (changed key, no identification) that an address the client chose
/// itself ended with; held back until it is known that no other address
/// connects.
struct DialAlarm: Equatable {
    var state: FlowState
    var address: String
}

/// What the client does when one attempt at one of a saved Mac's addresses
/// ends. No socket and no clock in it: the app feeds it what happened and does
/// what it says, and the tests run it on the Mac.
///
/// The rule: "identity changed" or "did not identify" is shown when the user
/// picked that address, or when no other address succeeds, and it names the
/// address that misbehaved. Nothing is accepted without the pinned key (the
/// flow itself keeps that; this type only decides what comes next).
enum DialPlanFlow {
    enum Outcome: Equatable {
        /// Dial the plan's next address; carry this held alarm (if any).
        case tryNext(held: DialAlarm?)
        /// Every address failed and one raised an alarm: show it.
        case showAlarm(DialAlarm)
        /// Show the plain error and let the caller's back-off run.
        /// `restartPlan`: the next attempt starts again at the first address.
        case showError(restartPlan: Bool, held: DialAlarm?)

        var held: DialAlarm? {
            switch self {
            case let .tryNext(held): return held
            case let .showAlarm(alarm): return alarm
            case let .showError(_, held): return held
            }
        }
    }

    /// What a state that a session reached means for the alarm held so far: a
    /// connection with the pinned key makes it moot.
    static func held(after state: FlowState, _ held: DialAlarm?) -> DialAlarm? {
        if case .connected = state { return nil }
        return held
    }

    /// An attempt ended with `.failure` or `.nextAddress`.
    /// - `shown`: the last state the attempt showed.
    /// - `opened`: whether the socket opened.
    /// - `address`: the address this attempt dialled.
    /// - `isPicked`: the user picked it (the plan's other addresses were added
    ///   by the client from the saved Mac's list).
    /// - `isLast`: no address follows it in the plan.
    static func decide(end: FlowEnd, shown: FlowState?, opened: Bool, address: String,
                       isPicked: Bool, isLast: Bool, held: DialAlarm?) -> Outcome {
        let wrongMac = end == .nextAddress
        var held = held
        switch shown {
        case .changedIdentity?, .didNotIdentify?:
            if wrongMac, held == nil, let shown { held = DialAlarm(state: shown, address: address) }
        default: break
        }
        var reachedSession = false
        switch shown {
        case .connected?, .waitingForApproval?, .busy?: reachedSession = true
        default: break
        }
        // An address this client chose that opened but never got as far as a
        // session (not connected, not waiting for approval) also moves on.
        let failedEarly = opened && !isPicked && !reachedSession
        // The address the user picked opened and dropped before any session, on
        // the last address of the plan: a held alarm from an earlier address
        // must not be lost behind a plain error, and with none held the whole
        // plan is tried again.
        let pickedDropped = opened && isPicked && isLast && !reachedSession
        guard !opened || wrongMac || failedEarly || pickedDropped else {
            return .showError(restartPlan: false, held: held)
        }
        if !isLast { return .tryNext(held: held) }
        if let held { return .showAlarm(held) }
        return .showError(restartPlan: true, held: nil)
    }
}
