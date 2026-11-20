import Foundation

// Wire format for the custom streaming protocol — see PROTOCOL.md.
// Platform-neutral (Foundation only): compiled into both the Mac host and
// the iOS ClamshellViewer client.

enum StreamMessageType: UInt8 {
    case hello = 0x01
    case helloAck = 0x02
    case clientDisplays = 0x03 // client -> host: display size / second-screen update
    case streamStatus = 0x04   // host -> client: live status (current bitrate)
    case hostLockState = 0x05  // host -> client: screen locked/unlocked (1 byte bool)
    case cursorPos = 0x06      // host -> client: remote cursor position (see "Cursor-follow auto-pan")
    case ping = 0x07           // both directions: empty keepalive; the host echoes the client's
    // 0x08...0x0F belong to the authentication/encryption layer (PROTOCOL.md
    // "Device authentication and encrypted session"); constants only here.
    case authChallenge = 0x08
    case authResponse = 0x09
    case authResult = 0x0A
    case hostInfo = 0x0B
    case clientInfo = 0x0C
    case devicePending = 0x0D
    case deviceDecision = 0x0E
    case secure = 0x0F
    case videoFrame = 0x10
    case keyframeRequest = 0x11
    case videoState = 0x12    // host -> client: video encoder state (0 running, 1 rebuilding, 2 gave up)
    case audioFrame = 0x13    // host -> client: one AAC-LC packet (fixed 48kHz stereo)
    case mouseMove = 0x20
    case mouseButton = 0x21
    case key = 0x22
    case scroll = 0x23        // client -> host: dx, dy wheel deltas
    case mouseRelative = 0x24 // client -> host: dx, dy in points (needs relativeMouse)
    case text = 0x25          // client -> host: UTF-8 text to type (needs textInput)
    case mouseButtonAtCursor = 0x26 // client -> host: button, down; at the host cursor (needs relativeMouse)
    case clipboard = 0x30     // both directions: UTF-8 plain text
    // 0x50...0x54: peripherals attached to the client (needs peripherals).
    case peripheralAttach = 0x50
    case peripheralStatus = 0x51
    case peripheralDetach = 0x52
    case peripheralInput = 0x53
    case peripheralOutput = 0x54
    // 0x58...0x5B: file transfer, both directions (needs fileTransfer).
    case fileOffer = 0x58
    case fileAnswer = 0x59
    case fileData = 0x5A
    case fileEnd = 0x5B
    // 0x60, 0x61: planned restart that skips the disk unlock once (needs restart).
    case restartRequest = 0x60 // client -> host: UTF-8 JSON {"username", "password"}
    case restartResult = 0x61  // host -> client: RestartService.Outcome (1 byte)
}

/// Feature bits exchanged in the handshake (PROTOCOL.md "Capabilities").
struct StreamCapabilities: OptionSet {
    let rawValue: UInt32
    static let approvalRequired = StreamCapabilities(rawValue: 1 << 0)
    static let relativeMouse    = StreamCapabilities(rawValue: 1 << 1)
    static let textInput        = StreamCapabilities(rawValue: 1 << 2)
    static let extraButtons     = StreamCapabilities(rawValue: 1 << 3)
    static let deviceApproval   = StreamCapabilities(rawValue: 1 << 4)
    static let fileTransfer     = StreamCapabilities(rawValue: 1 << 5)
    static let peripherals      = StreamCapabilities(rawValue: 1 << 6)
    static let restart          = StreamCapabilities(rawValue: 1 << 7)
}

enum StreamCodec: UInt8 {
    case h264 = 1
    case hevc = 2
}

let streamProtocolVersion: UInt8 = 1
let streamDefaultPort: UInt16 = 5903

// Window Handoff v1 (see PROTOCOL.md "Window Handoff"): explicit-selection
// single-window streaming reuses this exact protocol/framing unchanged, just
// on its own fixed port (not basePort+index like displays, since windows are
// dynamic — opened/closed/reselected, not a small fixed set).
let windowStreamDefaultPort: UInt16 = 5920

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
    /// drives the host's auto dual-display mode. When a second display is
    /// attached its own pixel size is appended too (secondSize), so the host
    /// sizes Display B to the real external monitor instead of a fixed preset.
    static func hello(requestedCodec: StreamCodec,
                      displayInfo: (widthPx: UInt32, heightPx: UInt32, secondDisplay: Bool)? = nil,
                      secondSize: (widthPx: UInt32, heightPx: UInt32)? = nil) -> Data {
        var p = Data([streamProtocolVersion, requestedCodec.rawValue])
        if let info = displayInfo {
            appendDisplayInfo(&p, info, secondSize)
        }
        return frame(type: .hello, payload: p)
    }

    /// Mid-session update of the same info HELLO carries — sent when the
    /// client's external monitor is plugged/unplugged after connecting.
    static func clientDisplays(widthPx: UInt32, heightPx: UInt32, secondDisplay: Bool,
                               secondSize: (widthPx: UInt32, heightPx: UInt32)? = nil) -> Data {
        var p = Data()
        appendDisplayInfo(&p, (widthPx, heightPx, secondDisplay), secondSize)
        return frame(type: .clientDisplays, payload: p)
    }

    private static func appendDisplayInfo(_ p: inout Data,
                                          _ info: (widthPx: UInt32, heightPx: UInt32, secondDisplay: Bool),
                                          _ secondSize: (widthPx: UInt32, heightPx: UInt32)?) {
        p.appendBE(info.widthPx); p.appendBE(info.heightPx)
        p.append(info.secondDisplay ? 1 : 0)
        if info.secondDisplay, let s = secondSize {
            p.appendBE(s.widthPx); p.appendBE(s.heightPx)
        }
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

    /// Pointer movement in points for a captured pointer (needs `relativeMouse`).
    static func mouseRelative(dx: Float32, dy: Float32) -> Data {
        var p = Data(); p.appendBE(dx); p.appendBE(dy)
        return frame(type: .mouseRelative, payload: p)
    }

    /// A press or release where the host cursor is now, for a captured pointer
    /// (needs `relativeMouse`).
    static func mouseButtonAtCursor(button: UInt8, down: Bool) -> Data {
        frame(type: .mouseButtonAtCursor, payload: Data([button, down ? 1 : 0]))
    }

    /// Text to type as-is (needs `textInput`); the host refuses more than 16 KB.
    static func text(_ s: String) -> Data {
        frame(type: .text, payload: Data(s.utf8))
    }

    static func audioFrame(_ aac: Data) -> Data { frame(type: .audioFrame, payload: aac) }

    /// Live stream status for the client's quality indicator: current encoder
    /// target bitrate in kbps (see PROTOCOL.md "Connection quality").
    static func streamStatus(bitrateKbps: UInt16) -> Data {
        var p = Data(); p.appendBE(bitrateKbps)
        return frame(type: .streamStatus, payload: p)
    }

    static func clipboard(text: String) -> Data {
        frame(type: .clipboard, payload: Data(text.utf8))
    }

    /// Host screen lock state — native capture can't survive the macOS lock
    /// screen, so the client shows the browser-VNC fallback banner when locked.
    ///
    /// `native` is the host's `nativeLockScreen` setting. When on, a second
    /// payload byte of 1 tells the client to keep showing the native stream
    /// (banner only, never the browser VNC fallback). When off the payload is
    /// the original single byte, so older clients and the default are unchanged.
    static func hostLockState(_ locked: Bool, native: Bool = false) -> Data {
        frame(type: .hostLockState, payload: native ? Data([locked ? 1 : 0, 1]) : Data([locked ? 1 : 0]))
    }

    /// The host setting `nativeLockScreen` (UserDefaults, default off).
    static func nativeLockScreenEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: "nativeLockScreen")
    }

    /// Remote cursor position, normalized 0..1 in this display's source-frame
    /// space (same convention as INPUT_MOUSE_MOVE), origin top-left. Drives
    /// client-side cursor-follow auto-pan — see "Cursor-follow auto-pan" in
    /// PROTOCOL.md. Values can fall outside 0...1 (cursor is on a different
    /// display than this connection); the client treats that as "not visible
    /// here" and skips auto-pan.
    static func cursorPos(x: Float32, y: Float32) -> Data {
        var p = Data(); p.appendBE(x); p.appendBE(y)
        return frame(type: .cursorPos, payload: p)
    }
}

// MARK: - Input message decoding

/// The client-to-host input messages (0x20-0x26), decoded from their payloads.
/// Pure: only the length checks and field reads live here. What a host does
/// with the values (clamping, dropping non-finite numbers) is up to the caller.
enum InputMessage {
    case mouseMove(x: Float32, y: Float32)
    case mouseButton(button: UInt8, down: Bool, x: Float32, y: Float32)
    case key(macKeyCode: UInt16, down: Bool, flags: UInt64)
    case scroll(dx: Float32, dy: Float32)
    case mouseRelative(dx: Float32, dy: Float32)
    case mouseButtonAtCursor(button: UInt8, down: Bool)
    case text(Data)

    /// Nil for a payload shorter than its layout needs and for any other
    /// message type. Extra trailing bytes are skipped.
    static func decode(type: StreamMessageType, payload: Data) -> InputMessage? {
        let s = payload.startIndex
        switch type {
        case .mouseMove:
            guard payload.count >= 8 else { return nil }
            return .mouseMove(x: payload.beFloat32(at: 0), y: payload.beFloat32(at: 4))
        case .mouseButton:
            guard payload.count >= 10 else { return nil }
            return .mouseButton(button: payload[s], down: payload[s + 1] == 1,
                                x: payload.beFloat32(at: 2), y: payload.beFloat32(at: 6))
        case .key:
            guard payload.count >= 11 else { return nil }
            return .key(macKeyCode: payload.beUInt16(at: 0), down: payload[s + 2] == 1,
                        flags: payload.beUInt64(at: 3))
        case .scroll:
            guard payload.count >= 8 else { return nil }
            return .scroll(dx: payload.beFloat32(at: 0), dy: payload.beFloat32(at: 4))
        case .mouseRelative:
            guard payload.count >= 8 else { return nil }
            return .mouseRelative(dx: payload.beFloat32(at: 0), dy: payload.beFloat32(at: 4))
        case .mouseButtonAtCursor:
            guard payload.count >= 2 else { return nil }
            return .mouseButtonAtCursor(button: payload[s], down: payload[s + 1] == 1)
        case .text:
            return .text(payload)
        default:
            return nil
        }
    }
}

// MARK: - Incremental parser

/// Feed raw bytes from the socket; emits complete (type, payload) messages.
/// Unknown message types are skipped (forward compatibility).
final class StreamMessageParser {
    private var buffer = Data()
    /// Default cap for a single message: 64 MB — anything bigger is a corrupt stream.
    static let defaultMaxPayload = 64 << 20
    /// Settable so a host can read a small cap before a connection has
    /// authenticated and the normal one after.
    var maxPayload: Int

    init(maxPayload: Int = StreamMessageParser.defaultMaxPayload) {
        self.maxPayload = maxPayload
    }

    var onMessage: ((StreamMessageType, Data) -> Void)?
    /// A whole message whose type this build does not know. It is skipped
    /// either way; a caller that must not skip one (an encrypted session, where
    /// everything is SECURE) sets this to hear about it.
    var onUnknown: ((UInt8) -> Void)?
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
            } else {
                onUnknown?(typeByte)
            }
        }
    }
}
