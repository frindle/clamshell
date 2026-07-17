import SwiftUI
import AVFoundation
import CoreMedia

// Video rendering + direct input capture, shared by both iOS targets.
// VideoUIView hardware-decodes and renders via AVSampleBufferDisplayLayer;
// in interactive mode it also forwards touches (absolute touch-as-mouse),
// trackpad/mouse hover, indirect scroll, and hardware key presses.

/// One-line description of an external screen for the diagnostic log —
/// resolution/scale as actually detected, since "does the monitor/glasses
/// enumerate sanely" is exactly what needs verifying on real hardware.
func describeScreen(_ screen: UIScreen) -> String {
    let b = screen.bounds.size, n = screen.nativeBounds.size
    return "\(Int(b.width))x\(Int(b.height))pt @\(screen.scale)x (native \(Int(n.width))x\(Int(n.height))px, maxFPS \(screen.maximumFramesPerSecond))"
}

final class VideoUIView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    weak var client: StreamClient?
    var videoSize: CGSize = .zero
    /// Display B on an external screen is output-only — no input capture.
    private let interactive: Bool

    init(frame: CGRect, interactive: Bool) {
        self.interactive = interactive
        super.init(frame: frame)
        displayLayer.videoGravity = .resizeAspect
        isMultipleTouchEnabled = false
        backgroundColor = .black
        guard interactive else { return }

        // Trackpad / mouse hover drives the pointer position without a button.
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(onHover))
        addGestureRecognizer(hover)
        // Trackpad two-finger / mouse-wheel scroll -> INPUT_SCROLL.
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(onScroll))
        scroll.allowedScrollTypesMask = .all
        scroll.maximumNumberOfTouches = 0 // indirect (trackpad/wheel) scroll only
        addGestureRecognizer(scroll)
    }
    required init?(coder: NSCoder) { fatalError() }

    // Physical keyboard: capture key presses while this view is first responder.
    override var canBecomeFirstResponder: Bool { interactive }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil && interactive { becomeFirstResponder() }
    }

    @objc private func onHover(_ g: UIHoverGestureRecognizer) {
        guard let (x, y) = normalized(g.location(in: self)) else { return }
        client?.sendMouseMove(x: x, y: y)
    }

    private var lastScroll: CGPoint = .zero
    @objc private func onScroll(_ g: UIPanGestureRecognizer) {
        if g.state == .began { lastScroll = .zero }
        let t = g.translation(in: self)
        let dx = Float(t.x - lastScroll.x)
        let dy = Float(t.y - lastScroll.y)
        lastScroll = t
        if dx != 0 || dy != 0 { client?.sendScroll(dx: dx, dy: dy) }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !KeyMap.forward(presses, down: true, to: client) { super.pressesBegan(presses, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !KeyMap.forward(presses, down: false, to: client) { super.pressesEnded(presses, with: event) }
    }

    func enqueue(_ sample: CMSampleBuffer) {
        if displayLayer.status == .failed {
            // The layer wraps the hardware VTDecompressionSession; its error is
            // the only decode diagnostic iOS exposes. Log it before recovering.
            clogViewer("decode: AVSampleBufferDisplayLayer FAILED: \(displayLayer.error?.localizedDescription ?? "unknown error") — flushing and requesting keyframe")
            displayLayer.flush()
            client?.requestKeyframe()
        }
        displayLayer.enqueue(sample)
    }

    /// Maps a touch point into normalized video coordinates, accounting for
    /// aspect-fit letterboxing. Nil when outside the video rect.
    private func normalized(_ point: CGPoint) -> (Float, Float)? {
        guard videoSize != .zero, bounds.width > 0, bounds.height > 0 else { return nil }
        let rect = AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
        guard rect.width > 0, rect.height > 0 else { return nil }
        let x = Float((point.x - rect.minX) / rect.width)
        let y = Float((point.y - rect.minY) / rect.height)
        guard x >= 0, x <= 1, y >= 0, y <= 1 else { return nil }
        return (x, y)
    }

    // Single touch = left mouse: down on begin, drag on move, up on end.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, let (x, y) = normalized(t.location(in: self)) else { return }
        client?.sendMouseButton(button: 0, down: true, x: x, y: y)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, let (x, y) = normalized(t.location(in: self)) else { return }
        client?.sendMouseMove(x: x, y: y)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, let (x, y) = normalized(t.location(in: self)) else { return }
        client?.sendMouseButton(button: 0, down: false, x: x, y: y)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, let (x, y) = normalized(t.location(in: self)) else { return }
        client?.sendMouseButton(button: 0, down: false, x: x, y: y)
    }
}

struct VideoView: UIViewRepresentable {
    @ObservedObject var client: StreamClient
    var interactive = true

    func makeUIView(context: Context) -> VideoUIView {
        let view = VideoUIView(frame: .zero, interactive: interactive)
        view.client = client
        client.onSampleBuffer = { [weak view] sample in view?.enqueue(sample) }
        return view
    }

    func updateUIView(_ view: VideoUIView, context: Context) {
        view.videoSize = client.videoSize
    }
}

/// Warning shown whenever the connected host is encoding in software
/// (no hardware encoder) — never degrade silently. Shared by both targets.
struct SoftwareEncodingBanner: View {
    var body: some View {
        Label("Software encoding — expect higher CPU/battery use and possibly worse latency",
              systemImage: "exclamationmark.triangle.fill")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.black)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.yellow.opacity(0.9), in: Capsule())
    }
}

/// Root view hosted on the external UIWindowScene — output only.
struct ExternalDisplayView: View {
    @ObservedObject var client: StreamClient

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if case .streaming = client.status {
                VideoView(client: client, interactive: false).ignoresSafeArea()
            }
        }
    }
}
