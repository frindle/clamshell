import Foundation
import Network
@preconcurrency import ScreenCaptureKit
import CoreMedia
import VideoToolbox

// Host side of the stream: ScreenCaptureKit capture of one display (or, for
// Window Handoff, one window) -> hardware VideoToolbox encode -> framed
// messages over one TCP connection. Receives input messages on the same
// connection and injects them. One client at a time; a new connection
// replaces the current one.

/// What this server captures. A window capture is video+input only — no
/// audio/clipboard/cursor-follow/lock-state/client-display-reporting, all of
/// which are display concepts (see the `isPrimary`-gated features below and
/// PROTOCOL.md's v1 sections they implement). ponytail: window audio capture
/// (SCContentFilter supports it) is skipped for v1 — add if silent remoted
/// apps turn out to matter.
enum StreamSource {
    case display(CGDirectDisplayID)
    case window(UInt32)
}

extension StreamServer {
    /// Resolves the current target display ID, preferring:
    /// a. the original display if it's still present in shareable content,
    /// b. otherwise an active VIRTUAL display if one exists,
    /// c. otherwise CGMainDisplayID() if that is present in shareable content.
    /// Returns nil if nothing at all can be found.
    func resolveCurrentTargetDisplayID(content: SCShareableContent, originalDisplayID: CGDirectDisplayID) -> CGDirectDisplayID? {
        // a. Try the display it was originally constructed with
        if content.displays.contains(where: { $0.displayID == originalDisplayID }) {
            clog("STREAM: using original display \(originalDisplayID)")
            return originalDisplayID
        }
        
        // b. Any of OUR virtual displays, identified by the vendor/product IDs
        // VirtualDisplayController stamps on them. Do NOT construct a
        // VirtualDisplayController here to ask: its `displays` map is
        // per-instance state and the live one is private to
        // CollapseCoordinator, so a fresh instance is always empty and this
        // branch would never fire.
        if let ours = content.displays.first(where: { d in
            CGDisplayVendorNumber(d.displayID) == VirtualDisplayController.vendorID
                && CGDisplayModelNumber(d.displayID) == VirtualDisplayController.productID
        }) {
            clog("STREAM: original display gone; using virtual display \(ours.displayID)")
            return ours.displayID
        }

        // c. Fall back to main display if present in shareable content
        let mainDisplay = CGMainDisplayID()
        if content.displays.contains(where: { $0.displayID == mainDisplay }) {
            clog("STREAM: using main display \(mainDisplay)")
            return mainDisplay
        }
        
        // Nothing found at all
        clog("STREAM: no suitable display found in shareable content")
        return nil
    }

    /// Re-evaluate the capture target when a display configuration change occurs.
    /// This method is called by StreamFleet to handle reconfiguration events.
    func updateCaptureTarget() {
        // We can't easily restart an active stream without tearing down clients,
        // but we've already made the system resilient in startSession()
        clog("STREAM: Capture target updated due to display configuration change")
    }
}

// @unchecked Sendable: all mutable state is confined to the serial `queue`.
final class StreamServer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let source: StreamSource
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

    /// Whether the Mac's screen is currently locked (fed by StreamFleet's
    /// lock-notification observer). Pushed to the client as HOST_LOCK_STATE on
    /// every change and once right after HELLO_ACK, so a client that connects to
    /// an already-locked Mac immediately shows the browser-VNC fallback banner.
    private var hostLocked = false

    // Adaptive bitrate (see PROTOCOL.md "Adaptive bitrate"): reactive, driven
    // purely by the send-queue backpressure above. A full send queue means the
    // network can't drain 20 Mbps — halve the encoder bitrate (min once per
    // second, floor 2 Mbps). After 5 s without congestion, step back up by 25%
    // (min 5 s between up-steps, ceiling 20 Mbps).
    // Matches VideoEncoder's own cold-start value — see its comment on
    // kVTCompressionPropertyKey_AverageBitRate for why this starts low.
    private var bitrate = VideoEncoder.minBitrate
    private var lastCongestionAt: CFAbsoluteTime = 0
    private var lastStepAt: CFAbsoluteTime = 0

    // Cursor-follow auto-pan (see PROTOCOL.md): a lightweight, throttled
    // CURSOR_POS report so the client can auto-pan its viewport without the
    // cursor being decoded from pixels. 20 Hz is plenty for a smooth-feeling
    // follow and is trivial bandwidth (14 bytes/msg) next to the video stream.
    private var cursorTimer: DispatchSourceTimer?
    private var lastSentCursor: CGPoint?

    init(source: StreamSource, port: UInt16 = streamDefaultPort, isPrimary: Bool = true) {
        self.source = source
        self.port = port
        self.isPrimary = isPrimary
    }

    convenience init(displayID: CGDirectDisplayID, port: UInt16 = streamDefaultPort, isPrimary: Bool = true) {
        self.init(source: .display(displayID), port: port, isPrimary: isPrimary)
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
        clog("STREAM: listening on port \(port) for \(source)")
    }

    /// `completion` fires only once the listener has actually released its
    /// port (NWListener.cancel() is itself fire-and-forget) — callers that
    /// start a new listener on the same port right after stop() must wait
    /// for this, or the bind races the old socket's teardown and fails with
    /// EADDRINUSE. Confirmed live 2026-07-31: this raced during
    /// collapse/restore, the resulting failed bind cancelled the
    /// connection, which looked like the client dropping and reconnecting
    /// in an infinite loop.
    func stop(completion: @escaping () -> Void = {}) {
        queue.async { [self] in
            teardownSession()
            if let l = listener {
                l.stateUpdateHandler = { state in
                    clog("STREAM: listener \(state)")
                    if case .cancelled = state { completion() }
                }
                l.cancel()
            } else {
                completion()
            }
            listener = nil
        }
    }

    /// Force-disconnect the current client (Diagnostics "Disconnect All").
    func disconnectClient() {
        queue.async { [self] in teardownSession() }
    }

    /// Update the host lock state (from StreamFleet's lock observer). Stores it
    /// for the next HELLO_ACK and, if a client is connected, pushes it now.
    func setLockState(_ locked: Bool) {
        queue.async { [self] in
            hostLocked = locked
            guard connection != nil else { return }
            send(StreamMessage.hostLockState(locked))
        }
    }

    /// Snapshot for the Diagnostics view (read from the main queue).
    var portNumber: UInt16 { port }
    var primary: Bool { isPrimary }
    var isClientConnected: Bool { queue.sync { connection != nil } }

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
        bitrate = VideoEncoder.minBitrate
        lastCongestionAt = 0
        lastStepAt = 0
        cursorTimer?.cancel()
        cursorTimer = nil
        lastSentCursor = nil
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
        case .helloAck, .videoFrame, .audioFrame, .streamStatus, .hostLockState, .cursorPos:
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
        // Optional trailing Display B size (present only when a second display
        // is attached) — lets the host size Display B to the real external
        // monitor instead of the fixed presetB.
        var secondInfo: (w: UInt32, h: UInt32)?
        if secondDisplay, payload.count >= offset + 17 {
            let bw = payload.beUInt32(at: offset + 9), bh = payload.beUInt32(at: offset + 13)
            if bw >= 640, bh >= 480 { secondInfo = (bw, bh) }
        }
        clientAnnounced = true
        clog("STREAM: client reports \(w)x\(h)px\(secondDisplay ? " + second display\(secondInfo.map { " \($0.w)x\($0.h)px" } ?? "")" : "") — requesting collapse")
        DispatchQueue.main.async {
            Self.pendingRestorePost?.cancel()
            Self.pendingRestorePost = nil
            var info: [String: String] = ["width": String(w), "height": String(h),
                                          "external": secondDisplay ? "1" : "0", "source": "stream"]
            if let s = secondInfo { info["widthB"] = String(s.w); info["heightB"] = String(s.h) }
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("com.frindle.clamshell.collapse"), object: nil,
                userInfo: info, deliverImmediately: true)
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
        let source = self.source
        // Pin this session to the connection that sent HELLO. A second client
        // can connect (tearing down `connection` and installing a new one)
        // during the awaits below; without this check the new connection would
        // inherit this session's stream/encoder while the old one leaks.
        let sessionConn = self.connection
        Task {
            do {
                // Distinguish "permission denied" from other capture failures up
                // front — SCShareableContent's error alone is cryptic.
                if !CGPreflightScreenCaptureAccess() {
                    clog("STREAM: WARNING — Screen Recording permission NOT granted; capture will fail. Grant it in System Settings > Privacy & Security > Screen Recording.")
                }

                let (filter, pxWidth, pxHeight, refresh): (SCContentFilter, Int, Int, Double)
                switch source {
                case .display(let displayID):
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    
                    // Resolve the current target display ID with fallback logic
                    guard let resolvedDisplayID = self.resolveCurrentTargetDisplayID(content: content, originalDisplayID: displayID) else {
                        clog("STREAM: no suitable display found for capture")
                        self.queue.async { self.teardownSession() }
                        return
                    }
                    
                    // Use the resolved display ID to find the actual SCDisplay object
                    guard let scDisplay = content.displays.first(where: { $0.displayID == resolvedDisplayID }) else {
                        clog("STREAM: resolved display \(resolvedDisplayID) not found in shareable content")
                        self.queue.async { self.teardownSession() }
                        return
                    }
                    
                    // Native pixel resolution and refresh rate — no scaling in
                    // the capture path; the encoder sees exactly what the
                    // display shows.
                    let mode = CGDisplayCopyDisplayMode(resolvedDisplayID)
                    pxWidth = mode?.pixelWidth ?? scDisplay.width
                    pxHeight = mode?.pixelHeight ?? scDisplay.height
                    refresh = (mode?.refreshRate ?? 0) > 0 ? mode!.refreshRate : 60
                    filter = SCContentFilter(display: scDisplay, excludingWindows: [])
                case .window(let windowID):
                    // Window Handoff (PROTOCOL.md): explicit-selection v1, no
                    // AX-based hide/drag-trigger (blocked on this dev Mac —
                    // see WindowHandoff/WindowHideSelfTest.swift), so the
                    // window is captured wherever it currently sits.
                    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                    guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
                        clog("STREAM: window \(windowID) not found (closed, minimized, or off-screen?)")
                        self.queue.async { self.teardownSession() }
                        return
                    }
                    // ponytail: points-resolution capture, not the window's
                    // real backing-store pixel size (no cheap way to read a
                    // window's owning screen's backingScaleFactor from
                    // SCWindow alone) — upgrade if Retina windows look soft.
                    pxWidth = max(Int(scWindow.frame.width), 1)
                    pxHeight = max(Int(scWindow.frame.height), 1)
                    refresh = 60
                    filter = SCContentFilter(desktopIndependentWindow: scWindow)
                }

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
                // A remoted window shouldn't carry the source Mac's own
                // cursor into the frame; a whole display should.
                if case .window = source {
                    config.showsCursor = false
                } else {
                    config.showsCursor = true
                }

                // Only the primary display carries system audio — one capture,
                // no separate Core Audio tap. Windows never do (see StreamSource).
                let audioEncoder = self.isPrimary ? AudioEncoder() : nil
                if audioEncoder != nil {
                    config.capturesAudio = true
                    config.sampleRate = 48000
                    config.channelCount = 2
                }

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.videoQueue)
                if audioEncoder != nil {
                    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.audioQueue)
                }
                try await stream.startCapture()

                self.queue.async {
                    // Require the *same* connection that started this session:
                    // nil means the client vanished, a different object means a
                    // second client replaced it mid-setup. Either way this
                    // stream/encoder is orphaned — tear it down, don't attach.
                    guard self.connection === sessionConn, self.connection != nil else {
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
                    switch source {
                    case .display(let displayID): self.injector = InputInjector(displayID: displayID)
                    case .window(let windowID): self.injector = InputInjector(windowID: windowID)
                    }
                    self.send(StreamMessage.helloAck(codec: encoder.codec,
                                                     width: UInt32(pxWidth), height: UInt32(pxHeight),
                                                     hardwareEncoder: encoder.isHardware))
                    self.sendStreamStatus() // initial bitrate for the quality indicator
                    self.send(StreamMessage.hostLockState(self.hostLocked)) // so a client joining a locked Mac knows now
                    // Cursor-follow auto-pan is a display concept (see
                    // PROTOCOL.md) — a remoted window has no "different
                    // display" to report positions relative to.
                    if case .display(let displayID) = source {
                        self.startCursorReporting(displayID: displayID)
                    }
                    clog("STREAM: session started — \(encoder.codec) \(pxWidth)x\(pxHeight)@\(Int(refresh.rounded()))\(encoder.isHardware ? "" : " [SOFTWARE ENCODE]")")
                }
            } catch {
                clog("STREAM: failed to start capture session: \(error)")
                self.queue.async { self.teardownSession() }
            }
        }
    }

    // MARK: - Cursor-follow auto-pan (on `queue`)

    /// Polls the global cursor position at 20 Hz and reports it normalized to
    /// this display's bounds — skipped when it hasn't moved (beyond a small
    /// epsilon) since the last send, so an idle mouse costs nothing. `CGEvent`
    /// location is in the same top-left-origin global point space as
    /// `CGDisplayBounds`, matching `InputInjector.map` exactly.
    private func startCursorReporting(displayID: CGDirectDisplayID) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50)) // 20 Hz
        timer.setEventHandler { [weak self] in
            guard let self, let global = CGEvent(source: nil)?.location else { return }
            let bounds = CGDisplayBounds(displayID)
            guard bounds.width > 0, bounds.height > 0 else { return }
            let norm = CGPoint(x: (global.x - bounds.origin.x) / bounds.width,
                               y: (global.y - bounds.origin.y) / bounds.height)
            if let last = self.lastSentCursor,
               abs(last.x - norm.x) < 0.001, abs(last.y - norm.y) < 0.001 { return }
            self.lastSentCursor = norm
            self.send(StreamMessage.cursorPos(x: Float32(norm.x), y: Float32(norm.y)))
        }
        timer.resume()
        cursorTimer = timer
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

    /// Current encoder target, for the client's quality indicator.
    private func sendStreamStatus() {
        guard connection != nil else { return }
        send(StreamMessage.streamStatus(bitrateKbps: UInt16(min(bitrate / 1000, Int(UInt16.max)))))
    }

    private func stepBitrateDown() {
        let now = CFAbsoluteTimeGetCurrent()
        lastCongestionAt = now
        guard bitrate > VideoEncoder.minBitrate, now - lastStepAt >= 1 else { return }
        bitrate = max(bitrate / 2, VideoEncoder.minBitrate)
        lastStepAt = now
        encoder?.setBitrate(bitrate)
        sendStreamStatus()
        clog("STREAM: congestion (send queue full, dropping frames) — bitrate down to \(bitrate / 1_000_000) Mbps")
    }

    private func maybeStepBitrateUp() {
        guard bitrate < VideoEncoder.maxBitrate else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastCongestionAt >= 5, now - lastStepAt >= 5 else { return }
        bitrate = min(bitrate * 5 / 4, VideoEncoder.maxBitrate)
        lastStepAt = now
        encoder?.setBitrate(bitrate)
        sendStreamStatus()
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
    /// Shared instance for access from CollapseCoordinator
    static var shared: StreamFleet?
    
    private let basePort: UInt16
    private var servers: [StreamServer] = []
    private var currentIDs: [CGDirectDisplayID] = []
    private var pendingRebuild: DispatchWorkItem?

    /// Current screen-lock state, tracked from the `com.apple.screenIsLocked` /
    /// `...Unlocked` distributed notifications. Seeded from the login-session
    /// dictionary so a fleet started while already locked is correct. New
    /// servers inherit it on rebuild; live changes are pushed to every server.
    private var screenLocked = false
    private var lockObservers: [NSObjectProtocol] = []
    private var pendingLockSettle: DispatchWorkItem?

    /// Track virtual displays created by collapse operations to avoid tearing down active connections during collapse
    private var collapseCreatedDisplays: Set<CGDirectDisplayID> = []

    var isServing: Bool { !servers.isEmpty }

    /// Per-display connection snapshot for the Diagnostics view.
    var clientStatus: [(port: UInt16, primary: Bool, connected: Bool)] {
        servers.map { ($0.portNumber, $0.primary, $0.isClientConnected) }
    }

    /// Stored so it can be removed on stop() — the same function pointer must
    /// be passed to register and remove, and a live callback holding an
    /// unretained pointer to a deallocated fleet would dangle.
    private let reconfigCallback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
        guard let userInfo,
              flags.contains(.addFlag) || flags.contains(.removeFlag) else { return }
        let fleet = Unmanaged<StreamFleet>.fromOpaque(userInfo).takeUnretainedValue()
        DispatchQueue.main.async { fleet.rebuildSoon() }
    }
    private var callbackRegistered = false

    init(basePort: UInt16) {
        self.basePort = basePort
        CGDisplayRegisterReconfigurationCallback(reconfigCallback, Unmanaged.passUnretained(self).toOpaque())
        callbackRegistered = true
        screenLocked = Self.currentlyLocked() // correct if started while already locked
        observeLockState()
    }

    /// Whether the login session's screen is locked right now. `nil` (key
    /// absent) means unlocked. Used to seed initial state and is the same signal
    /// the screenIsLocked/Unlocked notifications flip.
    private static func currentlyLocked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Int == 1
    }

    /// Observe the system lock/unlock distributed notifications (the same
    /// mechanism `screensharingd` and the login window use) and fan the state
    /// out to every server so connected clients get HOST_LOCK_STATE. Main-queue
    /// confined, matching the rest of this class.
    private func observeLockState() {
        let dnc = DistributedNotificationCenter.default()
        for (name, _) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            let obs = dnc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                // Debounce lock state changes to handle the transient unlock->lock flap during login-window -> user-session handoff
                // The ~600ms delay allows for the screensharingd handoff flap to settle before propagating the final state
                self.pendingLockSettle?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    // Read the authoritative current lock state rather than trusting the notification that triggered this
                    let settled = Self.currentlyLocked()
                    if settled != self.screenLocked {
                        self.screenLocked = settled
                        clog("STREAM: screen \(settled ? "LOCKED" : "UNLOCKED") — notifying \(self.servers.count) server(s)")
                        for s in self.servers { s.setLockState(settled) }
                    }
                }
                self.pendingLockSettle = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
            }
            lockObservers.append(obs)
        }
    }

    /// Stop every server and unregister the topology callback. Lets the
    /// menu-bar app toggle native streaming on and off in-process.
    func stop() {
        pendingRebuild?.cancel()
        pendingRebuild = nil
        for s in servers { s.stop() }
        servers = []
        currentIDs = []
        if callbackRegistered {
            CGDisplayRemoveReconfigurationCallback(reconfigCallback, Unmanaged.passUnretained(self).toOpaque())
            callbackRegistered = false
        }
        for obs in lockObservers { DistributedNotificationCenter.default().removeObserver(obs) }
        lockObservers = []
        // Cancel any pending lock settle work item to prevent dangling scheduled work
        pendingLockSettle?.cancel()
        pendingLockSettle = nil
        clog("STREAM: fleet stopped")
    }

    /// Disconnect every connected client without tearing down the listeners —
    /// forces stuck reconnect-looping clients to re-handshake cleanly.
    func disconnectAllClients() {
        for s in servers { s.disconnectClient() }
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
        
        // Check if this is a reconfiguration that's part of an ongoing collapse operation.
        // If so, we should avoid tearing down active connections to prevent the loop.
        let isCollapseRebuild = !collapseCreatedDisplays.isEmpty && 
                               Set(ids).isSubset(of: collapseCreatedDisplays)
        
        // If this rebuild is due to a collapse and there are no other displays
        // (i.e., only virtual displays), we should not tear down existing connections
        if isCollapseRebuild {
            clog("STREAM: skipping rebuild for collapse-created displays")
            return
        }
        
        let group = DispatchGroup()
        for s in servers { group.enter(); s.stop { group.leave() } }
        servers = []
        currentIDs = ids
        // Wait for every old listener's port to actually release before
        // binding new ones on the same ports — see stop()'s doc comment.
        group.notify(queue: .main) { [self] in
            for (i, id) in ids.enumerated() {
                let server = StreamServer(displayID: id, port: basePort + UInt16(i), isPrimary: i == 0)
                do {
                    try server.start()
                    server.setLockState(screenLocked) // inherit current lock state
                    servers.append(server)
                } catch {
                    clog("STREAM: failed to start server on port \(basePort + UInt16(i)): \(error)")
                }
            }
            clog("STREAM: serving \(servers.count) display(s) on ports \(basePort)–\(basePort + UInt16(max(servers.count, 1) - 1))")
        }
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

    /// Mark a display as created during collapse operation to prevent it from 
    /// triggering rebuilds that would tear down active connections.
    func markCollapseCreatedDisplay(_ displayID: CGDirectDisplayID) {
        collapseCreatedDisplays.insert(displayID)
    }
    
    /// Clear the set of collapse-created displays after a period, allowing
    /// normal rebuild behavior for external changes.
    func clearCollapseCreatedDisplays() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.collapseCreatedDisplays.removeAll()
        }
    }
}
