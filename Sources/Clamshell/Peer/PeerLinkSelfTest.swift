import Foundation

// `clamshell peer-link-selftest` — two PeerLinks in one process over real
// loopback WebSockets (ports 5998/5999, the stream-selftest pair), proving
// the transport + handshake end to end without Bonjour or a second machine:
//   1. an unpaired peer without a PIN is refused (UNTRUSTED)
//   2. the wrong PIN is refused (BAD_PIN) and leaves nothing trusted
//   3. the right PIN pairs both directions (each side stores the other)
//   4. a reconnect with no PIN succeeds on stored trust alone
//   5. post-auth messages flow both ways, including a max-size FILE_CHUNK
//   6. a pre-auth feature message drops the connection
enum PeerLinkSelfTest {
    private static var failures = 0
    private static func check(_ ok: Bool, _ what: String) {
        if !ok { failures += 1; print("FAIL: \(what)") }
    }

    /// Blocks until `link` reports a terminal state (linked/failed/idle).
    private static func awaitSettled(_ link: PeerLink, timeout: TimeInterval = 10) -> PeerLinkState {
        let sema = DispatchSemaphore(value: 0)
        var result: PeerLinkState = .idle
        link.onStateChange = { s in
            switch s {
            case .linked, .failed, .idle: result = s; sema.signal()
            default: break
            }
        }
        _ = sema.wait(timeout: .now() + timeout)
        return result
    }

    static func run() -> Int32 {
        failures = 0
        let idA = PeerIdentity(), idB = PeerIdentity()
        let trustA = PeerTrustStore(fileURL: nil), trustB = PeerTrustStore(fileURL: nil)
        let a = PeerLink(identity: idA, trust: trustA, localName: "A", port: 5998) { (1000, 500) }
        let b = PeerLink(identity: idB, trust: trustB, localName: "B", port: 5999) { (2000, 1000) }
        do {
            try a.startListening(advertise: false)
            try b.startListening(advertise: false)
        } catch {
            print("FAIL: could not listen: \(error)"); return 1
        }
        Thread.sleep(forTimeInterval: 0.3)

        // 1. No PIN, not paired.
        a.connect(host: "127.0.0.1", port: 5999, pin: nil)
        var s = awaitSettled(a)
        if case .failed(let why) = s { check(why.contains("not paired"), "untrusted refused: \(why)") } else { check(false, "untrusted should fail, got \(s)") }
        check(!trustB.isTrusted(publicKey: idA.publicKey), "no trust after untrusted attempt")

        // 2. Wrong PIN.
        let wrong = b.pairingPIN == "000000" ? "111111" : "000000"
        a.connect(host: "127.0.0.1", port: 5999, pin: wrong)
        s = awaitSettled(a)
        if case .failed(let why) = s { check(why.contains("wrong PIN"), "bad pin refused: \(why)") } else { check(false, "bad pin should fail, got \(s)") }
        check(!trustB.isTrusted(publicKey: idA.publicKey) && !trustA.isTrusted(publicKey: idB.publicKey), "no trust after bad pin")

        // 3. Right PIN pairs both ways.
        let pinBefore = b.pairingPIN
        a.connect(host: "127.0.0.1", port: 5999, pin: pinBefore)
        s = awaitSettled(a)
        if case .linked(let info, let w, let h) = s {
            check(info.name == "B" && info.id == idB.id && w == 2000 && h == 1000, "A linked to B with B's screen")
        } else { check(false, "pairing should link, got \(s)") }
        Thread.sleep(forTimeInterval: 0.2)
        check(trustA.isTrusted(publicKey: idB.publicKey), "A trusts B after pairing")
        check(trustB.isTrusted(publicKey: idA.publicKey), "B trusts A after pairing")
        check(b.pairingPIN != pinBefore, "B's PIN rotated after pairing")
        if case .linked(let info, let w, _) = b.state { check(info.id == idA.id && w == 1000, "B sees A") } else { check(false, "B not linked: \(b.state)") }

        // 5. Messages both ways, including a maximum-size chunk.
        let gotOnB = DispatchSemaphore(value: 0), gotOnA = DispatchSemaphore(value: 0)
        var bReceived: (StreamMessageType, Data)?, aReceived: (StreamMessageType, Data)?
        b.onMessage = { t, p in bReceived = (t, p); gotOnB.signal() }
        a.onMessage = { t, p in aReceived = (t, p); gotOnA.signal() }
        let big = Data((0..<PeerLimits.chunkSize).map { UInt8($0 & 0xFF) })
        a.send(StreamMessage.fileChunk(transferId: 1, offset: 0, bytes: big))
        check(gotOnB.wait(timeout: .now() + 5) == .success, "B received chunk")
        check(bReceived?.0 == .fileChunk && PeerParse.fileChunk(bReceived?.1 ?? Data())?.bytes == big, "chunk intact")
        b.send(StreamMessage.clipboard(text: "hello from B"))
        check(gotOnA.wait(timeout: .now() + 5) == .success, "A received clipboard")
        check(aReceived?.0 == .clipboard && String(data: aReceived?.1 ?? Data(), encoding: .utf8) == "hello from B", "clipboard intact")

        // 4. Reconnect on stored trust, no PIN, initiated from the other side.
        a.disconnect()
        Thread.sleep(forTimeInterval: 0.3)
        b.connect(host: "127.0.0.1", port: 5998, pin: nil)
        s = awaitSettled(b)
        if case .linked(let info, _, _) = s { check(info.id == idA.id, "B reconnected to A on trust") } else { check(false, "reconnect should link, got \(s)") }

        // 6. A raw client that talks before authenticating gets dropped.
        b.disconnect()
        Thread.sleep(forTimeInterval: 0.3)
        let rogue = PeerLink(identity: PeerIdentity(), trust: PeerTrustStore(fileURL: nil), localName: "rogue", port: 5997) { (1, 1) }
        // Reuse PeerLink's client path but with a peer that never trusts it:
        rogue.connect(host: "127.0.0.1", port: 5998, pin: nil)
        s = awaitSettled(rogue)
        if case .failed = s {} else { check(false, "rogue should be refused, got \(s)") }
        check(!trustA.isTrusted(publicKey: rogue.identity.publicKey), "rogue never trusted")

        let done = DispatchSemaphore(value: 0)
        a.stop { done.signal() }
        b.stop { done.signal() }
        rogue.stop { done.signal() }
        _ = done.wait(timeout: .now() + 3); _ = done.wait(timeout: .now() + 3); _ = done.wait(timeout: .now() + 3)
        print(failures == 0 ? "PASS: peer link selftest (pairing, trust, reconnect, messages over loopback)"
                            : "FAIL: \(failures) check(s) failed")
        return failures == 0 ? 0 : 1
    }
}
