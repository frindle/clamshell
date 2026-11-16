import CoreGraphics
import CryptoKit
import Foundation

// Selftest for the door in front of the stream listeners (StreamLink.swift):
// two real listeners on this machine's loopback address, real WebSocket
// clients, and a device list in a temporary directory.
//
// It checks who gets in, and that a connection which has not got in starts
// nothing and cannot disturb the client being served. It captures nothing and
// types nothing: the listeners are not primary, and no client sends a HELLO
// long enough to start a session.
//
// `clamshell auth-gate-selftest`, run in CI.

enum AuthGateSelfTest {
    private struct Failure: Error {
        let what: String
        init(_ what: String) { self.what = what }
    }

    /// How long to wait for something that should happen.
    private static let wait: TimeInterval = 15
    /// Display 0 and display 1 of the host under test.
    private static let port0: UInt16 = 5996
    private static let port1: UInt16 = 5995

    private static func expect(_ ok: Bool, _ what: String) throws {
        if !ok { throw Failure("expected that \(what)") }
    }

    private struct Device {
        let key = P256.Signing.PrivateKey()
        let name: String
        var publicKey: Data { key.publicKey.x963Representation }
        var id: String { DeviceIdentity.id(ofPublicKey: publicKey) }
    }

    // MARK: - A client

    /// One WebSocket client. What the host sends queues up as it arrives; the
    /// test reads it in order from its own thread.
    private final class Client: @unchecked Sendable {
        enum Event {
            case message(StreamMessageType, Data)
            case unknown(UInt8)
            case closed
        }

        let label: String
        private let hostKey: Data
        /// One session per client: several clients wait on one listener at
        /// once, and a shared session limits connections to one host.
        private let session = URLSession(configuration: .ephemeral)
        private let task: URLSessionWebSocketTask
        private let parser = StreamMessageParser()
        private let condition = NSCondition()
        private var events: [Event] = []
        private var isClosed = false

        // The handshake and the session, used from the test thread only.
        private var challenge: AuthChallenge?
        private var handshake: ClientHandshake?
        /// The AUTH_RESPONSE as it was sent, which the host's signature covers.
        private(set) var sentResponse = Data()
        private var sealer: SecureSealer?
        private var opener: SecureOpener?

        init(port: UInt16, label: String, hostKey: Data) {
            self.label = label
            self.hostKey = hostKey
            task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
            task.maximumMessageSize = 8 << 20
            parser.onMessage = { [weak self] type, payload in self?.push(.message(type, payload)) }
            parser.onUnknown = { [weak self] type in self?.push(.unknown(type)) }
            task.resume()
            receive()
        }

        private func receive() {
            task.receive { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(.data(let data)):
                    self.parser.feed(data)
                    self.receive()
                case .success:
                    self.receive()
                case .failure:
                    self.push(.closed)
                }
            }
        }

        private func push(_ event: Event) {
            condition.lock()
            if case .closed = event { isClosed = true } else { events.append(event) }
            condition.broadcast()
            condition.unlock()
        }

        /// The next thing the host sent, or nil when nothing arrives in time.
        /// Once the connection has closed and everything before that was read,
        /// every call says `closed`.
        func next(within seconds: TimeInterval) -> Event? {
            let deadline = Date().addingTimeInterval(seconds)
            condition.lock()
            defer { condition.unlock() }
            while events.isEmpty && !isClosed {
                guard condition.wait(until: deadline) else { break }
            }
            if !events.isEmpty { return events.removeFirst() }
            return isClosed ? .closed : nil
        }

        static func describe(_ event: Event?) -> String {
            switch event {
            case nil: return "nothing"
            case .closed?: return "the connection closing"
            case .unknown(let type)?: return "a message of unknown type \(type)"
            case .message(let type, let payload)?: return "\(type) (\(payload.count) bytes)"
            }
        }

        /// Returns once the bytes are written, so messages go out in the
        /// order they were sent.
        func send(_ data: Data) {
            let sent = DispatchSemaphore(value: 0)
            task.send(.data(data)) { _ in sent.signal() }
            _ = sent.wait(timeout: .now() + AuthGateSelfTest.wait)
        }

        func close() {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        // MARK: the handshake

        var hostCapabilities: StreamCapabilities { challenge?.hello.capabilities ?? [] }

        /// The challenge, which is the first thing a host sends.
        @discardableResult
        func readChallenge() throws -> AuthChallenge {
            let event = next(within: AuthGateSelfTest.wait)
            guard case .message(.authChallenge, let payload)? = event else {
                throw Failure("\(label): expected the challenge first, got \(Self.describe(event))")
            }
            guard let decoded = try? AuthChallenge.decode(payload) else {
                throw Failure("\(label): the challenge does not decode")
            }
            guard decoded.hello.identityKey == hostKey else {
                throw Failure("\(label): the challenge names a key that is not this host's")
            }
            challenge = decoded
            return decoded
        }

        /// Answers the challenge the way a real client does.
        func answer(as device: Device, capabilities: StreamCapabilities = []) throws {
            guard let challenge else { throw Failure("\(label): no challenge to answer") }
            let made = try ClientHandshake(challengePayload: challenge.payload, deviceKey: device.publicKey,
                                           capabilities: capabilities, name: device.name,
                                           sign: AuthSignature.signer(device.key))
            handshake = made
            sendResponse(made.response)
        }

        /// Sends these bytes as the AUTH_RESPONSE, whatever they are.
        func sendResponse(_ response: Data) {
            sentResponse = response
            send(StreamMessage.frame(type: .authResponse, payload: response))
        }

        /// The status of a result, after checking by hand that this host
        /// signed it over this connection's challenge and response.
        private func checkedStatus(_ payload: Data) throws -> AuthStatus {
            guard let challenge else { throw Failure("\(label): a result arrived before the challenge was read") }
            guard let result = try? AuthResult.decode(payload) else {
                throw Failure("\(label): the result does not decode")
            }
            let covered = result.status.signsEmptyResponse ? Data() : sentResponse
            let input = AuthWire.hostSignatureInput(challenge: challenge.payload, response: covered,
                                                    resultBody: result.body)
            guard AuthSignature.verify(result.signature, over: input, publicKey: hostKey) else {
                throw Failure("\(label): the \(result.status) result is not signed by this host over this handshake")
            }
            return result.status
        }

        /// The next message must be a result with this status.
        func expectStatus(_ status: AuthStatus, skippingPending: Bool = false) throws {
            while true {
                let event = next(within: AuthGateSelfTest.wait)
                guard case .message(.authResult, let payload)? = event else {
                    throw Failure("\(label): expected the result \(status), got \(Self.describe(event))")
                }
                let got = try checkedStatus(payload)
                if got == .pending, skippingPending, status != .pending { continue }
                guard got == status else { throw Failure("\(label): expected the result \(status), got \(got)") }
                return
            }
        }

        /// Reads for `seconds`; everything that arrives must be a signed
        /// `pending`. Returns how many arrived.
        func onlyPending(for seconds: TimeInterval) throws -> Int {
            let end = Date().addingTimeInterval(seconds)
            var count = 0
            while true {
                let left = end.timeIntervalSinceNow
                guard left > 0, let event = next(within: left) else { return count }
                guard case .message(.authResult, let payload) = event, try checkedStatus(payload) == .pending else {
                    throw Failure("\(label): while it waited for approval the host sent \(Self.describe(event))")
                }
                count += 1
            }
        }

        func expectNothing(for seconds: TimeInterval, _ why: String) throws {
            if let event = next(within: seconds) {
                throw Failure("\(label): \(why), but the host sent \(Self.describe(event))")
            }
        }

        /// The host must close the connection, and send nothing first (apart
        /// from repeats of `pending`, where those are allowed).
        func expectClosed(_ why: String, allowingPending: Bool = false) throws {
            while true {
                let event = next(within: AuthGateSelfTest.wait)
                if case .closed? = event { return }
                if allowingPending, case .message(.authResult, let payload)? = event,
                   (try? AuthResult.decode(payload))?.status == .pending { continue }
                throw Failure("\(label): expected the host to close the connection (\(why)), got \(Self.describe(event))")
            }
        }

        /// The next message must be this one, in the clear.
        @discardableResult
        func expectClear(_ type: StreamMessageType) throws -> Data {
            let event = next(within: AuthGateSelfTest.wait)
            guard case .message(let got, let payload)? = event, got == type else {
                throw Failure("\(label): expected \(type) in the clear, got \(Self.describe(event))")
            }
            return payload
        }

        // MARK: the encrypted session

        /// One session message, encrypted and framed, not yet sent.
        func seal(_ type: StreamMessageType, _ payload: Data = Data()) throws -> Data {
            guard var sealer else { throw Failure("\(label): no session to send on") }
            defer { self.sealer = sealer }
            return try sealer.sealMessage(StreamMessage.frame(type: type, payload: payload))
        }

        func sendSecure(_ type: StreamMessageType, _ payload: Data = Data()) throws {
            send(try seal(type, payload))
        }

        /// The next message must be an encrypted one of this type. Returns
        /// what was inside.
        @discardableResult
        func expectSecure(_ type: StreamMessageType) throws -> Data {
            let event = next(within: AuthGateSelfTest.wait)
            guard case .message(.secure, let payload)? = event else {
                throw Failure("\(label): expected an encrypted \(type), got \(Self.describe(event))")
            }
            guard var opener else { throw Failure("\(label): no session to read on") }
            defer { self.opener = opener }
            let inner: (type: UInt8, payload: Data)
            do {
                inner = try opener.open(payload)
            } catch {
                throw Failure("\(label): an encrypted message from the host did not open (\(error))")
            }
            guard inner.type == type.rawValue else {
                throw Failure("\(label): expected an encrypted \(type), got type \(inner.type) inside")
            }
            return inner.payload
        }

        private func object(_ payload: Data, _ what: String) throws -> [String: Any] {
            guard let parsed = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
                throw Failure("\(label): \(what) is not a JSON object")
            }
            return parsed
        }

        /// Starts the session after `accepted`: HOST_INFO must be the first
        /// thing in it, and must name this host and the display asked for.
        func beginSession(display: Int) throws {
            guard let handshake else { throw Failure("\(label): no handshake to start a session from") }
            let keys = try handshake.sessionKeys()
            sealer = SecureSealer(key: keys.clientToHost)
            opener = SecureOpener(key: keys.hostToClient)
            let info = try object(try expectSecure(.hostInfo), "HOST_INFO")
            guard info["hostId"] as? String == DeviceIdentity.id(ofPublicKey: hostKey),
                  info["kind"] as? String == "mac", info["display"] as? Int == display else {
                throw Failure("\(label): HOST_INFO does not name this host and display \(display): \(info)")
            }
        }

        /// A keepalive goes out encrypted and its echo is the next message.
        func expectPing() throws {
            try sendSecure(.ping)
            guard try expectSecure(.ping).isEmpty else { throw Failure("\(label): the keepalive echo carries data") }
        }

        /// The next message must be DEVICE_PENDING listing exactly these
        /// devices, oldest first.
        func expectWaitingList(_ devices: [Device]) throws {
            let list = try object(try expectSecure(.devicePending), "DEVICE_PENDING")["devices"] as? [[String: Any]]
            guard let list, list.count == devices.count else {
                throw Failure("\(label): expected \(devices.count) waiting device(s), got \(String(describing: list))")
            }
            for (entry, device) in zip(list, devices) {
                guard entry["id"] as? String == device.id, entry["name"] as? String == device.name,
                      entry["fingerprint"] as? String == DeviceIdentity.fingerprint(ofId: device.id) else {
                    throw Failure("\(label): the waiting list does not show \(device.name) as it is: \(entry)")
                }
            }
        }

        func decide(_ device: Device, _ decision: String) throws {
            let payload = try JSONSerialization.data(withJSONObject: ["id": device.id, "decision": decision])
            try sendSecure(.deviceDecision, payload)
        }
    }

    // MARK: - The bench

    private final class Bench {
        let auth: HostAuth
        private var clients: [Client] = []

        init(auth: HostAuth) { self.auth = auth }

        func connect(_ port: UInt16, _ label: String) -> Client {
            let client = Client(port: port, label: label, hostKey: auth.identity.publicKey)
            clients.append(client)
            return client
        }

        /// A device asks to connect and is told to wait.
        func knock(_ port: UInt16, _ device: Device, _ label: String,
                   capabilities: StreamCapabilities = []) throws -> Client {
            let client = connect(port, label)
            try client.readChallenge()
            try client.answer(as: device, capabilities: capabilities)
            try client.expectStatus(.pending)
            return client
        }

        /// A device asks to connect and is let in at once.
        func enter(_ port: UInt16, _ device: Device, _ label: String,
                   capabilities: StreamCapabilities = [], display: Int) throws -> Client {
            let client = connect(port, label)
            try client.readChallenge()
            try client.answer(as: device, capabilities: capabilities)
            try client.expectStatus(.accepted)
            try client.beginSession(display: display)
            return client
        }

        /// A listener binds after start() returns, so try until one answers.
        func waitForListener(_ port: UInt16) throws {
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                let probe = connect(port, "probe")
                let event = probe.next(within: 2)
                probe.close()
                if case .message(.authChallenge, _)? = event { return }
                Thread.sleep(forTimeInterval: 0.2)
            }
            throw Failure("the listener on port \(port) did not come up")
        }

        func closeAll() { clients.forEach { $0.close() } }
    }

    // MARK: - Run

    static func run() -> Int32 {
        let stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clamshell-auth-gate-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let auth = HostAuth(directory: stateDir, requireApproval: true, watch: false)
        auth.responseDeadline = 4
        auth.pendingRepeat = 0.2

        let servers = [
            StreamServer(source: .display(CGMainDisplayID()), port: port0, isPrimary: false,
                         auth: auth, displayIndex: 0, loopbackOnly: true),
            StreamServer(source: .display(CGMainDisplayID()), port: port1, isPrimary: false,
                         auth: auth, displayIndex: 1, loopbackOnly: true),
        ]
        let bench = Bench(auth: auth)
        var code: Int32 = 0
        do {
            for server in servers { try server.start() }
            try bench.waitForListener(port0)
            try bench.waitForListener(port1)
            try check(bench)
            print("PASS: the gate let in only what the user approved")
        } catch let failure as Failure {
            print("FAIL: \(failure.what)")
            code = 1
        } catch {
            print("FAIL: \(error)")
            code = 1
        }
        bench.closeAll()
        let stopped = DispatchGroup()
        for server in servers {
            stopped.enter()
            server.stop { stopped.leave() }
        }
        _ = stopped.wait(timeout: .now() + 5)
        return code
    }

    private static func check(_ bench: Bench) throws {
        let auth = bench.auth
        let store = auth.store
        let onHost = DeviceTrustStore.decidedOnHost
        let a = Device(name: "Selftest A"), b = Device(name: "Selftest B")
        let d = Device(name: "Selftest D"), f = Device(name: "Selftest F")
        let g = Device(name: "Selftest G"), x = Device(name: "Selftest X")
        // A HELLO too short to start a session, and a keepalive, in the clear.
        let shortHello = StreamMessage.frame(type: .hello, payload: Data([streamProtocolVersion]))
        let clearPing = StreamMessage.frame(type: .ping)

        // 1. An unknown device waits, and nothing it sends is read. Approval
        //    on the host lets it in on the connection it already has.
        let a1 = try bench.knock(port0, a, "A")
        try expect(a1.hostCapabilities.contains(.approvalRequired) && a1.hostCapabilities.contains(.deviceApproval),
                   "the challenge says approval is required")
        try expect(store.state(of: a.id) == .waiting, "an unknown device is listed as waiting")
        a1.send(shortHello)
        a1.send(clearPing)
        try expect(try a1.onlyPending(for: 1.0) >= 1, "a waiting connection is told again that it is waiting")
        try expect(store.decide(id: a.id, .approve, by: onHost, onlyIfWaiting: false) != nil,
                   "the host can approve a waiting device")
        try a1.expectStatus(.accepted, skippingPending: true)
        try a1.beginSession(display: 0)
        try a1.expectPing()
        try a1.expectNothing(for: 0.3, "what a device sent while it waited is never answered")
        print("PASS an unknown device waits, is not read, and gets in when the host approves it")

        // 2. A second device knocking on the same listener does not disturb
        //    the session. Once approved it takes the listener over.
        let b1 = try bench.knock(port0, b, "B")
        try a1.expectPing()
        try expect(store.decide(id: b.id, .approve, by: onHost, onlyIfWaiting: false) != nil,
                   "the host can approve a second device")
        try b1.expectStatus(.accepted, skippingPending: true)
        try b1.beginSession(display: 0)
        try a1.expectClosed("another device was let in on its listener")
        try b1.expectPing()
        print("PASS a waiting device does not disturb the session; a device that is let in replaces it")

        // 3. Revoking a device ends its session. When it comes back it is
        //    told it is denied and the connection is closed.
        try expect(store.revoke(id: b.id, by: onHost) != nil, "the host can revoke a trusted device")
        try b1.expectClosed("its device was revoked")
        let b2 = bench.connect(port0, "B after revoke")
        try b2.readChallenge()
        try b2.answer(as: b)
        try b2.expectStatus(.denied)
        try b2.expectClosed("its device is denied")
        print("PASS revoking closes the session, and the device is denied when it returns")

        // 4. A trusted device gets in at once. A message in the clear on an
        //    encrypted session closes it.
        let a2 = try bench.enter(port0, a, "A second time", display: 0)
        try a2.expectPing()
        a2.send(clearPing)
        try a2.expectClosed("it sent a message in the clear after accepted")
        print("PASS a trusted device gets in at once; a clear message on its session closes it")

        // 5. So does a message that was changed on the way, and one sent twice.
        let a3 = try bench.enter(port0, a, "A third time", display: 0)
        var changed = try a3.seal(.ping)
        changed[changed.endIndex - 1] ^= 0x01
        a3.send(changed)
        try a3.expectClosed("a SECURE message did not decrypt")
        let a4 = try bench.enter(port0, a, "A fourth time", display: 0)
        let once = try a4.seal(.ping)
        a4.send(once)
        try a4.expectSecure(.ping)
        a4.send(once)
        try a4.expectClosed("a SECURE message was sent twice")
        print("PASS a changed or repeated SECURE message closes the session")

        // 6. Answers that prove nothing: a changed signature, a trusted key
        //    signed for with another key, an old answer played again, and an
        //    answer that is too large. None of them changes the device list.
        let before = store.all()
        let x1 = bench.connect(port0, "changed signature")
        var forged = try ClientHandshake(challengePayload: try x1.readChallenge().payload, deviceKey: x.publicKey,
                                         capabilities: [], name: x.name, sign: AuthSignature.signer(x.key)).response
        forged[forged.endIndex - 1] ^= 0x01
        x1.sendResponse(forged)
        try x1.expectStatus(.invalid)
        try x1.expectClosed("its signature was wrong")

        let x2 = bench.connect(port0, "someone else's key")
        let stolen = try ClientHandshake(challengePayload: try x2.readChallenge().payload, deviceKey: a.publicKey,
                                         capabilities: [], name: a.name, sign: AuthSignature.signer(x.key)).response
        x2.sendResponse(stolen)
        try x2.expectStatus(.invalid)
        try x2.expectClosed("it does not hold the key it showed")

        let x3 = bench.connect(port0, "replayed answer")
        try x3.readChallenge()
        x3.sendResponse(a4.sentResponse)
        try x3.expectStatus(.invalid)
        try x3.expectClosed("its answer was made for another connection")

        let x4 = bench.connect(port0, "oversized answer")
        try x4.readChallenge()
        var oversized = Data([StreamMessageType.authResponse.rawValue])
        oversized.appendBE(UInt32(AuthWire.maxResponseBytes + 1))
        oversized.append(Data(count: 64))
        x4.send(oversized)
        try x4.expectClosed("its answer was larger than the host reads")
        try expect(store.all() == before && store.isTrusted(a.id) && store.record(id: x.id) == nil,
                   "answers that prove nothing leave the device list as it was")
        print("PASS a forged, borrowed, replayed or oversized answer gets nothing")

        // 7. A connection that never answers is sent nothing, whatever it
        //    sends, until the host tells it the time is up. The session on
        //    the same listener carries on.
        let a5 = try bench.enter(port0, a, "A fifth time", display: 0)
        let silent = bench.connect(port0, "no answer")
        try silent.readChallenge()
        silent.send(shortHello)
        silent.send(clearPing)
        try silent.expectNothing(for: 1.0, "a connection that has not answered the challenge is sent nothing")
        try silent.expectStatus(.timeout)
        try silent.expectClosed("it did not answer in time")
        try a5.expectPing()
        print("PASS a connection that does not answer starts nothing and is closed when its time is up")

        // 8. A trusted device that can show the approval prompt hears about a
        //    waiting device and approves it.
        let a6 = try bench.enter(port0, a, "A sixth time", capabilities: .deviceApproval, display: 0)
        try a5.expectClosed("its device connected again on the same listener")
        let d1 = try bench.knock(port1, d, "D")
        try a6.expectWaitingList([d])
        try a6.decide(d, "approve")
        try a6.expectWaitingList([])
        try d1.expectStatus(.accepted, skippingPending: true)
        try d1.beginSession(display: 1)
        try expect(store.isTrusted(d.id) && store.record(id: d.id)?.decidedBy == a.id,
                   "the list records which device approved the new one")
        print("PASS a trusted device approves a waiting one, and the list says who did")

        // 9. A trusted device that did not say it can show the prompt cannot
        //    decide. A waiting connection that sends too much is closed; its
        //    device stays on the waiting list.
        let f1 = try bench.knock(port0, f, "F")
        try a6.expectWaitingList([f])
        try d1.decide(f, "approve")
        try d1.expectPing()
        try expect(store.state(of: f.id) == .waiting, "a decision from a device without the prompt changes nothing")
        f1.send(Data(count: StreamGate.pendingByteBudget + 4096))
        try f1.expectClosed("it sent more than a waiting connection may", allowingPending: true)
        try expect(store.state(of: f.id) == .waiting && !auth.hasWaitingConnection(deviceId: f.id),
                   "a device whose connection was closed for sending too much is still waiting")
        print("PASS only a device with the prompt can decide; a waiting connection that floods is closed")

        // 10. With approval turned off the host still sends the challenge,
        //     lets in a device nobody approved and a client that sends HELLO
        //     in the clear, and takes a decision from neither. Turning
        //     approval back on closes both.
        auth.overrideRequireApproval(false)
        let g1 = bench.connect(port1, "G")
        try g1.readChallenge()
        try expect(!g1.hostCapabilities.contains(.approvalRequired), "the challenge says approval is not required")
        try g1.answer(as: g, capabilities: .deviceApproval)
        try g1.expectStatus(.accepted)
        try g1.beginSession(display: 1)
        try d1.expectClosed("another device was let in on its listener")
        try g1.decide(f, "approve")
        try g1.expectPing()
        try expect(store.state(of: f.id) == .waiting && store.record(id: g.id) == nil,
                   "a device let in with approval off is not listed and cannot decide")
        let old = bench.connect(port0, "client without the handshake")
        try old.readChallenge()
        old.send(shortHello)
        old.send(clearPing)
        try expect(try old.expectClear(.ping).isEmpty, "the keepalive echo is empty")
        try a6.expectClosed("another client was let in on its listener")
        auth.overrideRequireApproval(true)
        try old.expectClosed("device approval was turned on")
        try g1.expectClosed("device approval was turned on and nobody approved it")
        try expect(store.state(of: f.id) == .waiting, "turning approval off and on approves nobody")
        print("PASS approval off serves any client; turning it on closes the ones nobody approved")

        // 11. One device may wait on several connections; one more than the
        //     host allows is told the host is busy. When a trusted device
        //     denies it, every waiting connection is told and closed, and
        //     the denial cannot be undone from a device.
        let a7 = try bench.enter(port0, a, "A seventh time", capabilities: .deviceApproval, display: 0)
        try a7.expectWaitingList([f])
        var waiting: [Client] = []
        for n in 1 ... HostAuth.maxWaitingConnections {
            waiting.append(try bench.knock(port1, f, "F, waiting connection \(n)"))
        }
        let extra = bench.connect(port1, "F, one connection too many")
        try extra.readChallenge()
        try extra.answer(as: f)
        try extra.expectStatus(.busy)
        try extra.expectClosed("too many connections were waiting")
        try a7.decide(f, "deny")
        try a7.expectWaitingList([])
        for client in waiting {
            try client.expectStatus(.denied, skippingPending: true)
            try client.expectClosed("its device was denied")
        }
        try a7.decide(f, "approve")
        try a7.expectWaitingList([])
        try expect(store.state(of: f.id) == .denied && store.record(id: f.id)?.decidedBy == a.id,
                   "a device cannot approve one that was already denied")
        try a7.expectPing()
        print("PASS waiting connections are capped; a denial reaches every one and stays")
    }
}
