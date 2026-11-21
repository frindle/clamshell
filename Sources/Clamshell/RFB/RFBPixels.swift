import Foundation
import ZlibShim

/// A client's pixel format (RFB section 7.4), 16 bytes on the wire.
struct RFBPixelFormat: Equatable {
    var bitsPerPixel: UInt8
    var depth: UInt8
    var bigEndian: Bool
    var trueColour: Bool
    var redMax: UInt16, greenMax: UInt16, blueMax: UInt16
    var redShift: UInt8, greenShift: UInt8, blueShift: UInt8

    /// What the server announces: 32 bits per pixel, 24 deep, little endian,
    /// blue in the low byte (the order the capture delivers).
    static let standard = RFBPixelFormat(bitsPerPixel: 32, depth: 24, bigEndian: false, trueColour: true,
                                         redMax: 255, greenMax: 255, blueMax: 255,
                                         redShift: 16, greenShift: 8, blueShift: 0)

    var bytes: [UInt8] {
        [bitsPerPixel, depth, bigEndian ? 1 : 0, trueColour ? 1 : 0,
         UInt8(redMax >> 8), UInt8(redMax & 0xFF), UInt8(greenMax >> 8), UInt8(greenMax & 0xFF),
         UInt8(blueMax >> 8), UInt8(blueMax & 0xFF), redShift, greenShift, blueShift, 0, 0, 0]
    }

    static func parse(_ b: [UInt8]) -> RFBPixelFormat? {
        guard b.count >= 16 else { return nil }
        return RFBPixelFormat(bitsPerPixel: b[0], depth: b[1], bigEndian: b[2] != 0, trueColour: b[3] != 0,
                              redMax: UInt16(b[4]) << 8 | UInt16(b[5]),
                              greenMax: UInt16(b[6]) << 8 | UInt16(b[7]),
                              blueMax: UInt16(b[8]) << 8 | UInt16(b[9]),
                              redShift: b[10], greenShift: b[11], blueShift: b[12])
    }

    /// True colour at 8, 16 or 32 bits, with channels that fit the pixel.
    /// Colour-map formats are not served.
    var isSupported: Bool {
        guard trueColour, [8, 16, 32].contains(Int(bitsPerPixel)),
              redMax > 0, greenMax > 0, blueMax > 0 else { return false }
        func fits(_ max: UInt16, _ shift: UInt8) -> Bool {
            let bits = 16 - max.leadingZeroBitCount
            return Int(shift) + bits <= Int(bitsPerPixel)
        }
        return fits(redMax, redShift) && fits(greenMax, greenShift) && fits(blueMax, blueShift)
    }

    var pixelSize: Int { Int(bitsPerPixel) / 8 }

    func value(red: UInt8, green: UInt8, blue: UInt8) -> UInt32 {
        func scale(_ v: UInt8, _ max: UInt16) -> UInt32 { (UInt32(v) * UInt32(max) + 127) / 255 }
        return scale(red, redMax) << UInt32(redShift)
            | scale(green, greenMax) << UInt32(greenShift)
            | scale(blue, blueMax) << UInt32(blueShift)
    }

    func append(_ value: UInt32, to out: inout [UInt8]) {
        switch pixelSize {
        case 1: out.append(UInt8(truncatingIfNeeded: value))
        case 2:
            let hi = UInt8(truncatingIfNeeded: value >> 8), lo = UInt8(truncatingIfNeeded: value)
            if bigEndian { out.append(hi); out.append(lo) } else { out.append(lo); out.append(hi) }
        default:
            let b = [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                     UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
            out.append(contentsOf: bigEndian ? b : b.reversed())
        }
    }

    /// ZRLE writes a "compressed pixel" of 3 bytes for a 32-bit format whose
    /// colour bits all sit in the low three bytes or all in the high three.
    var cpixelBytes: (size: Int, dropFirst: Bool)? {
        guard bitsPerPixel == 32, depth <= 24 else { return nil }
        func top(_ max: UInt16, _ shift: UInt8) -> Int { Int(shift) + (16 - max.leadingZeroBitCount) }
        let highest = max(top(redMax, redShift), top(greenMax, greenShift), top(blueMax, blueShift))
        let lowest = min(redShift, greenShift, blueShift)
        if highest <= 24 { return (3, bigEndian) }       // low three bytes
        if lowest >= 8 { return (3, !bigEndian) }        // high three bytes
        return nil
    }

    func appendCPixel(_ value: UInt32, to out: inout [UInt8]) {
        if let c = cpixelBytes {
            var full: [UInt8] = []
            append(value, to: &full)
            out.append(contentsOf: c.dropFirst ? full[1...3] : full[0...2])
        } else {
            append(value, to: &out)
        }
    }

    func readValue(_ b: ArraySlice<UInt8>) -> UInt32 {
        var v: UInt32 = 0
        let bytes = bigEndian ? Array(b) : Array(b.reversed())
        for x in bytes { v = v << 8 | UInt32(x) }
        return v
    }

    func channels(of v: UInt32) -> (UInt8, UInt8, UInt8) {
        func unscale(_ shift: UInt8, _ max: UInt16) -> UInt8 {
            let c = (v >> UInt32(shift)) & UInt32(max)
            return UInt8((c * 255 + UInt32(max) / 2) / UInt32(max))
        }
        return (unscale(redShift, redMax), unscale(greenShift, greenMax), unscale(blueShift, blueMax))
    }
}

/// A read-only view of one captured frame: 32-bit pixels, blue first in memory.
struct RFBFrameView {
    let base: UnsafePointer<UInt8>
    let bytesPerRow: Int
    let width: Int
    let height: Int

    @inline(__always) func pixel(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let p = base + y * bytesPerRow + x * 4
        return (p[2], p[1], p[0])
    }
}

/// A stateful zlib deflater: the stream lives as long as the connection.
final class RFBDeflater {
    private let handle: UnsafeMutableRawPointer?
    init() { handle = zs_deflate_new() }
    deinit { zs_deflate_free(handle) }

    func compress(_ input: [UInt8]) -> [UInt8]? {
        guard handle != nil else { return nil }
        let cap = input.count + input.count / 50 + 1024
        var out = [UInt8](repeating: 0, count: cap)
        let n = input.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                zs_deflate(handle, src.baseAddress, src.count, dst.baseAddress, dst.count)
            }
        }
        guard n >= 0 else { return nil }
        return Array(out[0..<n])
    }
}

/// The matching inflater, used by the test client and the self-test.
final class RFBInflater {
    private let handle: UnsafeMutableRawPointer?
    init() { handle = zs_inflate_new() }
    deinit { zs_inflate_free(handle) }

    func decompress(_ input: [UInt8], limit: Int) -> [UInt8]? {
        guard handle != nil else { return nil }
        var out = [UInt8](repeating: 0, count: limit)
        let n = input.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                zs_inflate(handle, src.baseAddress, src.count, dst.baseAddress, dst.count)
            }
        }
        guard n >= 0 else { return nil }
        return Array(out[0..<n])
    }
}

/// Rectangle encoders: Raw (0) and ZRLE (16).
enum RFBEncoding {
    static let raw: Int32 = 0
    static let copyRect: Int32 = 1
    static let zrle: Int32 = 16
    static let desktopSize: Int32 = -223

    static func rawRect(_ frame: RFBFrameView, x: Int, y: Int, w: Int, h: Int, format: RFBPixelFormat) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(w * h * format.pixelSize)
        for row in y..<(y + h) {
            for col in x..<(x + w) {
                let p = frame.pixel(col, row)
                format.append(format.value(red: p.r, green: p.g, blue: p.b), to: &out)
            }
        }
        return out
    }

    /// The uncompressed ZRLE tile stream for a rectangle (64x64 tiles from the
    /// rectangle's corner): solid tiles, packed palettes of 2 to 16 colours,
    /// and raw tiles for the rest.
    static func zrleTiles(_ frame: RFBFrameView, x: Int, y: Int, w: Int, h: Int, format: RFBPixelFormat) -> [UInt8] {
        var out: [UInt8] = []
        var ty = 0
        while ty < h {
            let th = min(64, h - ty)
            var tx = 0
            while tx < w {
                let tw = min(64, w - tx)
                encodeTile(frame, x: x + tx, y: y + ty, w: tw, h: th, format: format, into: &out)
                tx += 64
            }
            ty += 64
        }
        return out
    }

    private static func encodeTile(_ frame: RFBFrameView, x: Int, y: Int, w: Int, h: Int,
                                   format: RFBPixelFormat, into out: inout [UInt8]) {
        var values = [UInt32]()
        values.reserveCapacity(w * h)
        var palette: [UInt32] = []
        var overflow = false
        for row in y..<(y + h) {
            for col in x..<(x + w) {
                let p = frame.pixel(col, row)
                let v = format.value(red: p.r, green: p.g, blue: p.b)
                values.append(v)
                if !overflow && !palette.contains(v) {
                    if palette.count == 16 { overflow = true } else { palette.append(v) }
                }
            }
        }
        if !overflow && palette.count == 1 {
            out.append(1)
            format.appendCPixel(palette[0], to: &out)
        } else if !overflow {
            out.append(UInt8(palette.count))
            for v in palette { format.appendCPixel(v, to: &out) }
            let bits = palette.count <= 2 ? 1 : (palette.count <= 4 ? 2 : 4)
            for row in 0..<h {
                var acc = 0, filled = 0
                for col in 0..<w {
                    let idx = palette.firstIndex(of: values[row * w + col]) ?? 0
                    acc = acc << bits | idx
                    filled += bits
                    if filled == 8 { out.append(UInt8(acc)); acc = 0; filled = 0 }
                }
                if filled > 0 { out.append(UInt8(acc << (8 - filled))) }
            }
        } else {
            out.append(0)
            for v in values { format.appendCPixel(v, to: &out) }
        }
    }

    /// The ZRLE rectangle body: a 4-byte length, then zlib data.
    static func zrleRect(_ frame: RFBFrameView, x: Int, y: Int, w: Int, h: Int,
                         format: RFBPixelFormat, deflater: RFBDeflater) -> [UInt8]? {
        let tiles = zrleTiles(frame, x: x, y: y, w: w, h: h, format: format)
        guard let z = deflater.compress(tiles) else { return nil }
        var out = RFBWire.u32(UInt32(z.count))
        out.append(contentsOf: z)
        return out
    }

    /// Decodes a ZRLE rectangle body into RGB triples (client-side; used by
    /// the test client and the self-test).
    static func decodeZRLE(_ body: [UInt8], w: Int, h: Int, format: RFBPixelFormat,
                           inflater: RFBInflater) -> [(UInt8, UInt8, UInt8)]? {
        guard body.count >= 4 else { return nil }
        let length = Int(RFBWire.readU32(body, 0))
        guard body.count == 4 + length,
              let data = inflater.decompress(Array(body[4...]), limit: w * h * 4 * 2 + 65536) else { return nil }
        let cp = format.cpixelBytes?.size ?? format.pixelSize
        var pixels = [(UInt8, UInt8, UInt8)](repeating: (0, 0, 0), count: w * h)
        var pos = 0
        func cpixel() -> (UInt8, UInt8, UInt8)? {
            guard pos + cp <= data.count else { return nil }
            var raw = Array(data[pos..<(pos + cp)])
            pos += cp
            if cp == 3, let c = format.cpixelBytes {
                raw = c.dropFirst ? [0] + raw : raw + [0]
            }
            return format.channels(of: format.readValue(raw[...]))
        }
        var ty = 0
        while ty < h {
            let th = min(64, h - ty)
            var tx = 0
            while tx < w {
                let tw = min(64, w - tx)
                guard pos < data.count else { return nil }
                let sub = Int(data[pos]); pos += 1
                if sub == 0 {
                    for r in 0..<th { for c in 0..<tw {
                        guard let p = cpixel() else { return nil }
                        pixels[(ty + r) * w + tx + c] = p
                    } }
                } else if sub == 1 {
                    guard let p = cpixel() else { return nil }
                    for r in 0..<th { for c in 0..<tw { pixels[(ty + r) * w + tx + c] = p } }
                } else if sub >= 2 && sub <= 16 {
                    var palette: [(UInt8, UInt8, UInt8)] = []
                    for _ in 0..<sub { guard let p = cpixel() else { return nil }; palette.append(p) }
                    let bits = sub <= 2 ? 1 : (sub <= 4 ? 2 : 4)
                    let rowBytes = (tw * bits + 7) / 8
                    for r in 0..<th {
                        guard pos + rowBytes <= data.count else { return nil }
                        for c in 0..<tw {
                            let bitOffset = c * bits
                            let shift = 8 - bits - (bitOffset % 8)
                            let idx = Int(data[pos + bitOffset / 8] >> UInt8(shift)) & ((1 << bits) - 1)
                            guard idx < palette.count else { return nil }
                            pixels[(ty + r) * w + tx + c] = palette[idx]
                        }
                        pos += rowBytes
                    }
                } else {
                    return nil
                }
                tx += 64
            }
            ty += 64
        }
        return pixels
    }
}

/// Big-endian integer helpers for the RFB wire.
enum RFBWire {
    static func u16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    static func u32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
    static func i32(_ v: Int32) -> [UInt8] { u32(UInt32(bitPattern: v)) }
    static func readU16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) << 8 | UInt16(b[o + 1]) }
    static func readU32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }
}
