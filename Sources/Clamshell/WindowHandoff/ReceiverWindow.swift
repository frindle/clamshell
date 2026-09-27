import AppKit
import AVFoundation
import Network

// The receiving side of a window handoff (PROTOCOL.md "Peer link — window
// handoff"): a native borderless window showing the peer's window live and
// forwarding mouse, scroll and keys back to it. It dials the v1 window
// stream the source opened for this handoff (HELLO → HELLO_ACK →
// VIDEO_FRAME…), decodes with the same FrameAssembler the iOS viewer uses
// into an AVSampleBufferDisplayLayer, and sends INPUT_* normalized to the
// video area — exactly what the source's InputInjector(windowID:) expects.
//
// A thin title strip carries the window's title, a drag handle (drag it
// back across the edge to send it home) and a ↩ button (send it home to
// where it came from). Closing the window also sends it home.
//
// Main-thread UI; network on its own queue.

final class ReceiverWindow: NSWindow {
    static let stripHeight: CGFloat = 22
    let sourceWindowId: UInt32
    private let videoView: ReceiverVideoView
    private let client: ReceiverStreamClient
    private var followTimer: Timer?
    /// User asked for it to go home (↩ / close). Set by the manager.
    var onReturnRequested: () -> Void = {}
    private var closingQuietly = false

    init(sourceWindowId: UInt32, title: String, app: String, size: CGSize, host: String, port: UInt16) {
        self.sourceWindowId = sourceWindowId
        let content = NSRect(x: 0, y: 0, width: max(size.width, 120), height: max(size.height, 60) + Self.stripHeight)
        videoView = ReceiverVideoView(frame: NSRect(x: 0, y: 0, width: content.width, height: content.height - Self.stripHeight))
        client = ReceiverStreamClient(host: host, port: port)
        super.init(contentRect: content, styleMask: [.borderless], backing: .buffered, defer: false)
        self.title = "\(app) — \(title)"
        isReleasedWhenClosed = false
        hasShadow = true
        backgroundColor = .black
        collectionBehavior = [.managed, .participatesInCycle]

        let root = NSView(frame: content)
        root.autoresizingMask = [.width, .height]
        videoView.autoresizingMask = [.width, .height]
        root.addSubview(videoView)
        let strip = ReceiverTitleStrip(frame: NSRect(x: 0, y: content.height - Self.stripHeight, width: content.width, height: Self.stripHeight),
                                       title: "\(app) — \(title)  (from peer)")
        strip.autoresizingMask = [.width, .minYMargin]
        strip.onReturn = { [weak self] in self?.onReturnRequested() }
        root.addSubview(strip)
        contentView = root
        initialFirstResponder = videoView

        videoView.send = { [weak client] data in client?.send(data) }
        client.onFrame = { [weak videoView] sample in videoView?.enqueue(sample) }
        client.onStatus = { [weak strip] text in DispatchQueue.main.async { strip?.status = text } }
        client.start()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Frames decoded so far (selftest / diagnostics).
    var framesShown: Int { videoView.framesEnqueued }
    var negotiatedSize: CGSize? { client.ackSize }

    /// Places the window so `grab` (0...1 within the video area) sits under
    /// the cursor and keeps it there while `isHeld()` — the carried-across
    /// drag. Stops on release.
    func follow(grab: CGPoint, isHeld: @escaping () -> Bool) {
        followTimer?.invalidate()
        let move = { [weak self] in
            guard let self else { return }
            let loc = NSEvent.mouseLocation
            let v = self.videoView.frame.size
            let origin = NSPoint(x: loc.x - grab.x * v.width, y: loc.y - (1 - grab.y) * v.height)
            self.setFrameOrigin(origin)
        }
        move()
        followTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            move()
            if !isHeld() {
                t.invalidate()
                self?.followTimer = nil
                self?.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Initial spot when nothing is being carried: against `edge` of the
    /// screen at `position` along it, fully on screen.
    func place(edge: PeerEdge, position: CGFloat) {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let f = frame
        var o = NSPoint.zero
        switch edge {
        case .left: o = NSPoint(x: screen.minX, y: screen.maxY - position * screen.height - f.height / 2)
        case .right: o = NSPoint(x: screen.maxX - f.width, y: screen.maxY - position * screen.height - f.height / 2)
        case .top: o = NSPoint(x: screen.minX + position * screen.width - f.width / 2, y: screen.maxY - f.height)
        case .bottom: o = NSPoint(x: screen.minX + position * screen.width - f.width / 2, y: screen.minY)
        }
        o.x = min(max(o.x, screen.minX), max(screen.maxX - f.width, screen.minX))
        o.y = min(max(o.y, screen.minY), max(screen.maxY - f.height, screen.minY))
        setFrameOrigin(o)
    }

    /// Closing via the window's own close (⌘W) = send it home.
    override func performClose(_ sender: Any?) { onReturnRequested() }

    /// Tear down without notifying anyone (manager already knows).
    func closeQuietly() {
        closingQuietly = true
        followTimer?.invalidate()
        client.stop()
        close()
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" { onReturnRequested(); return }
        videoView.keyDown(with: event)
    }
}

// MARK: - Title strip

private final class ReceiverTitleStrip: NSView {
    private let label = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "connecting…")
    var onReturn: () -> Void = {}
    var status: String { get { statusLabel.stringValue } set { statusLabel.stringValue = newValue } }

    init(frame: NSRect, title: String) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let button = NSButton(title: "↩ Send back", target: nil, action: nil)
        button.bezelStyle = .inline
        button.font = .systemFont(ofSize: 11)
        button.target = self
        button.action = #selector(returnTapped)
        button.sizeToFit()
        button.frame.origin = NSPoint(x: frame.width - button.frame.width - 6, y: (frame.height - button.frame.height) / 2)
        button.autoresizingMask = [.minXMargin]
        label.stringValue = title
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 8, y: 3, width: max(frame.width - button.frame.width - 110, 40), height: 16)
        label.autoresizingMask = [.width]
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right
        statusLabel.frame = NSRect(x: frame.width - button.frame.width - 100, y: 4, width: 90, height: 14)
        statusLabel.autoresizingMask = [.minXMargin]
        addSubview(label); addSubview(statusLabel); addSubview(button)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func returnTapped() { onReturn() }
    /// The strip is the drag handle: dragging it moves the window (and
    /// across the edge, sends it home — detected by CarryDetector).
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

// MARK: - Video + input

final class ReceiverVideoView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    var send: (Data) -> Void = { _ in }
    private(set) var framesEnqueued = 0
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }

    func enqueue(_ sample: CMSampleBuffer) {
        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(sample)
        framesEnqueued += 1
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    /// 0...1, origin top-left, in the video area.
    private func norm(_ e: NSEvent) -> (Float32, Float32) {
        let p = convert(e.locationInWindow, from: nil)
        let w = max(bounds.width, 1), h = max(bounds.height, 1)
        return (Float32(min(max(p.x / w, 0), 1)), Float32(min(max(1 - p.y / h, 0), 1)))
    }

    override func mouseMoved(with e: NSEvent) { let (x, y) = norm(e); send(StreamMessage.mouseMove(x: x, y: y)) }
    override func mouseDragged(with e: NSEvent) { mouseMoved(with: e) }
    override func rightMouseDragged(with e: NSEvent) { mouseMoved(with: e) }
    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let (x, y) = norm(e); send(StreamMessage.mouseButton(button: 0, down: true, x: x, y: y))
    }
    override func mouseUp(with e: NSEvent) { let (x, y) = norm(e); send(StreamMessage.mouseButton(button: 0, down: false, x: x, y: y)) }
    override func rightMouseDown(with e: NSEvent) { let (x, y) = norm(e); send(StreamMessage.mouseButton(button: 1, down: true, x: x, y: y)) }
    override func rightMouseUp(with e: NSEvent) { let (x, y) = norm(e); send(StreamMessage.mouseButton(button: 1, down: false, x: x, y: y)) }
    override func scrollWheel(with e: NSEvent) {
        let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 10
        send(StreamMessage.scroll(dx: Float32(e.scrollingDeltaX * k), dy: Float32(e.scrollingDeltaY * k)))
    }
    override func keyDown(with e: NSEvent) { key(e, down: true) }
    override func keyUp(with e: NSEvent) { key(e, down: false) }
    override func flagsChanged(with e: NSEvent) {
        let flags = CGEventFlags(rawValue: UInt64(e.modifierFlags.rawValue))
        guard let t = EdgeKeys.modifierTransition(keyCode: e.keyCode, flags: flags) else { return }
        send(StreamMessage.key(macKeyCode: e.keyCode, down: t.down, flags: flags.rawValue & InputInjector.allowedFlagBits))
        if t.isToggle { send(StreamMessage.key(macKeyCode: e.keyCode, down: false, flags: flags.rawValue & InputInjector.allowedFlagBits)) }
    }
    private func key(_ e: NSEvent, down: Bool) {
        // NSEvent.ModifierFlags' device-independent bits are CGEventFlags' bits.
        send(StreamMessage.key(macKeyCode: e.keyCode, down: down,
                               flags: UInt64(e.modifierFlags.rawValue) & InputInjector.allowedFlagBits))
    }
    // Keep ⌘-shortcuts (⌘C, ⌘V…) going to the remote app, not our menu.
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self, e.type == .keyDown, e.modifierFlags.contains(.command) else { return false }
        if e.charactersIgnoringModifiers == "w" { return false }
        key(e, down: true) // the matching keyUp arrives through keyUp(with:)
        return true
    }
}

// MARK: - Stream client

/// v1 window-stream client over a WebSocket NWConnection (dialled by URL —
/// see PeerLink for why), feeding decoded-ready sample buffers out.
final class ReceiverStreamClient {
    private let url: URL?
    private let queue = DispatchQueue(label: "clamshell.receiver")
    private var conn: NWConnection?
    private let parser = StreamMessageParser()
    private var assembler: FrameAssembler?
    private(set) var ackSize: CGSize?
    var onFrame: (CMSampleBuffer) -> Void = { _ in }
    var onStatus: (String) -> Void = { _ in }

    init(host: String, port: UInt16) {
        let h = host.contains(":") ? "[\(host)]" : host
        url = URL(string: "ws://\(h):\(port)/")
        parser.onMessage = { [weak self] t, p in self?.handle(t, p) }
    }

    func start() {
        guard let url else { onStatus("bad address"); return }
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 64 << 20
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        let c = NWConnection(to: .url(url), using: params)
        conn = c
        c.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.onStatus("live")
                self.receive(c)
                self.send(StreamMessage.hello(requestedCodec: .hevc))
            case .failed(let e): self.onStatus("lost: \(e)")
            case .waiting(let e): self.onStatus("waiting: \(e)")
            default: break
            }
        }
        c.start(queue: queue)
    }

    func stop() { conn?.cancel(); conn = nil }

    func send(_ data: Data) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let ctx = NWConnection.ContentContext(identifier: "msg", metadata: [meta])
        conn?.send(content: data, contentContext: ctx, isComplete: true, completion: .idempotent)
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, complete, error in
            guard let self, self.conn === c else { return }
            if let data, !data.isEmpty { self.parser.feed(data) }
            if error != nil || (complete && data == nil) || self.parser.corrupt {
                self.onStatus("stream ended"); return
            }
            self.receive(c)
        }
    }

    private func handle(_ t: StreamMessageType, _ p: Data) {
        switch t {
        case .helloAck:
            guard p.count >= 10, let codec = StreamCodec(rawValue: p[p.startIndex + 1]) else { return }
            assembler = FrameAssembler(codec: codec)
            ackSize = CGSize(width: CGFloat(p.beUInt32(at: 2)), height: CGFloat(p.beUInt32(at: 6)))
        case .videoFrame:
            guard let a = assembler else { return }
            if let sample = a.assemble(payload: p) {
                onFrame(sample)
            } else if a.formatDescription == nil {
                send(StreamMessage.frame(type: .keyframeRequest))
            }
        default:
            break
        }
    }
}
