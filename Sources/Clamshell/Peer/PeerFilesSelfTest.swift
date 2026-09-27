import AppKit
import CryptoKit

// `clamshell peer-files-selftest` — clipboard and file transfer between two
// PeerLinks over real loopback WebSockets (ports 5994/5995), each side with
// its own scratch Downloads folder and private pasteboard:
//   1. files of 0 bytes, 1 byte, exactly one chunk + 1, and ~3 MB random
//      arrive intact under their own names, both directions
//   2. a folder arrives as a .zip; a name clash gets "name (2).ext"
//   3. a tampered hash, an out-of-order chunk and a mid-transfer cancel
//      leave nothing behind (no file, no .part)
//   4. clipboard text and a PNG image cross, and the receiver doesn't echo
//      them back
enum PeerFilesSelfTest {
    private static var failures = 0
    private static func check(_ ok: Bool, _ what: String) {
        if !ok { failures += 1; print("FAIL: \(what)") } else { print("ok   \(what)") }
    }

    private final class Side {
        let link: PeerLink
        let files: FileTransfer
        let clipboard: PeerClipboard
        let pasteboard: NSPasteboard
        let dir: URL
        var received: [URL] = []
        var errors: [String] = []
        var raw: [(StreamMessageType, Data)] = []
        let lock = NSLock()
        init(name: String, port: UInt16, root: URL) {
            dir = root.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            link = PeerLink(identity: PeerIdentity(), trust: PeerTrustStore(fileURL: nil), localName: name, port: port) { (800, 600) }
            files = FileTransfer(directory: dir)
            pasteboard = NSPasteboard(name: NSPasteboard.Name("com.frindle.clamshell.selftest.\(name).\(UUID().uuidString)"))
            clipboard = PeerClipboard(pasteboard: pasteboard)
            files.send = { [link] data, done in link.send(data, completion: done) }
            clipboard.send = { [link] data in link.send(data) }
            files.onReceived = { [weak self] url in self?.lock.withLock { self?.received.append(url) } }
            files.onFailed = { [weak self] msg in self?.lock.withLock { self?.errors.append(msg) } }
            link.onMessage = { [weak self] t, p in
                guard let self else { return }
                self.lock.withLock { self.raw.append((t, p)) }
                if self.files.receive(type: t, payload: p) { return }
                DispatchQueue.main.async { _ = self.clipboard.receive(type: t, payload: p) }
            }
        }
        var receivedNames: [String] { lock.withLock { received.map(\.lastPathComponent) } }
        func leftovers() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".part") }
        }
    }

    /// Spins the main run loop (clipboard receive hops to main) until `cond`.
    private static func wait(_ timeout: TimeInterval = 10, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return cond()
    }

    static func run() -> Int32 {
        failures = 0
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clamshell-files-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = Side(name: "A", port: 5994, root: root)
        let b = Side(name: "B", port: 5995, root: root)
        do { try a.link.startListening(advertise: false); try b.link.startListening(advertise: false) } catch {
            print("FAIL: listen: \(error)"); return 1
        }
        _ = wait(0.3) { false }
        let linked = DispatchSemaphore(value: 0)
        a.link.onStateChange = { if case .linked = $0 { linked.signal() } }
        a.link.connect(host: "127.0.0.1", port: 5995, pin: b.link.pairingPIN)
        guard linked.wait(timeout: .now() + 10) == .success else { print("FAIL: link did not come up"); return 1 }
        _ = wait(0.3) { false }

        // 1. Files, both directions.
        let src = root.appendingPathComponent("src", isDirectory: true)
        try? FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        func make(_ name: String, _ bytes: Data) -> URL {
            let u = src.appendingPathComponent(name); try? bytes.write(to: u); return u
        }
        var rng = SystemRandomNumberGenerator()
        let big = Data((0..<(3 << 20) + 12345).map { _ in UInt8.random(in: 0...255, using: &rng) })
        let fixtures: [(String, Data)] = [("empty.txt", Data()), ("one.bin", Data([42])),
                                          ("chunk+1.bin", Data(repeating: 7, count: PeerLimits.chunkSize + 1)),
                                          ("big file.dat", big)]
        a.files.send(urls: fixtures.map { make($0.0, $0.1) })
        check(wait(20) { b.receivedNames.count == fixtures.count }, "A→B: \(fixtures.count) files arrive (got \(b.receivedNames))")
        for (name, bytes) in fixtures {
            let got = try? Data(contentsOf: b.dir.appendingPathComponent(name))
            check(got == bytes, "\(name) intact (\(bytes.count) bytes)")
        }
        b.files.send(urls: [make("reply.txt", Data("back to A".utf8))])
        check(wait { a.receivedNames == ["reply.txt"] } &&
              (try? String(contentsOf: a.dir.appendingPathComponent("reply.txt"), encoding: .utf8)) == "back to A",
              "B→A reply arrives")

        // 2. Folder → zip, and a name clash.
        let folder = src.appendingPathComponent("Project")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data("inside".utf8).write(to: folder.appendingPathComponent("note.txt"))
        a.files.send(urls: [folder, make("one.bin", Data([43]))])
        check(wait(20) { b.receivedNames.contains("Project.zip") && b.receivedNames.contains("one (2).bin") },
              "folder arrives as Project.zip; clash becomes \"one (2).bin\" (got \(b.receivedNames))")
        if let zipSize = (try? FileManager.default.attributesOfItem(atPath: b.dir.appendingPathComponent("Project.zip").path)[.size] as? NSNumber)?.intValue {
            check(zipSize > 100, "zip is non-trivial (\(zipSize) bytes)")
        }

        // 3. Hostile / broken sequences, sent raw from A.
        let before = b.receivedNames.count
        func raw(_ d: Data) { a.link.send(d) }
        raw(StreamMessage.fileOffer(transferId: 900, size: 5, name: "../../evil.sh"))
        _ = wait(1) { false }
        raw(StreamMessage.fileChunk(transferId: 900, offset: 0, bytes: Data("hello".utf8)))
        raw(StreamMessage.fileDone(transferId: 900, sha256: Data(repeating: 0, count: 32)))
        raw(StreamMessage.fileOffer(transferId: 901, size: 10, name: "gap.bin"))
        _ = wait(1) { false }
        raw(StreamMessage.fileChunk(transferId: 901, offset: 5, bytes: Data(repeating: 1, count: 5)))
        raw(StreamMessage.fileOffer(transferId: 902, size: 10, name: "cancelled.bin"))
        _ = wait(1) { false }
        raw(StreamMessage.fileChunk(transferId: 902, offset: 0, bytes: Data(repeating: 1, count: 5)))
        raw(StreamMessage.fileCancel(transferId: 902, reason: .user))
        raw(StreamMessage.fileOffer(transferId: 903, size: PeerLimits.maxFileSize + 1, name: "huge.bin"))
        _ = wait(1.5) { false }
        b.files.drain()
        check(b.receivedNames.count == before, "no file from a bad hash, a gap or a cancel")
        check(b.leftovers().isEmpty, "no .part files left behind (\(b.leftovers()))")
        check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("evil.sh").path) &&
              !FileManager.default.fileExists(atPath: b.dir.appendingPathComponent("evil.sh").path),
              "traversal name never written outside or inside")
        let answers = a.lock.withLock { a.raw.map(\.0) }
        check(answers.contains(.fileReject), "oversized offer rejected")
        check(answers.filter { $0 == .fileCancel }.count >= 1, "gap chunk answered with FILE_CANCEL")

        // 4. Clipboard both ways, no echo.
        a.clipboard.start(); b.clipboard.start()
        a.pasteboard.clearContents(); a.pasteboard.setString("clipboard from A ✓", forType: .string)
        a.clipboard.poll()
        check(wait { b.pasteboard.string(forType: .string) == "clipboard from A ✓" }, "text copied on A pastes on B")
        let rawCountBefore = a.lock.withLock { a.raw.count }
        b.clipboard.poll()
        _ = wait(0.5) { false }
        check(a.lock.withLock { a.raw.count } == rawCountBefore, "B does not echo the received text back")
        let img = NSImage(size: NSSize(width: 4, height: 3))
        img.lockFocus(); NSColor.systemPink.setFill(); NSRect(x: 0, y: 0, width: 4, height: 3).fill(); img.unlockFocus()
        let png = NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        b.pasteboard.clearContents(); b.pasteboard.setData(png, forType: .png)
        b.clipboard.poll()
        check(wait { a.pasteboard.data(forType: .png) == png && a.pasteboard.data(forType: .tiff) != nil },
              "image copied on B pastes on A (PNG + TIFF offered)")

        a.clipboard.stop(); b.clipboard.stop()
        let done = DispatchSemaphore(value: 0)
        a.link.stop { done.signal() }; b.link.stop { done.signal() }
        _ = done.wait(timeout: .now() + 3); _ = done.wait(timeout: .now() + 3)
        a.pasteboard.releaseGlobally(); b.pasteboard.releaseGlobally()
        print(failures == 0 ? "PASS: peer files selftest (files, folders, hostile sequences, clipboard over loopback)"
                            : "FAIL: \(failures) check(s) failed")
        return failures == 0 ? 0 : 1
    }
}
