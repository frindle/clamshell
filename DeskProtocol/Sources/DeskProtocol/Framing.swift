/// `[1 byte type][4-byte big-endian payload length][payload]`, the v1 framing.
public enum Framing {
    /// A frame larger than this is refused by the parser (a hostile length cannot make us buffer without bound).
    public static let maxPayload = 64 * 1024 * 1024

    public static func encode(type: UInt8, payload: [UInt8]) -> [UInt8] {
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
public struct FrameParser {
    private var buffer: [UInt8] = []
    public init() {}

    public mutating func feed(_ chunk: [UInt8]) throws -> [RawFrame] {
        buffer.append(contentsOf: chunk)
        var out: [RawFrame] = []
        var offset = 0
        while buffer.count - offset >= 5 {
            let len = Int(buffer[offset + 1]) << 24 | Int(buffer[offset + 2]) << 16 | Int(buffer[offset + 3]) << 8 | Int(buffer[offset + 4])
            if len > Framing.maxPayload {
                buffer.removeAll()
                throw DecodeError.frameTooLarge(len)
            }
            guard buffer.count - offset - 5 >= len else { break }
            out.append(RawFrame(type: buffer[offset], payload: Array(buffer[(offset + 5)..<(offset + 5 + len)])))
            offset += 5 + len
        }
        if offset > 0 { buffer.removeFirst(offset) }
        return out
    }
}
