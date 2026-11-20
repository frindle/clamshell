/// Clipboard data is sent as a run of PASTEBOARD_DATA messages of at most `Limits.maxPasteboardChunk` bytes, in order,
/// so video, audio and input are never held up behind one large frame (and no frame nears the 4 MB SECURE limit).
public enum PasteboardChunker {
    public static func chunks(generation: UInt32, uti: String, data: [UInt8]) throws -> [DeskMessage] {
        guard UInt64(data.count) <= Limits.maxPasteboardBytes else { throw EncodeError.badValue("clipboard item too large") }
        let total = UInt64(data.count)
        if data.isEmpty { return [.pasteboardData(generation: generation, uti: uti, offset: 0, total: 0, data: [])] }
        var out: [DeskMessage] = []
        var off = 0
        while off < data.count {
            let end = min(data.count, off + Limits.maxPasteboardChunk)
            out.append(.pasteboardData(generation: generation, uti: uti, offset: UInt64(off), total: total, data: Array(data[off..<end])))
            off = end
        }
        return out
    }
}

/// Puts the chunks of one fetched item back together. The receiver knows the size from the offer it is answering
/// and refuses a chunk that disagrees, skips ahead, repeats, or runs past the end.
public struct PasteboardAssembler {
    public let generation: UInt32
    public let uti: String
    public let expectedSize: UInt64
    private var buffer: [UInt8] = []
    public init(generation: UInt32, uti: String, expectedSize: UInt64) {
        self.generation = generation; self.uti = uti; self.expectedSize = expectedSize
    }

    /// Returns the whole item once the last chunk arrives, nil while more are due.
    public mutating func add(_ m: DeskMessage) throws -> [UInt8]? {
        guard case .pasteboardData(let g, let u, let off, let total, let data) = m else { throw DecodeError.badValue("not clipboard data") }
        guard g == generation, u == uti, total == expectedSize else { throw DecodeError.badValue("clipboard chunk does not match the request") }
        guard off == UInt64(buffer.count) else { throw DecodeError.badValue("clipboard chunk out of order") }
        guard UInt64(buffer.count + data.count) <= expectedSize else { throw DecodeError.badValue("clipboard chunk past the end") }
        buffer.append(contentsOf: data)
        return UInt64(buffer.count) == expectedSize ? buffer : nil
    }
}
