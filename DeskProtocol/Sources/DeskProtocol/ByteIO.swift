/// Errors raised while decoding a payload. Decoding never traps on hostile input.
public enum DecodeError: Error, Equatable {
    case truncated
    case stringTooLong
    case tooManyItems
    case treeTooDeep
    case badValue(String)
    case frameTooLarge(Int)
}

/// Errors raised while building a frame.
public enum EncodeError: Error, Equatable {
    case frameTooLarge(Int)
    case unsafeFileName(String)
    /// A string over its length prefix, or a list over its limit. The encoder refuses instead of cutting.
    case stringTooLong(Int)
    case tooManyItems(Int)
    case badValue(String)
}

/// Big-endian writer, matching v1 ("BE" in PROTOCOL.md).
public struct ByteWriter {
    public private(set) var bytes: [UInt8] = []
    public init() {}

    public mutating func u8(_ v: UInt8) { bytes.append(v) }
    public mutating func bool(_ v: Bool) { bytes.append(v ? 1 : 0) }
    public mutating func u16(_ v: UInt16) { bytes.append(UInt8(v >> 8)); bytes.append(UInt8(v & 0xFF)) }
    public mutating func u32(_ v: UInt32) { for s in stride(from: 24, through: 0, by: -8) { bytes.append(UInt8((v >> UInt32(s)) & 0xFF)) } }
    public mutating func u64(_ v: UInt64) { for s in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((v >> UInt64(s)) & 0xFF)) } }
    public mutating func f32(_ v: Float) { u32(v.bitPattern) }
    public mutating func raw(_ b: [UInt8]) { bytes.append(contentsOf: b) }

    /// v2 style string: 1-byte length, at most 255 UTF-8 bytes. Longer input is refused, never cut.
    public mutating func str8(_ s: String) throws {
        let b = Array(s.utf8)
        guard b.count <= 255 else { throw EncodeError.stringTooLong(b.count) }
        u8(UInt8(b.count)); raw(b)
    }
    /// v3 style string: 2-byte length, at most 65535 UTF-8 bytes. Longer input is refused, never cut.
    public mutating func str16(_ s: String) throws {
        let b = Array(s.utf8)
        guard b.count <= 65535 else { throw EncodeError.stringTooLong(b.count) }
        u16(UInt16(b.count)); raw(b)
    }
}

/// Big-endian reader. Every read checks bounds.
public struct ByteReader {
    private let bytes: [UInt8]
    private var pos = 0
    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    public var remaining: Int { bytes.count - pos }

    public mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw DecodeError.truncated }
        defer { pos += 1 }
        return bytes[pos]
    }
    public mutating func bool() throws -> Bool { try u8() != 0 }
    public mutating func u16() throws -> UInt16 {
        guard remaining >= 2 else { throw DecodeError.truncated }
        defer { pos += 2 }
        return UInt16(bytes[pos]) << 8 | UInt16(bytes[pos + 1])
    }
    public mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw DecodeError.truncated }
        var v: UInt32 = 0
        for i in 0..<4 { v = v << 8 | UInt32(bytes[pos + i]) }
        pos += 4
        return v
    }
    public mutating func u64() throws -> UInt64 {
        guard remaining >= 8 else { throw DecodeError.truncated }
        var v: UInt64 = 0
        for i in 0..<8 { v = v << 8 | UInt64(bytes[pos + i]) }
        pos += 8
        return v
    }
    public mutating func f32() throws -> Float {
        let f = Float(bitPattern: try u32())
        guard f.isFinite else { throw DecodeError.badValue("non-finite float") }
        return f
    }
    public mutating func raw(_ n: Int) throws -> [UInt8] {
        guard n >= 0, remaining >= n else { throw DecodeError.truncated }
        defer { pos += n }
        return Array(bytes[pos..<(pos + n)])
    }
    public mutating func rest() -> [UInt8] {
        defer { pos = bytes.count }
        return Array(bytes[pos...])
    }
    public mutating func str8() throws -> String {
        let n = Int(try u8())
        return String(decoding: try raw(n), as: UTF8.self)
    }
    public mutating func str16() throws -> String {
        let n = Int(try u16())
        return String(decoding: try raw(n), as: UTF8.self)
    }
}
