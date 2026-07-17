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

    /// Whether audio plays through this client. Only the primary (iPad-screen)
    /// client plays audio; the external-display client stays muted.
    var playsAudio = true
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
    private var connectParams: (host: String, accessId: String, accessSecret: String)?
    private var wantConnection = false
    private var reconnectAttempt = 0
    /// Last clipboard text seen in either direction — breaks the echo loop.
    private var lastClipboard: String?

    /// Accepts a bare host ("10.0.1.5" -> ws://10.0.1.5:5903) or a full
    /// ws:// / wss:// URL (Cloudflare Tunnel: wss://mac.example.com/stream).
    /// Cloudflare Access service-token headers are attached when provided.
    func connect(host: String, accessId: String = "", accessSecret: String = "") {
        wantConnection = true
        connectParams = (host, accessId, accessSecret)
        openSocket()
    }

    private func openSocket() {
        teardownSocket()
        guard let (host, accessId, accessSecret) = connectParams else { return }
        let urlString = host.contains("://") ? host : "ws://\(host):\(streamDefaultPort)"
        guard let url = URL(string: urlString) else {
            clogViewer("connect FAILED: invalid address '\(urlString)'")
            status = .failed("invalid address")
            return
        }
        clogViewer("connecting to \(urlString)\(accessId.isEmpty ? "" : " (with CF Access service token)")")
        status = .connecting

        let parser = StreamMessageParser()
        parser.onMessage = { [weak self] type, payload in self?.handle(type: type, payload: payload) }
        self.parser = parser

        var request = URLRequest(url: url)
        // Cloudflare Access service token — validated at Cloudflare's edge.
        if !accessId.isEmpty { request.setValue(accessId, forHTTPHeaderField: "CF-Access-Client-Id") }
        if !accessSecret.isEmpty { request.setValue(accessSecret, forHTTPHeaderField: "CF-Access-Client-Secret") }

        let task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 64 << 20 // keyframes at full display resolution
        self.task = task
        task.resume()
        // URLSession queues sends until the handshake completes.
        task.send(.data(StreamMessage.hello(requestedCodec: .hevc))) { _ in }
        receiveLoop(task)
    }

    /// User-initiated disconnect: stop reconnecting and tear down.
    func disconnect() {
        if wantConnection { clogViewer("disconnect requested by user") }
        wantConnection = false
        connectParams = nil
        reconnectAttempt = 0
        teardownSocket()
        status = .idle
        videoSize = .zero
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
            clogViewer("HELLO_ACK: \(codec == .hevc ? "HEVC" : "H.264") \(width)x\(height) — streaming")
            assembler = FrameAssembler(codec: codec)
            DispatchQueue.main.async {
                self.videoSize = CGSize(width: Double(width), height: Double(height))
                self.status = .streaming("\(codec == .hevc ? "HEVC" : "H.264") \(width)x\(height)")
            }
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
