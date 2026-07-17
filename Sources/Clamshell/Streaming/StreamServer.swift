import Foundation
import Network
@preconcurrency import ScreenCaptureKit
import CoreMedia
import VideoToolbox

// Host side of the stream: ScreenCaptureKit capture of one display ->
// hardware VideoToolbox encode -> framed messages over one TCP connection.
// Receives input messages on the same connection and injects them.
// One client at a time; a new connection replaces the current one.

// @unchecked Sendable: all mutable state is confined to the serial `queue`.
final class StreamServer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let displayID: CGDirectDisplayID
    private let port: UInt16
    /// The primary server (main display, base port) also carries system audio
    /// and clipboard sync; secondary displays are video+input only.
    private let isPrimary: Bool

    private var listener: NWListener?
    private var connection: NWConnection?
    private var parser: StreamMessageParser?
    private var stream: SCStream?
    private var encoder: VideoEncoder?
    private var audioEncoder: AudioEncoder?
    private var clipboard: ClipboardBridge?
    private var injector: InputInjector?
    private let audioQueue = DispatchQueue(label: "clamshell.stream.audio")

    /// Serial queue owning all connection/session state.
    private let queue = DispatchQueue(label: "clamshell.stream")
    private let videoQueue = DispatchQueue(label: "clamshell.stream.video")

    /// Send backpressure: frames handed to NWConnection but not yet consumed.
    /// TCP on LAN drains fast; if it backs up, drop delta frames and let the
    /// next keyframe resynchronize the decoder.
    private var framesInFlight = 0
    private let maxFramesInFlight = 8

    /// This session's client reported display info (and so may have driven a
    /// collapse) — on teardown, schedule the matching restore request.
    private var clientAnnounced = false

    // Adaptive bitrate (see PROTOCOL.md "Adaptive bitrate"): reactive, driven
    // purely by the send-queue backpressure above. A full send queue means the
    // network can't drain 20 Mbps — halve the encoder bitrate (min once per
    // second, floor 2 Mbps). After 5 s without congestion, step back up by 25%
    // (min 5 s between up-steps, ceiling 20 Mbps).
    private var bitrate = VideoEncoder.maxBitrate
    private var lastCongestionAt: CFAbsoluteTime = 0
    private var lastStepAt: CFAbsoluteTime = 0

    init(displayID: CGDirectDisplayID, port: UInt16 = streamDefaultPort, isPrimary: Bool = true) {
        self.displayID = displayID
        self.port = port
        self.isPrimary = isPrimary
    }

    func start() throws {
        // WebSocket over TCP (not raw TCP) so the stream can ride through a
        // Cloudflare Tunnel's HTTP path; the binary framing inside is unchanged.
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] conn in
            self?.queue.async { self?.accept(conn) }
        }
        listener.stateUpdateHandler = { state in
            clog("STREAM: listener \(state)")
        }
        listener.start(queue: queue)
        self.listener = listener
        clog("STREAM: listening on port \(port) for display \(displayID)")
    }

    func stop() {
        queue.async { [self] in
            teardownSession()
            listener?.cancel()
            listener = nil
        }
    }

    // MARK: - Connection lifecycle (on `queue`)

    private func accept(_ conn: NWConnection) {
        if connection != nil {
            clog("STREAM: new client replaces existing connection")
            teardownSession()
        }
        connection = conn
        let parser = StreamMessageParser()
        parser.onMessage = { [weak self] type, payload in
            self?.handle(type: type, payload: payload)
        }
        self.parser = parser
        conn.stateUpdateHandler = { [weak self] state in
            clog("STREAM: connection \(state)")
            if case .failed = state { self?.queue.async { self?.teardownSession() } }
            if case .cancelled = state { self?.queue.async { self?.teardownSession() } }
        }
        conn.start(queue: queue)
        receiveLoop(conn)
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, complete, error in
            guard let self, self.connection === conn else { return }
            if let data, !data.isEmpty { self.parser?.feed(data) }
            if self.parser?.corrupt == true {
                clog("STREAM: corrupt stream from client — disconnecting")
                self.teardownSession()
                return
            }
            if error != nil || (complete && data == nil) {
                clog("STREAM: client disconnected (\(error.map(String.init(describing:)) ?? "eof"))")
                self.teardownSession()
                return
            }
            self.receiveLoop(conn)
        }
    }

    private func teardownSession() {
        guard connection != nil || stream != nil else { return }
        if clientAnnounced {
            clientAnnounced = false
            scheduleRestorePost()
        }
        connection?.cancel()
        connection = nil
        parser = nil
        framesInFlight = 0
        bitrate = VideoEncoder.maxBitrate
        lastCongestionAt = 0
        lastStepAt = 0
        if let s = stream {
            s.stopCapture { _ in }
            stream = nil
        }
        encoder?.invalidate()
        encoder = nil
        audioEncoder = nil
        clipboard?.stop()
        clipboard = nil
        injector = nil
    }

    // MARK: - Messages (on `queue`)

    private func handle(type: StreamMessageType, payload: Data) {
        switch type {
        case .hello:
            guard payload.count >= 2 else { return }
            let requested = StreamCodec(rawValue: payload[payload.startIndex + 1]) ?? .hevc
            handleClientDisplayInfo(payload, at: 2)
            startSession(requestedCodec: requested)
        case .clientDisplays:
            handleClientDisplayInfo(payload, at: 0)
        case .keyframeRequest:
            encoder?.requestKeyframe()
        case .mouseMove:
            guard payload.count >= 8 else { return }
            injector?.mouseMove(x: payload.beFloat32(at: 0), y: payload.beFloat32(at: 4))
        case .mouseButton:
            guard payload.count >= 10 else { return }
            injector?.mouseButton(button: payload[payload.startIndex], down: payload[payload.startIndex + 1] == 1,
                                  x: payload.beFloat32(at: 2), y: payload.beFloat32(at: 6))
        case .key:
            guard payload.count >= 11 else { return }
            injector?.key(macKeyCode: payload.beUInt16(at: 0), down: payload[payload.startIndex + 2] == 1,
                          flags: payload.beUInt64(at: 3))
        case .scroll:
            guard payload.count >= 8 else { return }
            injector?.scroll(dx: payload.beFloat32(at: 0), dy: payload.beFloat32(at: 4))
        case .clipboard:
            if let text = String(data: payload, encoding: .utf8) { clipboard?.receiveFromClient(text) }
        case .helloAck, .videoFrame, .audioFrame:
            break // host never receives these
        }
    }

    // MARK: - Client display info -> host auto-configuration (on `queue`)

    /// The client reports its real screen size (and whether it has a second
    /// display surface) in HELLO / CLIENT_DISPLAYS. Forward it to the menu
    /// bar app over the same distributed-notification channel Sunshine's
    /// prep-command uses, so the virtual display gets auto-sized to the
    /// device (and dual mode auto-toggled) without a manual preset pick.
    /// Only the primary connection speaks for the client; secondary display
    /// connections would otherwise fight over the geometry.
    private func handleClientDisplayInfo(_ payload: Data, at offset: Int) {
        guard isPrimary, payload.count >= offset + 9 else { return }
        let w = payload.beUInt32(at: offset), h = payload.beUInt32(at: offset + 4)
        let secondDisplay = (payload[payload.startIndex + offset + 8] & 1) == 1
        guard w >= 640, h >= 480 else { return }
        clientAnnounced = true
        clog("STREAM: client reports \(w)x\(h)px\(secondDisplay ? " + second display" : "") — requesting collapse")
        DispatchQueue.main.async {
            Self.pendingRestorePost?.cancel()
            Self.pendingRestorePost = nil
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("com.frindle.clamshell.collapse"), object: nil,
                userInfo: ["width": String(w), "height": String(h),
                           "external": secondDisplay ? "1" : "0", "source": "stream"],
                deliverImmediately: true)
        }
    }

    /// Restore is posted only after a grace period with no announcing client:
    /// viewer reconnects (network blips, and this process rebuilding servers
    /// on display-topology changes) must not thrash the collapse. Static
    /// because a topology rebuild replaces server instances mid-session — the
    /// reconnecting client's HELLO on the *new* primary must cancel the *old*
    /// instance's scheduled restore. Main-queue confined.
    private static var pendingRestorePost: DispatchWorkItem?

    private func scheduleRestorePost() {
        DispatchQueue.main.async {
            Self.pendingRestorePost?.cancel()
            let work = DispatchWorkItem {
                Self.pendingRestorePost = nil
                clog("STREAM: no client for 15s — requesting restore")
                DistributedNotificationCenter.default().postNotificationName(
                    Notification.Name("com.frindle.clamshell.restore"), object: nil,
                    userInfo: ["source": "stream"], deliverImmediately: true)
            }
            Self.pendingRestorePost = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
        }
    }

    // MARK: - Capture session

    private func startSession(requestedCodec: StreamCodec) {
        let displayID = self.displayID
        Task {
            do {
                // Distinguish "permission denied" from other capture failures up
                // front — SCShareableContent's error alone is cryptic.
                if !CGPreflightScreenCaptureAccess() {
                    clog("STREAM: WARNING — Screen Recording permission NOT granted; capture will fail. Grant it in System Settings > Privacy & Security > Screen Recording.")
                }
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
                    clog("STREAM: display \(displayID) not found in shareable content")
                    self.queue.async { self.teardownSession() }
                    return
                }

                // Native pixel resolution and refresh rate — no scaling in the
                // capture path; the encoder sees exactly what the display shows.
                let mode = CGDisplayCopyDisplayMode(displayID)
                let pxWidth = mode?.pixelWidth ?? scDisplay.width
                let pxHeight = mode?.pixelHeight ?? scDisplay.height
                let refresh = (mode?.refreshRate ?? 0) > 0 ? mode!.refreshRate : 60

                let encoder = try VideoEncoder.makeEncoder(
                    width: Int32(pxWidth), height: Int32(pxHeight), preferred: requestedCodec)

                let config = SCStreamConfiguration()
                config.width = pxWidth
                config.height = pxHeight
                config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(refresh.rounded()))
                // NV12 full range is the hardware encoder's native input —
                // no format conversion between capture and encode.
                config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                config.queueDepth = 5
                config.showsCursor = true

                // Only the primary display carries system audio — one capture,
                // no separate Core Audio tap.
                let audioEncoder = self.isPrimary ? AudioEncoder() : nil
                if audioEncoder != nil {
                    config.capturesAudio = true
                    config.sampleRate = 48000
                    config.channelCount = 2
                }

                let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.videoQueue)
                if audioEncoder != nil {
                    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.audioQueue)
                }
                try await stream.startCapture()

                self.queue.async {
                    guard self.connection != nil else { // client vanished during setup
                        stream.stopCapture { _ in }
                        encoder.invalidate()
                        return
                    }
                    encoder.onEncodedFrame = { [weak self] keyframe, pts, nalData in
                        self?.queue.async { self?.sendFrame(keyframe: keyframe, ptsMicros: pts, nalData: nalData) }
                    }
                    self.encoder = encoder
                    self.stream = stream
                    if let audioEncoder {
                        audioEncoder.onEncodedPacket = { [weak self] aac in
                            self?.queue.async {
                                guard self?.connection != nil else { return }
                                self?.send(StreamMessage.audioFrame(aac))
                            }
                        }
                        self.audioEncoder = audioEncoder
                    }
                    if self.isPrimary {
                        let clipboard = ClipboardBridge()
                        clipboard.onLocalChange = { [weak self] text in
                            self?.queue.async {
                                guard self?.connection != nil else { return }
                                self?.send(StreamMessage.clipboard(text: text))
                            }
                        }
                        clipboard.start()
                        self.clipboard = clipboard
                    }
                    self.injector = InputInjector(displayID: displayID)
                    self.send(StreamMessage.helloAck(codec: encoder.codec,
                                                     width: UInt32(pxWidth), height: UInt32(pxHeight),
                                                     hardwareEncoder: encoder.isHardware))
                    clog("STREAM: session started — \(encoder.codec) \(pxWidth)x\(pxHeight)@\(Int(refresh.rounded()))\(encoder.isHardware ? "" : " [SOFTWARE ENCODE]")")
                }
            } catch {
                clog("STREAM: failed to start capture session: \(error)")
                self.queue.async { self.teardownSession() }
            }
        }
    }

    // MARK: - Sending (on `queue`)

    private func sendFrame(keyframe: Bool, ptsMicros: UInt64, nalData: Data) {
        guard connection != nil else { return }
        if framesInFlight >= maxFramesInFlight && !keyframe {
            // Network can't keep up: drop the delta and resync on a keyframe.
            encoder?.requestKeyframe()
            stepBitrateDown()
            return
        }
        maybeStepBitrateUp()
        framesInFlight += 1
        send(StreamMessage.videoFrame(keyframe: keyframe, ptsMicros: ptsMicros, nalData: nalData)) { [weak self] in
            self?.framesInFlight -= 1
        }
    }

    // MARK: - Adaptive bitrate (on `queue`)

    private func stepBitrateDown() {
        let now = CFAbsoluteTimeGetCurrent()
        lastCongestionAt = now
        guard bitrate > VideoEncoder.minBitrate, now - lastStepAt >= 1 else { return }
        bitrate = max(bitrate / 2, VideoEncoder.minBitrate)
        lastStepAt = now
        encoder?.setBitrate(bitrate)
        clog("STREAM: congestion (send queue full, dropping frames) — bitrate down to \(bitrate / 1_000_000) Mbps")
    }

    private func maybeStepBitrateUp() {
        guard bitrate < VideoEncoder.maxBitrate else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastCongestionAt >= 5, now - lastStepAt >= 5 else { return }
        bitrate = min(bitrate * 5 / 4, VideoEncoder.maxBitrate)
        lastStepAt = now
        encoder?.setBitrate(bitrate)
        clog("STREAM: healthy for 5s — bitrate up to \(bitrate / 1_000_000) Mbps")
    }

    private func send(_ data: Data, completion: (() -> Void)? = nil) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "msg", metadata: [metadata])
        connection?.send(content: data, contentContext: context, isComplete: true,
                         completion: .contentProcessed { [weak self] error in
            self?.queue.async {
                completion?()
                if error != nil { self?.teardownSession() }
            }
        })
    }

    // MARK: - SCStreamOutput / SCStreamDelegate (on `videoQueue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            if sampleBuffer.isValid { audioEncoder?.encode(sampleBuffer) }
            return
        }
        guard type == .screen,
              sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                  as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        encoder?.encode(pixelBuffer, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        clog("STREAM: capture stopped with error: \(error)")
        queue.async { self.teardownSession() }
    }
}

// MARK: - Fleet: one server per active display, following topology changes

/// Owns the per-display StreamServers for the `Clamshell stream` CLI and
/// rebuilds them when the display topology changes. That matters because the
/// client's HELLO can trigger a collapse (auto-sized virtual display, maybe
/// dual) *after* this process started — virtual display A must take over the
/// base port and B must get base+1 (where the iPad's external-screen client
/// connects), and the physical displays drop off the active list while
/// mirrored. Clients ride through the rebuild via their auto-reconnect.
/// Main-queue confined.
final class StreamFleet {
    private let basePort: UInt16
    private var servers: [StreamServer] = []
    private var currentIDs: [CGDirectDisplayID] = []
    private var pendingRebuild: DispatchWorkItem?

    var isServing: Bool { !servers.isEmpty }

    init(basePort: UInt16) {
        self.basePort = basePort
        let info = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ _, flags, userInfo in
            guard let userInfo,
                  flags.contains(.addFlag) || flags.contains(.removeFlag) else { return }
            let fleet = Unmanaged<StreamFleet>.fromOpaque(userInfo).takeUnretainedValue()
            DispatchQueue.main.async { fleet.rebuildSoon() }
        }, info)
    }

    /// Active displays, main display first (index 0 = base port = the primary
    /// connection carrying audio/clipboard/display-info). Mirrored displays
    /// are excluded by CGGetActiveDisplayList, so while collapsed the list is
    /// just the virtual display(s).
    private static func activeIDs() -> [CGDirectDisplayID] {
        var list = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &list, &count)
        var ids = Array(list.prefix(Int(count)))
        if ids.isEmpty { ids = [CGMainDisplayID()] }
        if let mainIdx = ids.firstIndex(of: CGMainDisplayID()), mainIdx != 0 { ids.swapAt(0, mainIdx) }
        return ids
    }

    func rebuild() {
        let ids = Self.activeIDs()
        guard ids != currentIDs else { return }
        for s in servers { s.stop() }
        servers = []
        currentIDs = ids
        for (i, id) in ids.enumerated() {
            let server = StreamServer(displayID: id, port: basePort + UInt16(i), isPrimary: i == 0)
            do {
                try server.start()
                servers.append(server)
            } catch {
                clog("STREAM: failed to start server on port \(basePort + UInt16(i)): \(error)")
            }
        }
        clog("STREAM: serving \(servers.count) display(s) on ports \(basePort)–\(basePort + UInt16(max(servers.count, 1) - 1))")
    }

    /// Collapse/restore reconfigures displays several times over ~2s;
    /// debounce so we rebuild once, after the topology settles.
    private func rebuildSoon() {
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingRebuild = nil
            self?.rebuild()
        }
        pendingRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }
}
