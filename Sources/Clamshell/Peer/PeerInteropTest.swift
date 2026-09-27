import CryptoKit
import Foundation

// `clamshell peer-interop listen <port> <dir>` / `connect <host> <port> <pin> <dir>`
// — one half of the Mac⇄Windows wire cross-check. The other half is
// `ClamshellServer peerinterop …` (WindowsServer/Peer/PeerSelfTest.cs); the
// two can also be run against themselves. Once linked, each side:
//   * sends every post-handshake golden message (same table on both sides)
//     and expects to receive exactly that sequence, byte for byte
//   * sends a ~1 MB deterministic file through FileTransfer and expects the
//     peer's identical file to land in <dir>
// Prints "PIN nnnnnn" (listen) and "PASS"/"FAIL: …"; exits 0 on PASS.
// Uses an ephemeral identity and an in-memory trust store — nothing on disk
// besides <dir>, no Bonjour, no input, no capture.
enum PeerInteropTest {
    static let fileSize = PeerLimits.chunkSize * 7 + 4321

    static func pattern() -> Data { Data((0..<fileSize).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }) }

    /// Golden messages that are legal on a linked connection and not
    /// consumed by the file-transfer engine.
    static func interopMessages() -> [(String, Data)] {
        PeerProtocolSelfTest.goldenMessages().filter { (_, d) in
            let t = d[d.startIndex]
            return !(0x40...0x42).contains(t) && !(0x50...0x55).contains(t)
        }
    }

    static func run(_ args: [String]) -> Int32 {
        let usage = "usage: peer-interop listen <port> <dir> | connect <host> <port> <pin> <dir> | mdns <name> <port> <seconds>"
        guard let mode = args.first else { print(usage); return 2 }
        if mode == "mdns", args.count == 4, let port = UInt16(args[2]), let secs = Double(args[3]) {
            return mdns(name: args[1], port: port, seconds: secs)
        }
        let listen = mode == "listen"
        guard (listen && args.count == 3) || (mode == "connect" && args.count == 5),
              let port = UInt16(args[listen ? 1 : 2]) else { print(usage); return 2 }
        let dir = URL(fileURLWithPath: args.last!, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let link = PeerLink(identity: PeerIdentity(), trust: PeerTrustStore(fileURL: nil), localName: "swift-interop",
                            port: listen ? port : 0) { (1111, 2222) }
        let files = FileTransfer(directory: dir)
        let lock = NSLock()
        var got: [Data] = []
        var received: [URL] = []
        var sent = false
        var failures: [String] = []
        var linkedTo: PeerLinkState?
        files.send = { data, done in link.send(data, completion: done) }
        files.onReceived = { url in lock.withLock { received.append(url) } }
        files.onSent = { _ in lock.withLock { sent = true } }
        files.onFailed = { msg in lock.withLock { failures.append(msg) } }
        link.onMessage = { t, p in
            if files.receive(type: t, payload: p) { return }
            lock.withLock { got.append(StreamMessage.frame(type: t, payload: p)) }
        }
        let linked = DispatchSemaphore(value: 0)
        link.onStateChange = { s in
            if s.isLinked { lock.withLock { linkedTo = s }; linked.signal() }
            if case .failed(let why) = s { print("link: \(why)") }
        }
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("interop-from-swift.bin")
        defer { try? FileManager.default.removeItem(at: src) }
        do { try pattern().write(to: src) } catch { print("FAIL: write source file: \(error)"); return 1 }

        if listen {
            do { try link.startListening(advertise: false) } catch { print("FAIL: listen: \(error)"); return 1 }
            print("PIN \(link.pairingPIN)"); fflush(stdout)
        } else {
            link.connect(host: args[1], port: port, pin: args[3])
        }
        defer {
            let done = DispatchSemaphore(value: 0)
            link.stop { done.signal() }
            _ = done.wait(timeout: .now() + 3)
        }
        guard linked.wait(timeout: .now() + 30) == .success else { print("FAIL: never linked"); return 1 }
        if case .linked(let info, let w, let h)? = lock.withLock({ linkedTo }) {
            print("linked with \(info.name) \(w)x\(h) id \(info.id.prefix(12))")
        }

        let expected = interopMessages()
        for (_, d) in expected { link.send(d) }
        files.send(urls: [src])

        let end = Date().addingTimeInterval(30)
        func done() -> Bool { lock.withLock { got.count >= expected.count && received.count >= 1 && sent } }
        while Date() < end && !done() { Thread.sleep(forTimeInterval: 0.05) }
        Thread.sleep(forTimeInterval: 1) // let our last bytes reach the peer before closing

        var bad = 0
        lock.withLock {
            for (i, (name, want)) in expected.enumerated() {
                if i >= got.count { print("FAIL: missing \(name)"); bad += 1; continue }
                if got[i] != want { print("FAIL: \(name) differs: \(got[i].map { String(format: "%02x", $0) }.joined())"); bad += 1 }
            }
            if got.count > expected.count { print("FAIL: \(got.count - expected.count) unexpected extra message(s)"); bad += 1 }
            if let url = received.first {
                let ok = (try? Data(contentsOf: url)) == pattern()
                print(ok ? "ok   received \(url.lastPathComponent) intact" : "FAIL: received file differs")
                if !ok { bad += 1 }
            } else { print("FAIL: no file received"); bad += 1 }
            if !sent { print("FAIL: our file was not sent"); bad += 1 }
            for f in failures { print("FAIL: transfer: \(f)"); bad += 1 }
        }
        if bad == 0 { print("ok   \(expected.count) golden messages received byte-identical") }
        print(bad == 0 ? "PASS" : "FAIL: \(bad) problem(s)")
        return bad == 0 ? 0 : 1
    }

    /// Advertises `name` on `port` over Bonjour and browses for
    /// _clamshell-peer._tcp for `seconds`, printing "found <name> id=<id>"
    /// for every other Clamshell seen (the C# side's mDNS included).
    private static func mdns(name: String, port: UInt16, seconds: Double) -> Int32 {
        let link = PeerLink(identity: PeerIdentity(), trust: PeerTrustStore(fileURL: nil), localName: name, port: port) { (1, 1) }
        var seen = Set<String>()
        let lock = NSLock()
        link.onDiscoveredChange = { peers in
            lock.withLock {
                for p in peers where !seen.contains(p.name + (p.id ?? "")) {
                    seen.insert(p.name + (p.id ?? ""))
                    print("found \(p.name) id=\(p.id ?? "-")"); fflush(stdout)
                }
            }
        }
        do { try link.startListening(advertise: true) } catch { print("FAIL: listen: \(error)"); return 1 }
        print("advertising \(name) id=\(link.identity.id)"); fflush(stdout)
        link.startBrowsing()
        Thread.sleep(forTimeInterval: seconds)
        let done = DispatchSemaphore(value: 0)
        link.stop { done.signal() }
        _ = done.wait(timeout: .now() + 3)
        return 0
    }
}
