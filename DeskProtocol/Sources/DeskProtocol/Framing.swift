/// `[1 byte type][4-byte big-endian payload length][payload]`, the v1 framing.
public enum Framing {
    /// A frame larger than this is refused by both encoder and parser. It sits under the v1 limit of 4 MB (4,194,304
    /// bytes) on a SECURE payload, with room for the envelope, because every frame travels inside SECURE and a larger
    /// one would close the session. Big things (clipboard data) are sent in chunks, never as one frame.
    public static let maxPayload = 4_000_000

    /// Refuses a payload over `maxPayload`: the peer would treat the frame as fatal.
    public static func encode(type: UInt8, payload: [UInt8]) throws -> [UInt8] {
        guard payload.count <= maxPayload else { throw EncodeError.frameTooLarge(payload.count) }
        var w = ByteWriter()
        w.u8(type); w.u32(UInt32(payload.count)); w.raw(payload)
        return w.bytes
    }
}

public struct RawFrame: Equatable {
    public let type: UInt8
    public let payload: [UInt8]
    public init(type: UInt8, payload: [UInt8]) { self.type = type; self.payload = payload }
}

/// Accepts arbitrary byte chunks and yields whole frames, as the v1 parser does.
/// An oversize length is fatal: the stream cannot be resynchronised, so after it every `feed` throws
/// and the caller must close the connection.
public struct FrameParser {
    private var buffer: [UInt8] = []
    private var head = 0          // start of unread bytes; consumed bytes are dropped in bulk, not per frame
    private var failedWith: Int?
    public init() {}

    public mutating func feed(_ chunk: [UInt8]) throws -> [RawFrame] {
        if let n = failedWith { throw DecodeError.frameTooLarge(n) }
        buffer.append(contentsOf: chunk)
        var out: [RawFrame] = []
        while buffer.count - head >= 5 {
            let o = head
            let len = Int(buffer[o + 1]) << 24 | Int(buffer[o + 2]) << 16 | Int(buffer[o + 3]) << 8 | Int(buffer[o + 4])
            if len > Framing.maxPayload {
                buffer.removeAll(); head = 0
                failedWith = len
                throw DecodeError.frameTooLarge(len)
            }
            guard buffer.count - o - 5 >= len else { break }
            out.append(RawFrame(type: buffer[o], payload: Array(buffer[(o + 5)..<(o + 5 + len)])))
            head += 5 + len
        }
        if head == buffer.count { buffer.removeAll(keepingCapacity: true); head = 0 }
        else if head >= 65536 { buffer.removeSubrange(0..<head); head = 0 }
        return out
    }
}
