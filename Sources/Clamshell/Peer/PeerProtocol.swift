import Foundation

// Peer link wire messages (PROTOCOL.md "Peer link (v2)") — the Synergy-style
// shared-desk feature set between two paired machines: pairing/auth, edge
// crossing (shared mouse+keyboard), clipboard, file transfer and window
// handoff negotiation. Same framing as everything else
// ([type][len BE][payload]), same big-endian helpers, on its own control
// connection (port 5910). Input while controlling a peer reuses the v1
// INPUT_* messages (0x20–0x23) unchanged; window video rides a normal v1
// window stream the handoff negotiates a port for.
//
// Foundation-only, like StreamProtocol.swift: nothing here touches AppKit,
// so the parsers can be exercised by `clamshell peer-protocol-selftest`
// without a display, and the byte layout is mirrored 1:1 in
// WindowsServer/PeerProtocol.cs.

let peerProtocolVersion: UInt8 = 2
let peerLinkDefaultPort: UInt16 = 5910
/// Bonjour/mDNS service both hosts advertise and browse.
let peerServiceType = "_clamshell-peer._tcp"

/// Bounds enforced on every peer-supplied field — the peer is authenticated
/// but still a different machine, so nothing it sends sizes a buffer.
enum PeerLimits {
    static let maxName = 128            // display names, app names, titles (bytes)
    static let maxFileName = 255        // after sanitization
    static let maxFileSize: UInt64 = 8 << 30
    static let chunkSize = 128 << 10    // FILE_CHUNK payload bytes
    static let maxClipboardBytes = 32 << 20
    static let nonceSize = 32
    static let publicKeySize = 65       // X9.63 uncompressed P-256 point
    static let signatureSize = 64       // raw r||s
    static let proofSize = 32           // HMAC-SHA256
}

/// Screen edge, from the point of view of the machine whose screen it is.
enum PeerEdge: UInt8 {
    case left = 0, right = 1, top = 2, bottom = 3
    /// The edge the cursor arrives on when it leaves this one on the peer.
    var opposite: PeerEdge {
        switch self {
        case .left: return .right
        case .right: return .left
        case .top: return .bottom
        case .bottom: return .top
        }
    }
    var name: String {
        switch self {
        case .left: return "left"
        case .right: return "right"
        case .top: return "top"
        case .bottom: return "bottom"
        }
    }
}

enum PeerHelloStatus: UInt8 {
    case ok = 0
    case untrusted = 1      // unknown key and no PIN proof — pair first
    case badPin = 2
    case badSignature = 3
    case busy = 4           // already linked to another peer
    case version = 5
}

enum PeerRejectReason: UInt8 {
    case user = 0, error = 1, tooLarge = 2, disk = 3, unsupported = 4, busy = 5
}

// MARK: - Parsed message structs

struct PeerHelloPayload {
    let flags: UInt8
    let publicKey: Data      // 65 bytes
    let clientNonce: Data    // 32 bytes
    let signature: Data      // 64 bytes over serverNonce || publicKey
    let pinProof: Data?      // 32 bytes HMAC over serverNonce || publicKey
    let name: String
    let screenWidth: UInt32
    let screenHeight: UInt32
}

struct PeerHelloAckPayload {
    let status: PeerHelloStatus
    let publicKey: Data
    let signature: Data      // over clientNonce || publicKey
    let pinProof: Data?
    let name: String
    let screenWidth: UInt32
    let screenHeight: UInt32
}

struct EdgeEnterPayload {
    let edge: PeerEdge       // edge of the CONTROLLED screen the cursor enters on
    let x: Float32, y: Float32
    let leftButtonDown: Bool
}

struct HandoffBeginPayload {
    let windowId: UInt32
    let edge: PeerEdge       // edge of the RECEIVER's screen it should appear at
    let position: Float32    // 0...1 along that edge (cursor's projection)
    let grabX: Float32, grabY: Float32 // where within the window the cursor holds it
    let width: UInt32, height: UInt32
    let streamPort: UInt16
    let title: String
    let appName: String
}

struct HandoffReturnPayload {
    let windowId: UInt32
    let edge: PeerEdge?      // nil = restore to original position
    let position: Float32
}

struct FileOfferPayload {
    let transferId: UInt32
    let size: UInt64
    let name: String         // raw, NOT yet sanitized
}

struct FileChunkPayload {
    let transferId: UInt32
    let offset: UInt64
    let bytes: Data
}

// MARK: - Builders

extension StreamMessage {
    static func peerChallenge(nonce: Data) -> Data {
        frame(type: .peerChallenge, payload: nonce)
    }

    static func peerHello(publicKey: Data, clientNonce: Data, signature: Data, pinProof: Data?,
                          name: String, screenWidth: UInt32, screenHeight: UInt32) -> Data {
        var p = Data([peerProtocolVersion, pinProof == nil ? 0 : 1])
        p.append(publicKey); p.append(clientNonce); p.append(signature)
        if let pinProof { p.append(pinProof) }
        p.appendString(name)
        p.appendBE(screenWidth); p.appendBE(screenHeight)
        return frame(type: .peerHello, payload: p)
    }

    static func peerHelloAck(status: PeerHelloStatus, publicKey: Data = Data(), signature: Data = Data(),
                             pinProof: Data? = nil, name: String = "",
                             screenWidth: UInt32 = 0, screenHeight: UInt32 = 0) -> Data {
        var p = Data([peerProtocolVersion, status.rawValue])
        if status == .ok {
            p.append(publicKey); p.append(signature)
            p.append(pinProof == nil ? 0 : 1)
            if let pinProof { p.append(pinProof) }
            p.appendString(name)
            p.appendBE(screenWidth); p.appendBE(screenHeight)
        }
        return frame(type: .peerHelloAck, payload: p)
    }

    static func edgeEnter(edge: PeerEdge, x: Float32, y: Float32, leftButtonDown: Bool) -> Data {
        var p = Data([edge.rawValue]); p.appendBE(x); p.appendBE(y); p.append(leftButtonDown ? 1 : 0)
        return frame(type: .edgeEnter, payload: p)
    }

    static func edgeLeave() -> Data { frame(type: .edgeLeave) }

    /// kind 1 = PNG image. (Text uses the v1 CLIPBOARD message.)
    static func clipboardData(kind: UInt8, bytes: Data) -> Data {
        var p = Data([kind]); p.append(bytes)
        return frame(type: .clipboardData, payload: p)
    }

    static func handoffBegin(_ h: HandoffBeginPayload) -> Data {
        var p = Data(); p.appendBE(h.windowId); p.append(h.edge.rawValue)
        p.appendBE(h.position); p.appendBE(h.grabX); p.appendBE(h.grabY)
        p.appendBE(h.width); p.appendBE(h.height); p.appendBE(h.streamPort)
        p.appendString(h.title); p.appendString(h.appName)
        return frame(type: .handoffBegin, payload: p)
    }

    static func handoffAccept(windowId: UInt32) -> Data {
        var p = Data(); p.appendBE(windowId)
        return frame(type: .handoffAccept, payload: p)
    }

    static func handoffReject(windowId: UInt32, reason: PeerRejectReason) -> Data {
        var p = Data(); p.appendBE(windowId); p.append(reason.rawValue)
        return frame(type: .handoffReject, payload: p)
    }

    static func handoffReturn(windowId: UInt32, edge: PeerEdge?, position: Float32) -> Data {
        var p = Data(); p.appendBE(windowId); p.append(edge?.rawValue ?? 0xFF); p.appendBE(position)
        return frame(type: .handoffReturn, payload: p)
    }

    static func windowClosed(windowId: UInt32) -> Data {
        var p = Data(); p.appendBE(windowId)
        return frame(type: .windowClosed, payload: p)
    }

    static func fileOffer(transferId: UInt32, size: UInt64, name: String) -> Data {
        var p = Data(); p.appendBE(transferId); p.appendBE(size); p.appendString(name)
        return frame(type: .fileOffer, payload: p)
    }

    static func fileAccept(transferId: UInt32) -> Data {
        var p = Data(); p.appendBE(transferId)
        return frame(type: .fileAccept, payload: p)
    }

    static func fileReject(transferId: UInt32, reason: PeerRejectReason) -> Data {
        var p = Data(); p.appendBE(transferId); p.append(reason.rawValue)
        return frame(type: .fileReject, payload: p)
    }

    static func fileChunk(transferId: UInt32, offset: UInt64, bytes: Data) -> Data {
        var p = Data(capacity: 12 + bytes.count); p.appendBE(transferId); p.appendBE(offset); p.append(bytes)
        return frame(type: .fileChunk, payload: p)
    }

    static func fileDone(transferId: UInt32, sha256: Data) -> Data {
        var p = Data(); p.appendBE(transferId); p.append(sha256)
        return frame(type: .fileDone, payload: p)
    }

    static func fileCancel(transferId: UInt32, reason: PeerRejectReason) -> Data {
        var p = Data(); p.appendBE(transferId); p.append(reason.rawValue)
        return frame(type: .fileCancel, payload: p)
    }
}

extension Data {
    /// Length-prefixed (u16 BE) UTF-8 string, truncated to PeerLimits.maxName
    /// bytes on a character boundary so a long window title never exceeds it.
    mutating func appendString(_ s: String) {
        var bytes = Data(s.utf8)
        if bytes.count > PeerLimits.maxName {
            // Whole characters only (a byte cut could split a scalar); every
            // character is at least one byte, so start from the first 128.
            var cut = String(s.prefix(PeerLimits.maxName))
            while cut.utf8.count > PeerLimits.maxName { cut.removeLast() }
            bytes = Data(cut.utf8)
        }
        appendBE(UInt16(bytes.count)); append(bytes)
    }
}

// MARK: - Parsers (every one bounds-checks; nil = malformed, caller drops peer)

/// Cursor over a payload; every read is checked against the remaining bytes.
struct PeerReader {
    private let d: Data
    private(set) var offset = 0
    init(_ d: Data) { self.d = d }
    var remaining: Int { d.count - offset }

    mutating func u8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return d[d.startIndex + offset]
    }
    mutating func u16() -> UInt16? {
        guard remaining >= 2 else { return nil }
        defer { offset += 2 }
        return d.beUInt16(at: offset)
    }
    mutating func u32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        defer { offset += 4 }
        return d.beUInt32(at: offset)
    }
    mutating func u64() -> UInt64? {
        guard remaining >= 8 else { return nil }
        defer { offset += 8 }
        return d.beUInt64(at: offset)
    }
    mutating func f32() -> Float32? {
        guard let bits = u32() else { return nil }
        let f = Float32(bitPattern: bits)
        return f.isFinite ? f : nil
    }
    mutating func bytes(_ n: Int) -> Data? {
        guard n >= 0, remaining >= n else { return nil }
        defer { offset += n }
        return d.subdata(in: d.startIndex + offset ..< d.startIndex + offset + n)
    }
    mutating func rest() -> Data { bytes(remaining) ?? Data() }
    /// u16-prefixed UTF-8, capped at PeerLimits.maxName; invalid UTF-8 or
    /// control characters are rejected rather than laundered.
    mutating func string() -> String? {
        guard let n = u16(), Int(n) <= PeerLimits.maxName, let b = bytes(Int(n)),
              let s = String(data: b, encoding: .utf8),
              s.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else { return nil }
        return s
    }
}

enum PeerParse {
    static func hello(_ p: Data) -> PeerHelloPayload? {
        var r = PeerReader(p)
        guard let ver = r.u8(), ver == peerProtocolVersion, let flags = r.u8(),
              let key = r.bytes(PeerLimits.publicKeySize), key.first == 0x04,
              let nonce = r.bytes(PeerLimits.nonceSize),
              let sig = r.bytes(PeerLimits.signatureSize) else { return nil }
        var proof: Data?
        if flags & 1 == 1 { guard let pr = r.bytes(PeerLimits.proofSize) else { return nil }; proof = pr }
        guard let name = r.string(), let w = r.u32(), let h = r.u32() else { return nil }
        return PeerHelloPayload(flags: flags, publicKey: key, clientNonce: nonce, signature: sig,
                                pinProof: proof, name: name, screenWidth: w, screenHeight: h)
    }

    static func helloAck(_ p: Data) -> PeerHelloAckPayload? {
        var r = PeerReader(p)
        guard let ver = r.u8(), ver == peerProtocolVersion, let s = r.u8(),
              let status = PeerHelloStatus(rawValue: s) else { return nil }
        guard status == .ok else {
            return PeerHelloAckPayload(status: status, publicKey: Data(), signature: Data(), pinProof: nil,
                                       name: "", screenWidth: 0, screenHeight: 0)
        }
        guard let key = r.bytes(PeerLimits.publicKeySize), key.first == 0x04,
              let sig = r.bytes(PeerLimits.signatureSize), let hasProof = r.u8() else { return nil }
        var proof: Data?
        if hasProof == 1 { guard let pr = r.bytes(PeerLimits.proofSize) else { return nil }; proof = pr }
        guard let name = r.string(), let w = r.u32(), let h = r.u32() else { return nil }
        return PeerHelloAckPayload(status: status, publicKey: key, signature: sig, pinProof: proof,
                                   name: name, screenWidth: w, screenHeight: h)
    }

    static func edgeEnter(_ p: Data) -> EdgeEnterPayload? {
        var r = PeerReader(p)
        guard let e = r.u8(), let edge = PeerEdge(rawValue: e), let x = r.f32(), let y = r.f32(),
              let down = r.u8() else { return nil }
        return EdgeEnterPayload(edge: edge, x: x, y: y, leftButtonDown: down == 1)
    }

    static func clipboardData(_ p: Data) -> (kind: UInt8, bytes: Data)? {
        var r = PeerReader(p)
        guard let kind = r.u8(), r.remaining <= PeerLimits.maxClipboardBytes else { return nil }
        return (kind, r.rest())
    }

    static func handoffBegin(_ p: Data) -> HandoffBeginPayload? {
        var r = PeerReader(p)
        guard let id = r.u32(), let e = r.u8(), let edge = PeerEdge(rawValue: e),
              let pos = r.f32(), let gx = r.f32(), let gy = r.f32(),
              let w = r.u32(), let h = r.u32(), w >= 1, h >= 1, w <= 16384, h <= 16384,
              let port = r.u16(), port > 0,
              let title = r.string(), let app = r.string() else { return nil }
        return HandoffBeginPayload(windowId: id, edge: edge, position: min(max(pos, 0), 1),
                                   grabX: min(max(gx, 0), 1), grabY: min(max(gy, 0), 1),
                                   width: w, height: h, streamPort: port, title: title, appName: app)
    }

    static func windowId(_ p: Data) -> UInt32? {
        var r = PeerReader(p); return r.u32()
    }

    static func idAndReason(_ p: Data) -> (id: UInt32, reason: PeerRejectReason)? {
        var r = PeerReader(p)
        guard let id = r.u32(), let b = r.u8() else { return nil }
        return (id, PeerRejectReason(rawValue: b) ?? .error)
    }

    static func handoffReturn(_ p: Data) -> HandoffReturnPayload? {
        var r = PeerReader(p)
        guard let id = r.u32(), let e = r.u8(), let pos = r.f32() else { return nil }
        if e != 0xFF && PeerEdge(rawValue: e) == nil { return nil }
        return HandoffReturnPayload(windowId: id, edge: PeerEdge(rawValue: e), position: min(max(pos, 0), 1))
    }

    static func fileOffer(_ p: Data) -> FileOfferPayload? {
        var r = PeerReader(p)
        guard let id = r.u32(), let size = r.u64(), let name = r.string() else { return nil }
        return FileOfferPayload(transferId: id, size: size, name: name)
    }

    static func fileChunk(_ p: Data) -> FileChunkPayload? {
        var r = PeerReader(p)
        guard let id = r.u32(), let off = r.u64(), r.remaining <= PeerLimits.chunkSize else { return nil }
        return FileChunkPayload(transferId: id, offset: off, bytes: r.rest())
    }

    static func fileDone(_ p: Data) -> (id: UInt32, sha256: Data)? {
        var r = PeerReader(p)
        guard let id = r.u32(), let hash = r.bytes(32) else { return nil }
        return (id, hash)
    }
}

// MARK: - File name sanitization (receiver side)

enum PeerFileNames {
    /// Reduces a peer-supplied name to a single safe path component: last
    /// component only (both separator styles), control characters and
    /// reserved punctuation replaced, no leading dots (no hidden files, no
    /// ".."), Windows-reserved device names de-fanged, length capped, and
    /// never empty. The result is only ever joined onto the Downloads folder.
    static func sanitize(_ raw: String) -> String {
        var name = raw
        if let slash = name.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            name = String(name[name.index(after: slash)...])
        }
        name = String(name.unicodeScalars.map { s -> Character in
            if s.value < 0x20 || s.value == 0x7F { return "_" }
            if s == ":" || s == "*" || s == "?" || s == "\"" || s == "<" || s == ">" || s == "|" { return "_" }
            return Character(s)
        })
        name = name.trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        while name.hasSuffix(".") || name.hasSuffix(" ") { name.removeLast() }
        let stem = name.split(separator: ".", maxSplits: 1).first.map(String.init)?.uppercased() ?? ""
        let reserved: Set<String> = ["CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6",
                                     "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6",
                                     "LPT7", "LPT8", "LPT9"]
        if reserved.contains(stem) { name = "_" + name }
        if name.utf8.count > PeerLimits.maxFileName {
            let ext = (name as NSString).pathExtension
            var base = (name as NSString).deletingPathExtension
            let room = PeerLimits.maxFileName - (ext.isEmpty ? 0 : ext.utf8.count + 1)
            while base.utf8.count > max(room, 1) { base.removeLast() }
            name = ext.isEmpty ? base : base + "." + ext
        }
        if name.isEmpty { name = "clamshell-transfer" }
        return name
    }

    /// "name.ext" -> "name (2).ext" ... until no file exists at that path.
    static func uniqueURL(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        var n = 2
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        while fm.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            candidate = dir.appendingPathComponent(next)
            n += 1
        }
        return candidate
    }
}
