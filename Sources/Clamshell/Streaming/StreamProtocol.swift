import Foundation

// Wire format for the custom streaming protocol — see PROTOCOL.md.
// Platform-neutral (Foundation only): compiled into both the Mac host and
// the iOS ClamshellViewer client.

enum StreamMessageType: UInt8 {
    case hello = 0x01
    case helloAck = 0x02
    case clientDisplays = 0x03 // client -> host: display size / second-screen update
    case videoFrame = 0x10
    case keyframeRequest = 0x11
    case audioFrame = 0x13    // host -> client: one AAC-LC packet (fixed 48kHz stereo)
    case mouseMove = 0x20
    case mouseButton = 0x21
    case key = 0x22
    case scroll = 0x23        // client -> host: dx, dy wheel deltas
    case clipboard = 0x30     // both directions: UTF-8 plain text
}

enum StreamCodec: UInt8 {
    case h264 = 1
    case hevc = 2
}

let streamProtocolVersion: UInt8 = 1
let streamDefaultPort: UInt16 = 5903

// MARK: - Big-endian append/read helpers

extension Data {
    mutating func appendBE(_ v: UInt16) { append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xFF)]) }
    mutating func appendBE(_ v: UInt32) {
        append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }
    mutating func appendBE(_ v: UInt64) {
        appendBE(UInt32(v >> 32)); appendBE(UInt32(v & 0xFFFF_FFFF))
    }
    mutating func appendBE(_ v: Float32) { appendBE(v.bitPattern) }

    /// Reads big-endian integers at an offset relative to the data's start.
    func beUInt16(at offset: Int) -> UInt16 {
        let b = self[startIndex + offset ..< startIndex + offset + 2]
        return b.reduce(0) { $0 << 8 | UInt16($1) }
    }
    func beUInt32(at offset: Int) -> UInt32 {
        let b = self[startIndex + offset ..< startIndex + offset + 4]
        return b.reduce(0) { $0 << 8 | UInt32($1) }
    }
    func beUInt64(at offset: Int) -> UInt64 {
        let b = self[startIndex + offset ..< startIndex + offset + 8]
        return b.reduce(0) { $0 << 8 | UInt64($1) }
    }
    func beFloat32(at offset: Int) -> Float32 { Float32(bitPattern: beUInt32(at: offset)) }
}

// MARK: - Message construction

enum StreamMessage {
    static func frame(type: StreamMessageType, payload: Data = Data()) -> Data {
        var d = Data(capacity: 5 + payload.count)
        d.append(type.rawValue)
        d.appendBE(UInt32(payload.count))
        d.append(payload)
        return d
    }

    /// Trailing client-display info (optional — hosts that predate it ignore
    /// the extra bytes): the client's video surface size in pixels, and
    /// whether a second display surface is attached (flags bit 0), which
    /// drives the host's auto dual-display mode.
    static func hello(requestedCodec: StreamCodec,
                      displayInfo: (widthPx: UInt32, heightPx: UInt32, secondDisplay: Bool)? = nil) -> Data {
        var p = Data([streamProtocolVersion, requestedCodec.rawValue])
        if let info = displayInfo {
            p.appendBE(info.widthPx); p.appendBE(info.heightPx)
            p.append(info.secondDisplay ? 1 : 0)
        }
        return frame(type: .hello, payload: p)
    }

    /// Mid-session update of the same info HELLO carries — sent when the
    /// client's external monitor is plugged/unplugged after connecting.
    static func clientDisplays(widthPx: UInt32, heightPx: UInt32, secondDisplay: Bool) -> Data {
        var p = Data()
        p.appendBE(widthPx); p.appendBE(heightPx)
        p.append(secondDisplay ? 1 : 0)
        return frame(type: .clientDisplays, payload: p)
    }

    /// `hardwareEncoder` becomes flags bit 0 (trailing byte; clients that
    /// predate it just ignore the extra byte).
    static func helloAck(codec: StreamCodec, width: UInt32, height: UInt32,
                         hardwareEncoder: Bool) -> Data {
        var p = Data([streamProtocolVersion, codec.rawValue])
        p.appendBE(width); p.appendBE(height)
        p.append(hardwareEncoder ? 1 : 0)
        return frame(type: .helloAck, payload: p)
    }

    /// flags bit 0 = keyframe. `nalData` is AVCC ([4-byte BE length][NAL])*.
    static func videoFrame(keyframe: Bool, ptsMicros: UInt64, nalData: Data) -> Data {
        var p = Data(capacity: 9 + nalData.count)
        p.append(keyframe ? 1 : 0)
        p.appendBE(ptsMicros)
        p.append(nalData)
        return frame(type: .videoFrame, payload: p)
    }

    static func mouseMove(x: Float32, y: Float32) -> Data {
        var p = Data(); p.appendBE(x); p.appendBE(y)
        return frame(type: .mouseMove, payload: p)
    }

    static func mouseButton(button: UInt8, down: Bool, x: Float32, y: Float32) -> Data {
        var p = Data([button, down ? 1 : 0]); p.appendBE(x); p.appendBE(y)
        return frame(type: .mouseButton, payload: p)
    }

    static func key(macKeyCode: UInt16, down: Bool, flags: UInt64) -> Data {
        var p = Data(); p.appendBE(macKeyCode); p.append(down ? 1 : 0); p.appendBE(flags)
        return frame(type: .key, payload: p)
    }

    static func scroll(dx: Float32, dy: Float32) -> Data {
        var p = Data(); p.appendBE(dx); p.appendBE(dy)
        return frame(type: .scroll, payload: p)
    }

    static func audioFrame(_ aac: Data) -> Data { frame(type: .audioFrame, payload: aac) }

    static func clipboard(text: String) -> Data {
        frame(type: .clipboard, payload: Data(text.utf8))
    }
}

// MARK: - Incremental parser

/// Feed raw bytes from the socket; emits complete (type, payload) messages.
/// Unknown message types are skipped (forward compatibility).
final class StreamMessageParser {
    private var buffer = Data()
    /// Cap a single message at 64 MB — anything bigger is a corrupt stream.
    private let maxPayload = 64 << 20

    var onMessage: ((StreamMessageType, Data) -> Void)?
    /// Set when the stream is unrecoverably corrupt; caller should disconnect.
    private(set) var corrupt = false

    func feed(_ data: Data) {
        guard !corrupt else { return }
        buffer.append(data)
        while buffer.count >= 5 {
            let length = Int(buffer.beUInt32(at: 1))
            if length > maxPayload { corrupt = true; return }
            guard buffer.count >= 5 + length else { return }
            let typeByte = buffer[buffer.startIndex]
            let payload = buffer.subdata(in: buffer.startIndex + 5 ..< buffer.startIndex + 5 + length)
            buffer.removeFirst(5 + length)
            if let type = StreamMessageType(rawValue: typeByte) {
                onMessage?(type, payload)
            }
        }
    }
}
