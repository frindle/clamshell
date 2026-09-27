import Foundation
import CryptoKit

// File transfer over the peer link (PROTOCOL.md "Peer link — files"):
// FILE_OFFER → FILE_ACCEPT/REJECT → FILE_CHUNK × n (sequential offsets,
// ≤ 128 KiB each) → FILE_DONE with the SHA-256 of the whole file; either
// side may FILE_CANCEL. Used for drag-and-drop across machines and the
// "Send File to Peer…" menu item.
//
// Receiving: auto-accepted from the (already authenticated, paired) peer
// into ~/Downloads under a sanitized, de-duplicated name, written to a
// hidden ".part" file first and only renamed into place once the size and
// hash check out. A folder is sent as a .zip of the folder (both platforms
// open zips natively).
//
// All state and file I/O live on one serial queue; the sender paces itself
// on the transport's send completions (at most 8 chunks in flight).

final class FileTransfer {
    private let queue = DispatchQueue(label: "clamshell.peer.files")
    private let directory: URL
    /// Transport: message + completion when handed to the socket.
    var send: (Data, @escaping () -> Void) -> Void = { _, done in done() }
    var onReceived: (URL) -> Void = { _ in }
    var onSent: (String) -> Void = { _ in }
    var onFailed: (String) -> Void = { _ in }

    private struct Outgoing {
        let id: UInt32
        let name: String
        let size: UInt64
        let handle: FileHandle
        var hasher = SHA256()
        var offset: UInt64 = 0
        var inFlight = 0
        var accepted = false
        let cleanup: URL?   // temporary zip to delete afterwards
    }
    private struct Incoming {
        let id: UInt32
        let name: String
        let size: UInt64
        let partURL: URL
        let handle: FileHandle
        var hasher = SHA256()
        var written: UInt64 = 0
    }

    private var pending: [(URL, String)] = []   // queued sends: file, wire name
    private var outgoing: Outgoing?
    private var incoming: [UInt32: Incoming] = [:]
    private var nextId = UInt32.random(in: 1...0x7FFF_FFFF)
    private var acceptTimeout: DispatchWorkItem?
    private let maxInFlight = 8
    private let maxIncoming = 4

    init(directory: URL = FileTransfer.downloadsDirectory) {
        self.directory = directory
    }

    static var downloadsDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }

    // MARK: - Sending

    func send(urls: [URL]) {
        queue.async { [self] in
            for url in urls {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    guard let zip = Self.zip(folder: url) else { report("could not zip \(url.lastPathComponent)"); continue }
                    pending.append((zip, url.lastPathComponent + ".zip"))
                } else {
                    pending.append((url, url.lastPathComponent))
                }
            }
            startNext()
        }
    }

    private static func zip(folder: URL) -> URL? {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("clamshell-\(UUID().uuidString).zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, out.path]
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        return p.terminationStatus == 0 ? out : nil
    }

    private func startNext() {
        guard outgoing == nil, !pending.isEmpty else { return }
        let (url, name) = pending.removeFirst()
        let isTemp = url.path.hasPrefix(FileManager.default.temporaryDirectory.path)
        guard let handle = try? FileHandle(forReadingFrom: url),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value else {
            report("could not read \(name)"); startNext(); return
        }
        guard size <= PeerLimits.maxFileSize else {
            report("\(name) is larger than the \(PeerLimits.maxFileSize >> 30) GiB limit"); startNext(); return
        }
        let id = nextId; nextId &+= 1
        outgoing = Outgoing(id: id, name: name, size: size, handle: handle, cleanup: isTemp ? url : nil)
        clog("PEER: offering \(name) (\(size) bytes) as transfer \(id)")
        send(StreamMessage.fileOffer(transferId: id, size: size, name: name)) {}
        let work = DispatchWorkItem { [weak self] in
            guard let self, let o = self.outgoing, o.id == id, !o.accepted else { return }
            self.send(StreamMessage.fileCancel(transferId: id, reason: .error)) {}
            self.finishOutgoing(error: "peer did not answer the offer for \(name)")
        }
        acceptTimeout = work
        queue.asyncAfter(deadline: .now() + 60, execute: work)
    }

    private func pump() {
        guard var o = outgoing, o.accepted else { return }
        while o.inFlight < maxInFlight && o.offset < o.size {
            let n = Int(min(UInt64(PeerLimits.chunkSize), o.size - o.offset))
            guard let bytes = try? o.handle.read(upToCount: n), bytes.count == n else {
                outgoing = o
                send(StreamMessage.fileCancel(transferId: o.id, reason: .error)) {}
                finishOutgoing(error: "read error in \(o.name)")
                return
            }
            o.hasher.update(data: bytes)
            let id = o.id
            send(StreamMessage.fileChunk(transferId: id, offset: o.offset, bytes: bytes)) { [weak self] in
                self?.queue.async {
                    guard let self, var cur = self.outgoing, cur.id == id else { return }
                    cur.inFlight -= 1
                    self.outgoing = cur
                    self.pump()
                }
            }
            o.offset += UInt64(n)
            o.inFlight += 1
        }
        outgoing = o
        if o.offset == o.size && o.inFlight == 0 {
            let digest = Data(o.hasher.finalize())
            send(StreamMessage.fileDone(transferId: o.id, sha256: digest)) {}
            clog("PEER: sent \(o.name)")
            onSent(o.name)
            finishOutgoing(error: nil)
        }
    }

    private func finishOutgoing(error: String?) {
        acceptTimeout?.cancel(); acceptTimeout = nil
        if let o = outgoing {
            try? o.handle.close()
            if let tmp = o.cleanup { try? FileManager.default.removeItem(at: tmp) }
        }
        outgoing = nil
        if let error { report(error) }
        startNext()
    }

    // MARK: - Receiving / control (entry point from PeerManager, any thread)

    /// Returns true when `type` is a file-transfer message.
    func receive(type: StreamMessageType, payload: Data) -> Bool {
        switch type {
        case .fileOffer, .fileAccept, .fileReject, .fileChunk, .fileDone, .fileCancel:
            queue.async { [self] in handle(type: type, payload: payload) }
            return true
        default:
            return false
        }
    }

    private func handle(type: StreamMessageType, payload: Data) {
        switch type {
        case .fileAccept:
            guard let id = PeerParse.windowId(payload), var o = outgoing, o.id == id, !o.accepted else { return }
            o.accepted = true
            outgoing = o
            acceptTimeout?.cancel()
            pump()
        case .fileReject:
            guard let r = PeerParse.idAndReason(payload), outgoing?.id == r.id else { return }
            finishOutgoing(error: "peer declined \(outgoing?.name ?? "file") (\(r.reason))")
        case .fileCancel:
            guard let r = PeerParse.idAndReason(payload) else { return }
            if outgoing?.id == r.id { finishOutgoing(error: "peer cancelled \(outgoing?.name ?? "file")") }
            if let inc = incoming.removeValue(forKey: r.id) { discard(inc, why: "sender cancelled") }
        case .fileOffer:
            guard let offer = PeerParse.fileOffer(payload) else { return }
            accept(offer)
        case .fileChunk:
            guard let c = PeerParse.fileChunk(payload), var inc = incoming[c.transferId] else { return }
            guard c.offset == inc.written, inc.written + UInt64(c.bytes.count) <= inc.size else {
                incoming[c.transferId] = nil
                send(StreamMessage.fileCancel(transferId: c.transferId, reason: .error)) {}
                discard(inc, why: "out-of-order or oversized chunk")
                return
            }
            do { try inc.handle.write(contentsOf: c.bytes) } catch {
                incoming[c.transferId] = nil
                send(StreamMessage.fileCancel(transferId: c.transferId, reason: .disk)) {}
                discard(inc, why: "disk write failed: \(error)")
                return
            }
            inc.hasher.update(data: c.bytes)
            inc.written += UInt64(c.bytes.count)
            incoming[c.transferId] = inc
        case .fileDone:
            guard let d = PeerParse.fileDone(payload), let inc = incoming.removeValue(forKey: d.id) else { return }
            try? inc.handle.close()
            let digest = Data(inc.hasher.finalize())
            guard inc.written == inc.size, digest == d.sha256 else {
                discard(inc, why: "size/hash mismatch (\(inc.written)/\(inc.size) bytes)")
                return
            }
            let dest = PeerFileNames.uniqueURL(in: directory, name: inc.name)
            do {
                try FileManager.default.moveItem(at: inc.partURL, to: dest)
                clog("PEER: received \(dest.lastPathComponent) (\(inc.size) bytes, sha256 ok)")
                onReceived(dest)
            } catch {
                discard(inc, why: "could not move into place: \(error)")
            }
        default:
            break
        }
    }

    private func accept(_ offer: FileOfferPayload) {
        let name = PeerFileNames.sanitize(offer.name)
        guard incoming[offer.transferId] == nil else { return }
        guard incoming.count < maxIncoming else {
            send(StreamMessage.fileReject(transferId: offer.transferId, reason: .busy)) {}; return
        }
        guard offer.size <= PeerLimits.maxFileSize else {
            send(StreamMessage.fileReject(transferId: offer.transferId, reason: .tooLarge)) {}; return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let free = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free > 0, UInt64(free) < offer.size + (256 << 20) {
            send(StreamMessage.fileReject(transferId: offer.transferId, reason: .disk)) {}; return
        }
        let part = directory.appendingPathComponent(".clamshell-\(offer.transferId)-\(UUID().uuidString.prefix(8)).part")
        guard FileManager.default.createFile(atPath: part.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: part) else {
            send(StreamMessage.fileReject(transferId: offer.transferId, reason: .disk)) {}; return
        }
        incoming[offer.transferId] = Incoming(id: offer.transferId, name: name, size: offer.size, partURL: part, handle: handle)
        clog("PEER: accepting \(name) (\(offer.size) bytes)")
        send(StreamMessage.fileAccept(transferId: offer.transferId)) {}
    }

    private func discard(_ inc: Incoming, why: String) {
        try? inc.handle.close()
        try? FileManager.default.removeItem(at: inc.partURL)
        report("dropped incoming \(inc.name): \(why)")
    }

    private func report(_ msg: String) {
        clog("PEER: file transfer: \(msg)")
        onFailed(msg)
    }

    /// Link went down: abandon everything, delete partial files.
    func reset() {
        queue.async { [self] in
            pending.removeAll()
            if outgoing != nil { finishOutgoing(error: "link dropped") }
            for inc in incoming.values { discard(inc, why: "link dropped") }
            incoming.removeAll()
        }
    }

    /// For selftests: blocks until queued work has run.
    func drain() { queue.sync {} }
}
