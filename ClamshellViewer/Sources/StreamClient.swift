import Foundation
import CoreMedia
import UIKit

// WebSocket protocol client shared by both iOS targets (ClamshellViewer on
// iPad, ClamshellControl on iPhone): connect, parse framed messages, assemble
// video samples, play audio, forward input, sync clipboard, auto-reconnect.

final class StreamClient: ObservableObject {
    enum Status: Equatable {
        case idle, connecting, streaming(String), failed(String)
    }

    @Published var status: Status = .idle
    @Published var videoSize: CGSize = .zero
    /// True when HELLO_ACK reported the host is encoding in SOFTWARE (no
    /// hardware encoder) — surfaced as a warning banner in the UI.
    @Published var softwareEncoding = false
    /// Host's current encoder target (kbps) from STREAM_STATUS; 0 = not yet
    /// reported. Drives the connection-quality dot / Nerd Mode readout.
    @Published var currentBitrateKbps: UInt16 = 0
    /// Negotiated codec name ("HEVC"/"H.264") from HELLO_ACK, for Nerd Mode.
    @Published var codecName = ""
    /// Human-readable reason for the most recent connection failure, surfaced
    /// on-screen while auto-reconnect keeps retrying. nil once streaming.
    @Published var lastError: String?

    /// Whether audio plays through this client. Only the primary (iPad-screen)
    /// client plays audio; the external-display client stays muted.
    var playsAudio = true

    /// This client's video surface size in pixels, reported to the host in
    /// HELLO so it can auto-size its virtual display to the device (instead
    /// of a manually picked preset). nil = report nothing (older behavior).
    var reportedPixelSize: CGSize?
    /// Whether a second display surface is attached client-side (external
    /// monitor on the iPad) — drives the host's auto dual-display mode.
    var reportsSecondDisplay = false
    /// The attached second display surface's pixel size (external monitor on
    /// the iPad) — reported alongside the flag so the host sizes Display B to
    /// the real monitor instead of a fixed preset. nil = size unknown.
    var reportedSecondPixelSize: CGSize?
    /// Called with received clipboard text (main thread).
    var onClipboard: ((String) -> Void)?

    /// Decoded-ready compressed samples for the display layer. Called on the
    /// network queue; AVSampleBufferDisplayLayer enqueue is thread-safe.
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var parser: StreamMessageParser?
    private var assembler: FrameAssembler?
    private let audio = AudioPlayer()

    // Retained connection parameters for automatic reconnection.
    private var connectHost: String?
    private var wantConnection = false
    private var reconnectAttempt = 0
    /// Last clipboard text seen in either direction — breaks the echo loop.
    private var lastClipboard: String?

    /// Accepts a bare host ("192.168.1.5" -> ws://192.168.1.5:5903) or a full
    /// ws:// / wss:// URL (Cloudflare Tunnel: wss://mac.example.com/stream).
    func connect(host: String) {
        wantConnection = true
        lastError = nil
        connectHost = host
        openSocket()
    }

    /// Maps a URLSession failure to a short reason a user can act on without
    /// opening Console.app: Cloudflare Access rejection vs. unreachable host
    /// vs. wrong address, distinguished by HTTP status and NSURLError code.
    static func friendlyError(_ error: Error, response: URLResponse?) -> String {
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 401, 403: return "Access denied (HTTP \(http.statusCode)) — check the Cloudflare Access token."
            case 302, 400..<500: return "Connection rejected (HTTP \(http.statusCode)) — check the URL / Cloudflare Access."
            case 500...: return "Host error (HTTP \(http.statusCode)) — the Mac rejected the stream."
            default: break
            }
        }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return ns.localizedDescription }
        switch ns.code {
        case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost:
            return "Can't reach the Mac — is it on this network and is Native Streaming enabled?"
        case NSURLErrorTimedOut:
            return "Connection timed out — check the address and that the Mac is awake."
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "Can't find that host — check the address."
        case NSURLErrorNotConnectedToInternet:
            return "This device is offline."
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            return "TLS failed — check the wss:// URL / Cloudflare Tunnel."
        default:
            return "Connection failed: \(ns.localizedDescription)"
        }
    }

    private func openSocket() {
        teardownSocket()
        guard let host = connectHost else { return }
        let urlString = host.contains("://") ? host : "ws://\(host):\(streamDefaultPort)"
        guard let url = URL(string: urlString) else {
            clogViewer("connect FAILED: invalid address '\(urlString)'")
            status = .failed("invalid address")
            return
        }
        clogViewer("connecting to \(urlString)")
        status = .connecting

        let parser = StreamMessageParser()
        parser.onMessage = { [weak self] type, payload in self?.handle(type: type, payload: payload) }
        self.parser = parser

        let task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = 64 << 20 // keyframes at full display resolution
        self.task = task
        task.resume()
        // URLSession queues sends until the handshake completes.
        task.send(.data(StreamMessage.hello(requestedCodec: .hevc, displayInfo: displayInfoPayload,
                                            secondSize: secondSizePayload))) { _ in }
        receiveLoop(task)
    }

    /// The wire form of the reported display situation. Mac virtual displays
    /// are landscape, so the size is landscape-normalized regardless of how
    /// the device is currently held.
    private var displayInfoPayload: (widthPx: UInt32, heightPx: UInt32, secondDisplay: Bool)? {
        guard let s = reportedPixelSize, s.width > 0, s.height > 0 else { return nil }
        return (UInt32(max(s.width, s.height)), UInt32(min(s.width, s.height)), reportsSecondDisplay)
    }

    /// The attached second display's landscape-normalized pixel size, sent
    /// only when a second display is actually reported.
    private var secondSizePayload: (widthPx: UInt32, heightPx: UInt32)? {
        guard reportsSecondDisplay, let s = reportedSecondPixelSize, s.width > 0, s.height > 0 else { return nil }
        return (UInt32(max(s.width, s.height)), UInt32(min(s.width, s.height)))
    }

    /// Mid-session update (external monitor plugged/unplugged, or a new
    /// surface size). Stores the values — they ride the next HELLO on
    /// reconnect — and, when connected, tells the host now via
    /// CLIENT_DISPLAYS so it can reshape its virtual display(s).
    func updateReportedDisplay(pixelSize: CGSize? = nil, secondDisplay: Bool, secondPixelSize: CGSize? = nil) {
        if let pixelSize { reportedPixelSize = pixelSize }
        if let secondPixelSize { reportedSecondPixelSize = secondPixelSize }
        reportsSecondDisplay = secondDisplay
        guard task != nil, let info = displayInfoPayload else { return }
        clogViewer("reporting display update: \(Int(info.widthPx))x\(Int(info.heightPx))px, second display \(secondDisplay)")
        send(StreamMessage.clientDisplays(widthPx: info.widthPx, heightPx: info.heightPx,
                                          secondDisplay: info.secondDisplay, secondSize: secondSizePayload))
    }

    /// User-initiated disconnect: stop reconnecting and tear down.
    func disconnect() {
        if wantConnection { clogViewer("disconnect requested by user") }
        wantConnection = false
        connectHost = nil
        reconnectAttempt = 0
        teardownSocket()
        status = .idle
        videoSize = .zero
        softwareEncoding = false
        currentBitrateKbps = 0
        lastError = nil
    }

    private func teardownSocket() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        parser = nil
        assembler = nil
        audio?.stop()
    }

    /// Drop detected: retry with capped exponential backoff unless the user
    /// asked to disconnect.
    private func scheduleReconnect() {
        guard wantConnection else { return }
        teardownSocket()
        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), 10) // 1,2,4,8,10,10…
        clogViewer("reconnect attempt \(reconnectAttempt) in \(Int(delay))s (retries forever until user disconnects)")
        DispatchQueue.main.async { self.status = .connecting }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.wantConnection else { return }
            self.openSocket()
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self, self.task === task else { return }
            switch result {
            case .success(let message):
                self.reconnectAttempt = 0
                if case .data(let data) = message { self.parser?.feed(data) }
                self.receiveLoop(task)
            case .failure(let error):
                // A rejected WS upgrade (Cloudflare Access, wrong path) carries
                // an HTTP status; a dead host/port doesn't. Log both so they're
                // distinguishable after the fact.
                var detail = error.localizedDescription
                if let http = task.response as? HTTPURLResponse {
                    detail += " (HTTP \(http.statusCode)"
                    if http.statusCode == 403 || http.statusCode == 401 || http.statusCode == 302 {
                        detail += " — WS upgrade rejected, likely Cloudflare Access auth"
                    }
                    detail += ")"
                }
                clogViewer("stream dropped: \(detail) — reconnecting")
                let friendly = Self.friendlyError(error, response: task.response)
                DispatchQueue.main.async { self.lastError = friendly }
                self.scheduleReconnect()
            }
        }
    }

    private func handle(type: StreamMessageType, payload: Data) {
        switch type {
        case .helloAck:
            guard payload.count >= 10,
                  let codec = StreamCodec(rawValue: payload[payload.startIndex + 1]) else { return }
            let width = payload.beUInt32(at: 2), height = payload.beUInt32(at: 6)
            // flags byte (bit 0 = hardware encoder) is trailing; an older host
            // omits it — assume hardware, matching its refuse-to-start contract.
            let hardware = payload.count >= 11 ? (payload[payload.startIndex + 10] & 1) == 1 : true
            clogViewer("HELLO_ACK: \(codec == .hevc ? "HEVC" : "H.264") \(width)x\(height)\(hardware ? "" : " [SOFTWARE ENCODE on host]") — streaming")
            assembler = FrameAssembler(codec: codec)
            let codecName = codec == .hevc ? "HEVC" : "H.264"
            DispatchQueue.main.async {
                self.videoSize = CGSize(width: Double(width), height: Double(height))
                self.softwareEncoding = !hardware
                self.codecName = codecName
                self.lastError = nil // streaming actually started — clear any stale reason
                self.status = .streaming("\(codecName) \(width)x\(height)")
            }
        case .streamStatus:
            guard payload.count >= 2 else { return }
            let kbps = payload.beUInt16(at: 0)
            DispatchQueue.main.async { self.currentBitrateKbps = kbps }
        case .videoFrame:
            guard let sample = assembler?.assemble(payload: payload) else { return }
            onSampleBuffer?(sample)
        case .audioFrame:
            if playsAudio { audio?.play(aac: payload) }
        case .clipboard:
            if let text = String(data: payload, encoding: .utf8) {
                lastClipboard = text
                DispatchQueue.main.async { self.onClipboard?(text) }
            }
        default:
            break // client never receives hello/keyframeRequest
        }
    }

    // MARK: Input (normalized 0..1 display coordinates)

    private func send(_ data: Data) {
        task?.send(.data(data)) { _ in }
    }

    func sendMouseMove(x: Float, y: Float) { send(StreamMessage.mouseMove(x: x, y: y)) }
    func sendMouseButton(button: UInt8, down: Bool, x: Float, y: Float) {
        send(StreamMessage.mouseButton(button: button, down: down, x: x, y: y))
    }
    func sendScroll(dx: Float, dy: Float) { send(StreamMessage.scroll(dx: dx, dy: dy)) }
    func sendKey(macKeyCode: UInt16, down: Bool, flags: UInt64) {
        send(StreamMessage.key(macKeyCode: macKeyCode, down: down, flags: flags))
    }
    /// Push local pasteboard text to the Mac, skipping text we just received.
    func syncClipboard(_ text: String) {
        guard !text.isEmpty, text != lastClipboard else { return }
        lastClipboard = text
        send(StreamMessage.clipboard(text: text))
    }
    func requestKeyframe() { send(StreamMessage.frame(type: .keyframeRequest)) }
}

import os

/// Client-side diagnostic log, mirroring the Mac host's `clog` convention.
/// Goes to the unified log — readable live in Console.app with the device
/// attached, or after the fact via `log collect --device` /
/// `log stream --predicate 'subsystem == "com.frindle.clamshell.viewer"'`.
private let viewerLogger = Logger(subsystem: "com.frindle.clamshell.viewer", category: "stream")

func clogViewer(_ message: String) {
    viewerLogger.notice("\(message, privacy: .public)")
    #if DEBUG
    print("[ClamshellViewer] \(message)")
    #endif
}
