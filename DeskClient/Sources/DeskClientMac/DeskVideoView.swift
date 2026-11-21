#if os(macOS)
import AppKit
import AVFoundation
import CoreMedia

/// Input from a window view, to be sent to the host as INPUT_* messages for that window.
public protocol DeskVideoViewDelegate: AnyObject {
    func videoView(_ view: DeskVideoView, key code: UInt16, down: Bool, flags: UInt64)
    func videoView(_ view: DeskVideoView, mouse x: Double, y: Double, button: Int, down: Bool)
    func videoView(_ view: DeskVideoView, scrollDX dx: Double, dy: Double)
}

/// Shows one hosted window's video. A layer-backed view on AVSampleBufferDisplayLayer: decoded frames are
/// enqueued as sample buffers. Mouse positions are sent in host window points (y down).
public final class DeskVideoView: NSView {
    public weak var delegate: DeskVideoViewDelegate?
    /// Size of the host window in points, to scale view coordinates back to host coordinates.
    public var hostSize = CGSize(width: 1, height: 1)

    private let displayLayer = AVSampleBufferDisplayLayer()

    public override init(frame: NSRect) {
        super.init(frame: frame)
        setUp()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        wantsLayer = true
        displayLayer.videoGravity = .resize // a stretched last frame while the host catches up
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer = displayLayer
    }

    public override var acceptsFirstResponder: Bool { true }
    public override var isFlipped: Bool { true }

    /// Queues one decoded-ready frame.
    public func enqueue(_ sample: CMSampleBuffer) {
        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(sample)
    }

    /// Drops queued frames, for example when the stream restarts.
    public func flush() { displayLayer.flushAndRemoveImage() }

    // MARK: input

    private func hostPoint(_ event: NSEvent) -> (Double, Double) {
        let p = convert(event.locationInWindow, from: nil)
        let w = max(bounds.width, 1), h = max(bounds.height, 1)
        return (Double(p.x / w * hostSize.width), Double(p.y / h * hostSize.height))
    }

    public override func keyDown(with event: NSEvent) {
        delegate?.videoView(self, key: event.keyCode, down: true, flags: DeskKeyMap.cgFlags(from: event.modifierFlags))
    }
    public override func keyUp(with event: NSEvent) {
        delegate?.videoView(self, key: event.keyCode, down: false, flags: DeskKeyMap.cgFlags(from: event.modifierFlags))
    }
    public override func mouseDown(with event: NSEvent) {
        let (x, y) = hostPoint(event); delegate?.videoView(self, mouse: x, y: y, button: 0, down: true)
    }
    public override func mouseUp(with event: NSEvent) {
        let (x, y) = hostPoint(event); delegate?.videoView(self, mouse: x, y: y, button: 0, down: false)
    }
    public override func rightMouseDown(with event: NSEvent) {
        let (x, y) = hostPoint(event); delegate?.videoView(self, mouse: x, y: y, button: 1, down: true)
    }
    public override func rightMouseUp(with event: NSEvent) {
        let (x, y) = hostPoint(event); delegate?.videoView(self, mouse: x, y: y, button: 1, down: false)
    }
    public override func scrollWheel(with event: NSEvent) {
        delegate?.videoView(self, scrollDX: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY))
    }
}
#endif
