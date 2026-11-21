import XCTest
import CryptoKit
@testable import Clamshell

/// The client connection flow against the real host half (`HostHandshake`) in
/// memory, and against tests/vectors/auth-v1.json. No sockets, no clock.
final class ClientAuthFlowTests: XCTestCase {
    private let hostKey = P256.Signing.PrivateKey()
    private let deviceKey = P256.Signing.PrivateKey()
    private let url = "ws://192.168.1.20:5903"
    private let address = "192.168.1.20:5903"

    private var hostPub: Data { hostKey.publicKey.x963Representation }
    private var devicePub: Data { deviceKey.publicKey.x963Representation }
    private var helloFrame: Data { StreamMessage.frame(type: .hello, payload: Data([1, 2])) }
    private let challengeType = StreamMessageType.authChallenge.rawValue
    private let resultType = StreamMessageType.authResult.rawValue
    private let secureType = StreamMessageType.secure.rawValue

    private func config(url: String? = nil, name: String = "Example iPad") -> ClientAuthConfig {
        let frame = helloFrame
        return ClientAuthConfig(deviceKey: devicePub, sign: AuthSignature.signer(deviceKey), deviceName: name,
                                appVersion: "0.1.0", dialledURL: url ?? self.url, makeHello: { frame })
    }

    private func known(address: String? = nil, key: Data? = nil) -> KnownHosts {
        var k = KnownHosts()
        k.recordVerified(key: key ?? hostPub, name: "Studio", address: address ?? self.address, now: 1)
        return k
    }

    private func host(caps: StreamCapabilities = [.relativeMouse, .extraButtons]) throws -> HostHandshake {
        try HostHandshake(identityKey: hostPub, capabilities: caps, name: "Studio")
    }

    private func hostSigner() -> AuthSigner { AuthSignature.signer(hostKey) }

    // MARK: action helpers

    private func sent(_ actions: [FlowAction]) -> [Data] {
        actions.compactMap { if case let .send(d) = $0 { return d } else { return nil } }
    }

    private func states(_ actions: [FlowAction]) -> [FlowState] {
        actions.compactMap { if case let .state(s) = $0 { return s } else { return nil } }
    }

    private func changes(_ actions: [FlowAction]) -> [KnownHostsChange] {
        actions.compactMap { if case let .change(c) = $0 { return c } else { return nil } }
    }

    private func end(_ actions: [FlowAction]) -> FlowEnd? {
        for a in actions { if case let .end(e, _) = a { return e } }
        return nil
    }

    private func closed(_ actions: [FlowAction]) -> Bool {
        actions.contains { if case .close = $0 { return true } else { return false } }
    }

    private func timers(_ actions: [FlowAction]) -> [(FlowTimer, Double)] {
        actions.compactMap { if case let .startTimer(t, s) = $0 { return (t, s) } else { return nil } }
    }

    private func payload(_ frame: Data) -> Data { Data(frame.dropFirst(5)) }

    // MARK: drivers

    /// Opens, delivers the host's challenge, and returns the response the flow sent.
    private func challenge(_ flow: inout ClientAuthFlow, _ h: HostHandshake) -> (actions: [FlowAction], response: Data?) {
        _ = flow.opened()
        let a = flow.received(type: challengeType, payload: h.challenge.payload)
        let response = sent(a).first { $0.first == StreamMessageType.authResponse.rawValue }.map(payload)
        return (a, response)
    }

    private struct Live {
        var flow: ClientAuthFlow
        var host: HostHandshake
        var hostSealer: SecureSealer
        var hostOpener: SecureOpener
        var up: [FlowAction]
    }

    /// A connection that went straight to accepted at a known host.
    private func live(url: String? = nil, caps: StreamCapabilities = [.relativeMouse, .extraButtons]) throws -> Live {
        var flow = ClientAuthFlow(config: config(url: url), known: known())
        let h = try host(caps: caps)
        let (_, response) = challenge(&flow, h)
        let device = try h.verify(responsePayload: try XCTUnwrap(response))
        let result = try h.result(.accepted, response: device.response, sign: hostSigner())
        let up = flow.received(type: resultType, payload: result)
        let keys = try h.sessionKeys(with: device)
        return Live(flow: flow, host: h, hostSealer: SecureSealer(key: keys.hostToClient),
                    hostOpener: SecureOpener(key: keys.clientToHost), up: up)
    }

    private func secure(_ l: inout Live, _ type: StreamMessageType, _ body: Data = Data()) throws -> Data {
        payload(try l.hostSealer.sealMessage(StreamMessage.frame(type: type, payload: body)))
    }

    // MARK: vectors

    private lazy var root: [String: Any] = {
        let u = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("vectors/auth-v1.json")
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: u)) as! [String: Any]
    }()

    private func hex(_ s: String) -> Data { Hex.decode(s)! }
    private func vstr(_ k: String) -> String { root[k] as! String }
    private func vpair(_ k: String) -> (priv: Data, pub: Data) {
        let d = root[k] as! [String: String]
        return (hex(d["private"]!), hex(d["public"]!))
    }
    private func vresult(_ k: String) -> Data { hex(((root["results"] as! [String: Any])[k] as! [String: Any])["payload"] as! String) }

    private func vectorFlow(known: Bool = true) throws -> ClientAuthFlow {
        let recorded = hex(vstr("clientSignature"))
        let e = root["responseExtension"] as! [String: Any]
        let ext = AuthExtension(type: UInt8((e["type"] as! NSNumber).intValue), value: hex(e["value"] as! String))
        let frame = helloFrame
        var c = ClientAuthConfig(deviceKey: vpair("deviceKey").pub, sign: { _ in recorded },
                                 deviceName: vstr("deviceName"), appVersion: "0.1.0", dialledURL: url,
                                 makeHello: { frame })
        c.capabilities = StreamCapabilities(rawValue: UInt32((root["clientCaps"] as! NSNumber).intValue))
        c.extensions = [ext]
        c.ephemeral = try P256.KeyAgreement.PrivateKey(rawRepresentation: vpair("clientEphemeral").priv)
        c.nonce = hex(vstr("clientNonce"))
        var k = KnownHosts()
        if known { k.recordVerified(key: vpair("hostIdentity").pub, name: "Studio", address: address, now: 1) }
        return ClientAuthFlow(config: c, known: k)
    }

    func testVectorResponseResultsAndSessionKeys() throws {
        var flow = try vectorFlow()
        _ = flow.opened()
        let a = flow.received(type: challengeType, payload: hex(vstr("challenge")))
        let responseFrame = try XCTUnwrap(sent(a).first)
        XCTAssertEqual(responseFrame.first, StreamMessageType.authResponse.rawValue)
        XCTAssertEqual(payload(responseFrame), hex(vstr("response")))
        XCTAssertTrue(timers(a).contains { $0.0 == .result && $0.1 == 15 })

        // The recorded pending result is verified and shows the waiting state.
        var pendingFlow = try vectorFlow()
        _ = pendingFlow.opened()
        _ = pendingFlow.received(type: challengeType, payload: hex(vstr("challenge")))
        let p = pendingFlow.received(type: resultType, payload: vresult("pending"))
        XCTAssertEqual(states(p), [.waitingForApproval(hostName: vstr("hostName"), hostFingerprint: vstr("hostFingerprint"),
                                                       deviceName: vstr("deviceName"), deviceFingerprint: vstr("deviceFingerprint"))])
        XCTAssertTrue(timers(p).contains { $0.0 == .pending && $0.1 == 60 })

        // Busy is verified too.
        var busyFlow = try vectorFlow()
        _ = busyFlow.opened()
        _ = busyFlow.received(type: challengeType, payload: hex(vstr("challenge")))
        let b = busyFlow.received(type: resultType, payload: vresult("busy"))
        XCTAssertEqual(end(b), .reconnect(after: 15, carry: FlowCarry(challengeWait: 2, busyDelay: 30, timeoutRetried: false)))

        // Accepted: the session keys are the vector's. The first sealed frame is
        // the vector's clientToHost frame for counter 0 (the same HELLO).
        let acc = flow.received(type: resultType, payload: vresult("accepted"))
        let frames = sent(acc)
        XCTAssertEqual(frames.count, 2)
        let vectors = root["secure"] as! [[String: Any]]
        let c2h0 = try XCTUnwrap(vectors.first { ($0["direction"] as! String) == "clientToHost" && ($0["counter"] as! NSNumber).intValue == 0 })
        XCTAssertEqual(frames[0], hex(c2h0["frame"] as! String))
        let key = SymmetricKey(data: hex(vstr("keyClientToHost")))
        var opener = SecureOpener(key: key)
        XCTAssertEqual(try opener.open(payload(frames[0])).type, StreamMessageType.hello.rawValue)
        XCTAssertEqual(try opener.open(payload(frames[1])).type, StreamMessageType.clientInfo.rawValue)

        // The vector's host frames open in order: HOST_INFO (kept), then a ping.
        let h2c = vectors.filter { ($0["direction"] as! String) == "hostToClient" }
        let first = flow.received(type: secureType, payload: payload(hex(h2c[0]["frame"] as! String)))
        XCTAssertTrue(first.isEmpty)
        let second = flow.received(type: secureType, payload: payload(hex(h2c[1]["frame"] as! String)))
        XCTAssertEqual(second, [.deliver(type: StreamMessageType.ping.rawValue, payload: Data())])
    }

    // MARK: accepted at once, round trip

    func testAcceptedAtOnceFromAKnownHostThenARoundTrip() throws {
        var l = try live(url: "ws://user:pw@192.168.1.20:5903/ws/a?x=1#f")
        // Capabilities come from the verified challenge.
        XCTAssertTrue(l.up.contains(.hostCapabilities([.relativeMouse, .extraButtons])))
        XCTAssertEqual(states(l.up), [.connected(verified: true, hostName: "Studio")])
        XCTAssertTrue(l.flow.isSecure)
        // HELLO first, inside SECURE, then CLIENT_INFO once.
        let frames = sent(l.up)
        XCTAssertEqual(frames.count, 2)
        XCTAssertTrue(frames.allSatisfy { $0.first == secureType })
        let hello = try l.hostOpener.open(payload(frames[0]))
        XCTAssertEqual(hello.type, StreamMessageType.hello.rawValue)
        XCTAssertEqual(hello.payload, Data([1, 2]))
        let info = try l.hostOpener.open(payload(frames[1]))
        XCTAssertEqual(info.type, StreamMessageType.clientInfo.rawValue)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: info.payload) as? [String: String])
        XCTAssertEqual(json["app"], "ios")
        XCTAssertEqual(json["version"], "0.1.0")
        XCTAssertEqual(json["url"], "ws://192.168.1.20:5903/ws/a")
        XCTAssertEqual(Set(json.keys), ["app", "version", "url"])

        // Client to host, in order.
        let key = StreamMessage.frame(type: .ping)
        let a1 = l.flow.send(key)
        let a2 = l.flow.send(key)
        XCTAssertEqual(try l.hostOpener.open(payload(sent(a1)[0])).type, StreamMessageType.ping.rawValue)
        XCTAssertEqual(try l.hostOpener.open(payload(sent(a2)[0])).type, StreamMessageType.ping.rawValue)

        // Host to client: HOST_INFO adds hints, other messages are handed on.
        let info2 = try secure(&l, .hostInfo, Data(#"{"name":"Studio","displays":[{"index":0,"urls":["ws://10.0.0.2:5903"]}]}"#.utf8))
        XCTAssertEqual(changes(l.flow.received(type: secureType, payload: info2)),
                       [.hints(hostId: DeviceIdentity.id(ofPublicKey: hostPub), urls: ["ws://10.0.0.2:5903"])])
        let ping = try secure(&l, .ping)
        XCTAssertEqual(l.flow.received(type: secureType, payload: ping),
                       [.deliver(type: StreamMessageType.ping.rawValue, payload: Data())])

        // The connection ending clears the host's capabilities.
        XCTAssertTrue(l.flow.socketClosed().contains(.hostCapabilities([])))
    }

    func testClientOffersOnlyTheBitsTheAppHonours() throws {
        var flow = ClientAuthFlow(config: config(), known: known())
        let (_, response) = challenge(&flow, try host())
        let hello = try AuthResponse.decode(try XCTUnwrap(response)).hello
        XCTAssertEqual(hello.capabilities, [.relativeMouse, .textInput, .extraButtons])
        XCTAssertFalse(hello.capabilities.contains(.deviceApproval))
        XCTAssertFalse(hello.capabilities.contains(.fileTransfer))
        XCTAssertFalse(hello.capabilities.contains(.peripherals))
        XCTAssertEqual(hello.displayName, "Example iPad")
        XCTAssertEqual(hello.identityKey, devicePub)
    }

    func testEmptyDeviceNameFallsBack() throws {
        var flow = ClientAuthFlow(config: config(name: "\u{200B}\n"), known: known())
        let (_, response) = challenge(&flow, try host())
        XCTAssertEqual(try AuthResponse.decode(try XCTUnwrap(response)).hello.displayName, "iPad")
    }

    // MARK: pending

    func testPendingRepeatedPendingThenAccepted() throws {
        var flow = ClientAuthFlow(config: config(), known: KnownHosts())
        let h = try host()
        let (_, response) = challenge(&flow, h)
        let device = try h.verify(responsePayload: try XCTUnwrap(response))
        let pending = try h.result(.pending, response: device.response, sign: hostSigner())
        let hostId = DeviceIdentity.id(ofPublicKey: hostPub)
        let shown = FlowState.waitingForApproval(hostName: "Studio", hostFingerprint: DeviceIdentity.fingerprint(ofId: hostId),
                                                 deviceName: "Example iPad", deviceFingerprint: flow.deviceFingerprint)
        let first = flow.received(type: resultType, payload: pending)
        XCTAssertEqual(states(first), [shown])
        XCTAssertTrue(sent(first).isEmpty)
        // The host repeats the identical bytes every 20 s: each is accepted.
        let again = flow.received(type: resultType, payload: pending)
        XCTAssertEqual(states(again), [shown])
        XCTAssertTrue(timers(again).contains { $0.0 == .pending && $0.1 == 60 })
        XCTAssertNil(end(again))
        // Then accepted: remembered, session up.
        let accepted = try h.result(.accepted, response: device.response, sign: hostSigner())
        let up = flow.received(type: resultType, payload: accepted)
        XCTAssertEqual(changes(up), [.recordVerified(key: hostPub, name: "Studio", address: url)])
        XCTAssertTrue(flow.isSecure)
        XCTAssertEqual(sent(up).count, 2)
    }

    func testNoResultFor60SecondsReconnects() throws {
        var flow = ClientAuthFlow(config: config(), known: KnownHosts())
        let h = try host()
        let (_, response) = challenge(&flow, h)
        let device = try h.verify(responsePayload: try XCTUnwrap(response))
        _ = flow.received(type: resultType, payload: try h.result(.pending, response: device.response, sign: hostSigner()))
        let a = flow.timerFired(.pending)
        XCTAssertEqual(end(a), .reconnect(after: 0, carry: FlowCarry()))
        XCTAssertTrue(sent(a).isEmpty)
    }

    func testNoResultWithin15SecondsIsAFailedConnection() throws {
        var flow = ClientAuthFlow(config: config(), known: known())
        _ = challenge(&flow, try host())
        XCTAssertEqual(end(flow.timerFired(.result)), .failure)
    }

    // MARK: rules that refuse or close

    func testChangedIdentityClosesAndSendsNothing() throws {
        let other = P256.Signing.PrivateKey().publicKey.x963Representation
        var flow = ClientAuthFlow(config: config(), known: known(key: other))
        _ = flow.opened()
        let a = flow.received(type: challengeType, payload: try host().challenge.payload)
        XCTAssertTrue(sent(a).isEmpty)
        XCTAssertEqual(end(a), .stop)
        XCTAssertEqual(states(a), [.changedIdentity(address: address,
                                                    savedFingerprint: DeviceIdentity.fingerprint(ofPublicKey: other),
                                                    nowFingerprint: DeviceIdentity.fingerprint(ofPublicKey: hostPub))])
        XCTAssertTrue(changes(a).isEmpty)
        XCTAssertTrue(flow.isEnded)
    }

    // MARK: an address the client chose itself falls through

    private func chosen(key: Data? = nil, falls: Bool) -> ClientAuthFlow {
        var c = config()
        c.fallsThrough = falls
        return ClientAuthFlow(config: c, known: known(key: key))
    }

    func testAnUnknownKeyAtAnAddressTheClientChoseMovesOnAndKeepsTheAlarm() throws {
        let other = P256.Signing.PrivateKey().publicKey.x963Representation
        var flow = chosen(key: other, falls: true)
        _ = flow.opened()
        let a = flow.received(type: challengeType, payload: try host().challenge.payload)
        XCTAssertTrue(sent(a).isEmpty)
        XCTAssertTrue(changes(a).isEmpty)
        XCTAssertEqual(end(a), .nextAddress)
        XCTAssertEqual(states(a), [.changedIdentity(address: address,
                                                    savedFingerprint: DeviceIdentity.fingerprint(ofPublicKey: other),
                                                    nowFingerprint: DeviceIdentity.fingerprint(ofPublicKey: hostPub))])
        XCTAssertTrue(flow.isEnded)
    }

    func testNoChallengeAtAnAddressTheClientChoseMovesOnAndKeepsTheAlarm() throws {
        var flow = chosen(falls: true)
        _ = flow.opened()
        let a = flow.timerFired(.challenge)
        XCTAssertTrue(sent(a).isEmpty)
        XCTAssertEqual(states(a), [.didNotIdentify(hostName: "Studio")])
        XCTAssertEqual(end(a), .nextAddress)
    }

    func testTheAddressTheUserPickedStillStopsWithTheAlarm() throws {
        let other = P256.Signing.PrivateKey().publicKey.x963Representation
        var key = chosen(key: other, falls: false)
        _ = key.opened()
        XCTAssertEqual(end(key.received(type: challengeType, payload: try host().challenge.payload)), .stop)
        var silent = chosen(falls: false)
        _ = silent.opened()
        XCTAssertEqual(end(silent.timerFired(.challenge)), .stop)
    }

    func testSilentKnownHostIsRefusedWithoutAClearHello() throws {
        var flow = ClientAuthFlow(config: config(), known: known())
        let opened = flow.opened()
        XCTAssertTrue(sent(opened).isEmpty)
        XCTAssertEqual(timers(opened).first?.0, .challenge)
        XCTAssertEqual(timers(opened).first?.1, 2)
        let a = flow.timerFired(.challenge)
        XCTAssertTrue(sent(a).isEmpty)
        XCTAssertEqual(states(a), [.didNotIdentify(hostName: "Studio")])
        XCTAssertEqual(end(a), .stop)
    }

    func testSilentUnknownHostAsksThenSendsAClearHelloOnlyOnYes() throws {
        var no = ClientAuthFlow(config: config(), known: KnownHosts())
        _ = no.opened()
        let ask = no.timerFired(.challenge)
        XCTAssertEqual(states(ask), [.askUnverified(address: address)])
        XCTAssertTrue(sent(ask).isEmpty)
        let declined = no.answered(false)
        XCTAssertTrue(sent(declined).isEmpty)
        XCTAssertEqual(end(declined), .stop)

        var yes = ClientAuthFlow(config: config(), known: KnownHosts())
        _ = yes.opened()
        _ = yes.timerFired(.challenge)
        let go = yes.answered(true)
        XCTAssertEqual(sent(go), [helloFrame])
        XCTAssertEqual(changes(go), [.allowUnverified(address: address)])
        XCTAssertEqual(states(go), [.connected(verified: false, hostName: "")])
        XCTAssertTrue(go.contains(.hostCapabilities([])))
        // In this session messages go in the clear, both ways.
        let msg = StreamMessage.frame(type: .ping)
        XCTAssertEqual(sent(yes.send(msg)), [msg])
        XCTAssertEqual(yes.received(type: StreamMessageType.helloAck.rawValue, payload: Data([1])),
                       [.deliver(type: StreamMessageType.helloAck.rawValue, payload: Data([1]))])
        // A result, SECURE or response in the clear is not accepted here.
        XCTAssertEqual(end(yes.received(type: resultType, payload: Data())), .failure)
    }

    func testAnUnknownAddressTheUserAllowedBeforeDoesNotAskAgain() throws {
        var k = KnownHosts()
        k.allowUnverified(address: url)
        var flow = ClientAuthFlow(config: config(), known: k)
        _ = flow.opened()
        let a = flow.timerFired(.challenge)
        XCTAssertEqual(sent(a), [helloFrame])
        XCTAssertFalse(states(a).contains { if case .askUnverified = $0 { return true } else { return false } })
    }

    func testLateChallengeAfterAClearHelloReconnectsWaiting10Seconds() throws {
        var flow = ClientAuthFlow(config: config(), known: KnownHosts())
        _ = flow.opened()
        _ = flow.timerFired(.challenge)
        _ = flow.answered(true)
        let a = flow.received(type: challengeType, payload: try host().challenge.payload)
        XCTAssertTrue(sent(a).isEmpty)
        guard case let .reconnect(after, carry)? = end(a) else { return XCTFail("expected a reconnect") }
        XCTAssertEqual(after, 0)
        XCTAssertEqual(carry.challengeWait, 10)
        var again = ClientAuthFlow(config: config(), known: KnownHosts(), carry: carry)
        XCTAssertEqual(timers(again.opened()).first?.1, 10)
    }

    func testAResultWithABadSignatureIsAFailedConnection() throws {
        for status in [AuthStatus.accepted, .pending, .denied, .busy] {
            var flow = ClientAuthFlow(config: config(), known: known())
            let h = try host()
            let (_, response) = challenge(&flow, h)
            let device = try h.verify(responsePayload: try XCTUnwrap(response))
            let forged = try h.result(status, response: device.response, sign: AuthSignature.signer(P256.Signing.PrivateKey()))
            let a = flow.received(type: resultType, payload: forged)
            XCTAssertEqual(end(a), .failure, "\(status)")
            XCTAssertTrue(sent(a).isEmpty)
            XCTAssertTrue(changes(a).isEmpty)
            XCTAssertFalse(flow.isSecure)
        }
    }

    func testDeniedAndInvalidStopAndSayWhy() throws {
        for (status, shown) in [(AuthStatus.denied, FlowState.denied(hostName: "Studio")),
                                (.invalid, FlowState.invalid(hostName: "Studio"))] {
            var flow = ClientAuthFlow(config: config(), known: known())
            let h = try host()
            let (_, response) = challenge(&flow, h)
            let device = try h.verify(responsePayload: try XCTUnwrap(response))
            let a = flow.received(type: resultType, payload: try h.result(status, response: device.response, sign: hostSigner()))
            XCTAssertEqual(states(a), [shown])
            XCTAssertEqual(end(a), .stop)
        }
    }

    func testBusyBacksOffFrom15SecondsToTwoMinutes() throws {
        var carry = FlowCarry()
        var delays: [Double] = []
        for _ in 0 ..< 5 {
            var flow = ClientAuthFlow(config: config(), known: known(), carry: carry)
            let h = try host()
            let (_, response) = challenge(&flow, h)
            let device = try h.verify(responsePayload: try XCTUnwrap(response))
            let a = flow.received(type: resultType, payload: try h.result(.busy, response: device.response, sign: hostSigner()))
            guard case let .reconnect(after, next)? = end(a) else { return XCTFail("expected a reconnect") }
            XCTAssertEqual(states(a), [.busy(retryIn: Int(after))])
            delays.append(after)
            carry = next
        }
        XCTAssertEqual(delays, [15, 30, 60, 120, 120])
    }

    func testBusyWithAReasonShowsTheReason() throws {
        let cases: [(HostBusyReason, (Int) -> FlowState)] = [
            (.keychain, { .hostNeedsKeychain(retryIn: $0) }),
            (.remoteAccessOff, { .remoteAccessOff(retryIn: $0) }),
        ]
        for (reason, expected) in cases {
            var flow = ClientAuthFlow(config: config(), known: known(), carry: FlowCarry())
            let h = try host()
            let (_, response) = challenge(&flow, h)
            let device = try h.verify(responsePayload: try XCTUnwrap(response))
            let payload = try h.result(.busy, response: device.response, extensions: [reason.authExtension],
                                       sign: hostSigner())
            let a = flow.received(type: resultType, payload: payload)
            guard case let .reconnect(after, _)? = end(a) else { return XCTFail("expected a reconnect") }
            XCTAssertEqual(states(a), [expected(Int(after))])
        }
    }

    func testBusyReasonIsIgnoredOnOtherStatusesAndWhenUnknown() throws {
        var flow = ClientAuthFlow(config: config(), known: known(), carry: FlowCarry())
        let h = try host()
        let (_, response) = challenge(&flow, h)
        let device = try h.verify(responsePayload: try XCTUnwrap(response))
        // A reason value this client does not know is plain busy.
        let unknown = AuthExtension(type: HostBusyReason.extensionType, value: Data([0x7f]))
        let a = flow.received(type: resultType, payload: try h.result(.busy, response: device.response,
                                                                      extensions: [unknown], sign: hostSigner()))
        guard case let .reconnect(after, _)? = end(a) else { return XCTFail("expected a reconnect") }
        XCTAssertEqual(states(a), [.busy(retryIn: Int(after))])
        XCTAssertNil(HostBusyReason.find(in: []))
        XCTAssertEqual(HostBusyReason.find(in: [HostBusyReason.keychain.authExtension]), .keychain)
    }

    func testTimeoutReconnectsAtOnceOnceThenLikeBusy() throws {
        var carry = FlowCarry()
        var delays: [Double] = []
        for _ in 0 ..< 3 {
            var flow = ClientAuthFlow(config: config(), known: known(), carry: carry)
            let h = try host()
            let (_, response) = challenge(&flow, h)
            let device = try h.verify(responsePayload: try XCTUnwrap(response))
            let a = flow.received(type: resultType, payload: try h.result(.timeout, response: device.response, sign: hostSigner()))
            guard case let .reconnect(after, next)? = end(a) else { return XCTFail("expected a reconnect") }
            delays.append(after)
            carry = next
        }
        XCTAssertEqual(delays, [0, 15, 30])
    }

    func testAClearMessageAfterAcceptedClosesTheConnection() throws {
        var l = try live()
        let a = l.flow.received(type: StreamMessageType.ping.rawValue, payload: Data())
        XCTAssertEqual(end(a), .failure)
        XCTAssertTrue(a.contains(.hostCapabilities([])))
        XCTAssertTrue(l.flow.isEnded)
    }

    func testASecureMessageThatFailsToOpenClosesTheConnection() throws {
        var l = try live()
        var bad = try secure(&l, .ping)
        bad[bad.startIndex] ^= 0x01
        XCTAssertEqual(end(l.flow.received(type: secureType, payload: bad)), .failure)
    }

    func testASecureMessageReplayedOrOutOfOrderClosesTheConnection() throws {
        var l = try live()
        _ = try secure(&l, .ping) // counter 0 is never delivered
        let second = try secure(&l, .ping)
        XCTAssertEqual(end(l.flow.received(type: secureType, payload: second)), .failure)
        XCTAssertTrue(l.flow.isEnded)
    }

    func testAForbiddenInnerTypeClosesTheConnection() throws {
        for forbidden in [StreamMessageType.secure, .authChallenge, .authResponse, .authResult] {
            // The sealer itself refuses these, so seal by hand with the session key.
            let inner = StreamMessage.frame(type: forbidden, payload: Data([1]))
            var refusing = try live()
            XCTAssertThrowsError(try refusing.hostSealer.seal(inner))
            let h = try host()
            var flow = ClientAuthFlow(config: config(), known: known())
            let (_, response) = challenge(&flow, h)
            let device = try h.verify(responsePayload: try XCTUnwrap(response))
            _ = flow.received(type: resultType, payload: try h.result(.accepted, response: device.response, sign: hostSigner()))
            let k = try h.sessionKeys(with: device)
            let box = try AES.GCM.seal(inner, using: k.hostToClient, nonce: AES.GCM.Nonce(data: SecureFrame.nonce(0)))
            XCTAssertEqual(end(flow.received(type: secureType, payload: box.ciphertext + box.tag)), .failure, "\(forbidden)")
        }
    }

    func testBeforeAcceptedOnlyOneChallengeThenResultsAreTaken() throws {
        let ping = StreamMessageType.ping.rawValue
        let h = try host()

        // Anything but a challenge before the challenge.
        for type in [ping, resultType, secureType, StreamMessageType.helloAck.rawValue, StreamMessageType.hostInfo.rawValue] {
            var flow = ClientAuthFlow(config: config(), known: known())
            _ = flow.opened()
            let a = flow.received(type: type, payload: Data())
            XCTAssertEqual(end(a), .failure, "type \(type)")
            XCTAssertTrue(sent(a).isEmpty)
        }
        // A second challenge, a ping, or a SECURE message while waiting for the result.
        for type in [challengeType, ping, secureType] {
            var flow = ClientAuthFlow(config: config(), known: known())
            _ = challenge(&flow, h)
            XCTAssertEqual(end(flow.received(type: type, payload: h.challenge.payload)), .failure, "type \(type)")
        }
        // The same while the host says pending.
        var flow = ClientAuthFlow(config: config(), known: KnownHosts())
        let (_, response) = challenge(&flow, h)
        let device = try h.verify(responsePayload: try XCTUnwrap(response))
        _ = flow.received(type: resultType, payload: try h.result(.pending, response: device.response, sign: hostSigner()))
        XCTAssertEqual(end(flow.received(type: ping, payload: Data())), .failure)
    }

    func testAChallengeWithAnInvalidKeyOrVersionIsAFailedConnection() throws {
        var bad = try host().challenge.payload
        bad[bad.startIndex] = 9 // version
        var flow = ClientAuthFlow(config: config(), known: KnownHosts())
        _ = flow.opened()
        let a = flow.received(type: challengeType, payload: bad)
        XCTAssertEqual(end(a), .failure)
        XCTAssertTrue(sent(a).isEmpty)

        var flow2 = ClientAuthFlow(config: config(), known: KnownHosts())
        _ = flow2.opened()
        XCTAssertEqual(end(flow2.received(type: challengeType, payload: Data([1, 2, 3]))), .failure)
    }

    // MARK: rule 12 and binding

    func testAHostNotMetBeforeThatLetsUsInIsAskedAboutFirst() throws {
        var flow = ClientAuthFlow(config: config(), known: KnownHosts())
        let h = try host()
        let (_, response) = challenge(&flow, h)
        let device = try h.verify(responsePayload: try XCTUnwrap(response))
        let a = flow.received(type: resultType, payload: try h.result(.accepted, response: device.response, sign: hostSigner()))
        // Nothing is sent and nothing is remembered before the user's yes.
        XCTAssertTrue(sent(a).isEmpty)
        XCTAssertTrue(changes(a).isEmpty)
        XCTAssertTrue(closed(a))
        XCTAssertFalse(a.contains { if case .hostCapabilities = $0 { return true } else { return false } })
        XCTAssertEqual(states(a), [.confirmHost(hostName: "Studio", fingerprint: DeviceIdentity.fingerprint(ofPublicKey: hostPub))])
        XCTAssertFalse(flow.isSecure)
        // The socket closing is the close we asked for, not a new event.
        XCTAssertTrue(flow.socketClosed().isEmpty)
        XCTAssertTrue(flow.send(StreamMessage.frame(type: .ping)).isEmpty)

        var no = flow
        let declined = no.answered(false)
        XCTAssertTrue(changes(declined).isEmpty)
        XCTAssertTrue(sent(declined).isEmpty)
        XCTAssertEqual(end(declined), .stop)

        let yes = flow.answered(true)
        XCTAssertEqual(changes(yes), [.recordVerified(key: hostPub, name: "Studio", address: url)])
        XCTAssertTrue(sent(yes).isEmpty)
        XCTAssertEqual(end(yes), .reconnect(after: 0, carry: FlowCarry()))
    }

    func testAKnownKeyAtANewAddressIsBoundWithoutAsking() throws {
        var flow = ClientAuthFlow(config: config(url: "wss://mac.example.com/ws/a"), known: known(address: "10.0.0.9:5903"))
        let h = try host()
        let (_, response) = challenge(&flow, h)
        let device = try h.verify(responsePayload: try XCTUnwrap(response))
        let a = flow.received(type: resultType, payload: try h.result(.pending, response: device.response, sign: hostSigner()))
        XCTAssertEqual(changes(a), [.bind(hostId: DeviceIdentity.id(ofPublicKey: hostPub), address: "wss://mac.example.com/ws/a")])
        XCTAssertTrue(sent(a).isEmpty)
    }

    // MARK: an address that now reaches a different saved Mac

    /// Two saved Macs; the address of the first now reaches the second.
    private func swapped(expected: String? = nil) throws -> (flow: ClientAuthFlow, actions: [FlowAction], otherId: String) {
        let otherKey = P256.Signing.PrivateKey()
        let otherPub = otherKey.publicKey.x963Representation
        var k = known()
        k.recordVerified(key: otherPub, name: "Other Mac", address: "192.168.1.21:5903", now: 2)
        var c = config()
        c.expectedHostId = expected
        var flow = ClientAuthFlow(config: c, known: k)
        let h = try HostHandshake(identityKey: otherPub, capabilities: [.relativeMouse], name: "Other Mac")
        let (_, response) = challenge(&flow, h)
        let device = try h.verify(responsePayload: try XCTUnwrap(response))
        let result = try h.result(.accepted, response: device.response, sign: AuthSignature.signer(otherKey))
        // The actions first: the flow is a value, and the copy returned with
        // them has to be the one the result was fed to.
        let actions = flow.received(type: resultType, payload: result)
        return (flow, actions, DeviceIdentity.id(ofPublicKey: otherPub))
    }

    func testAnAddressThatNowReachesADifferentSavedMacIsNotASuccess() throws {
        var s = try swapped()
        // The address moves to the Mac that answered, and the attempt ends so
        // the caller can try the next address. No session, no HELLO.
        XCTAssertEqual(changes(s.actions), [.bind(hostId: s.otherId, address: url)])
        XCTAssertEqual(states(s.actions), [.failed("This address now reaches Other Mac")])
        XCTAssertEqual(end(s.actions), .nextAddress)
        XCTAssertTrue(sent(s.actions).isEmpty)
        XCTAssertFalse(s.flow.isSecure)
        XCTAssertTrue(s.flow.isEnded)
        XCTAssertTrue(s.flow.socketClosed().isEmpty)
    }

    func testThePickedMacCountsEvenWhenTheAddressWasMovedAlready() throws {
        // The caller says it picked the first Mac (its pick is kept across
        // attempts even after the address moved). Still not a success.
        let firstId = DeviceIdentity.id(ofPublicKey: hostPub)
        let s = try swapped(expected: firstId)
        XCTAssertEqual(end(s.actions), .nextAddress)
        XCTAssertEqual(states(s.actions), [.failed("This address now reaches Other Mac")])
    }

    func testTheSameMacAtTheSameAddressStillConnects() throws {
        let l = try live()
        XCTAssertEqual(states(l.up), [.connected(verified: true, hostName: "Studio")])
        XCTAssertTrue(l.flow.isSecure)
    }

    func testNothingTheAppSendsBeforeAcceptedGoesOut() throws {
        var flow = ClientAuthFlow(config: config(), known: KnownHosts())
        let key = StreamMessage.frame(type: .ping)
        XCTAssertTrue(flow.send(key).isEmpty)
        let h = try host()
        let (_, response) = challenge(&flow, h)
        XCTAssertTrue(flow.send(key).isEmpty)
        let device = try h.verify(responsePayload: try XCTUnwrap(response))
        _ = flow.received(type: resultType, payload: try h.result(.pending, response: device.response, sign: hostSigner()))
        XCTAssertTrue(flow.send(key).isEmpty)
    }

    func testAChallengeThatArrivesBeforeTheOpenEventIsStillAnswered() throws {
        var flow = ClientAuthFlow(config: config(), known: known())
        let h = try host()
        // No opened() first: the socket's open callback has not run yet.
        let a = flow.received(type: challengeType, payload: h.challenge.payload)
        let response = try XCTUnwrap(sent(a).first { $0.first == StreamMessageType.authResponse.rawValue })
        _ = try h.verify(responsePayload: payload(response))
        XCTAssertNil(end(a))
        XCTAssertFalse(flow.isEnded)
        // The late open event changes nothing and sends nothing.
        XCTAssertTrue(flow.opened().isEmpty)
        // The result still works.
        let device = try h.verify(responsePayload: payload(response))
        let up = flow.received(type: resultType, payload: try h.result(.accepted, response: device.response, sign: hostSigner()))
        XCTAssertTrue(flow.isSecure)
        XCTAssertEqual(states(up), [.connected(verified: true, hostName: "Studio")])
    }

    func testAnythingElseBeforeTheOpenEventIsStillIgnored() throws {
        var flow = ClientAuthFlow(config: config(), known: known())
        XCTAssertTrue(flow.received(type: StreamMessageType.ping.rawValue, payload: Data()).isEmpty)
        XCTAssertTrue(flow.received(type: resultType, payload: Data(count: 70)).isEmpty)
        XCTAssertFalse(flow.isEnded)
    }

    func testTheClientSendsNothingWhenTheSocketOpens() throws {
        var flow = ClientAuthFlow(config: config(), known: known())
        let a = flow.opened()
        XCTAssertTrue(sent(a).isEmpty)
        XCTAssertEqual(timers(a).count, 1)
    }

    func testHostInfoNeverChangesTheExpectedKey() throws {
        var l = try live()
        let hostile = Data(#"{"hostId":"\#(String(repeating: "a", count: 64))","displays":[{"urls":["ws://evil.example:5903"]}]}"#.utf8)
        let a = l.flow.received(type: secureType, payload: try secure(&l, .hostInfo, hostile))
        // Only a hint for the key the handshake verified.
        XCTAssertEqual(changes(a), [.hints(hostId: DeviceIdentity.id(ofPublicKey: hostPub), urls: ["ws://evil.example:5903"])])
        XCTAssertTrue(l.flow.isSecure)
    }
}
