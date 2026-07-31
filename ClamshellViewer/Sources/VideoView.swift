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

/// Shown while the host reports its screen is locked (HOST_LOCK_STATE). Native
/// ScreenCaptureKit capture and CGEventPost input can't cross the macOS lock
/// screen, so the video freezes — this points the user at the browser VNC
/// bridge (Apple's privileged screensharingd), which can reach and unlock a
/// locked Mac. Clears automatically when the host reports unlocked; the video
/// resumes on its own via StreamClient's existing reconnect/frame flow.
struct LockScreenBanner: View {
    let fallbackURL: URL?
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 8) {
            Label("Mac is locked — native video paused", systemImage: "lock.fill")
                .font(.footnote.weight(.semibold))
            if let url = fallbackURL {
                Button {
                    openURL(url) // opens the noVNC bridge in Safari
                } label: {
                    Label("Unlock in browser (Screen Sharing)", systemImage: "safari.fill")
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
            } else {
                Text("Open the Mac's http://…:5901 web access in a browser to unlock.")
                    .font(.caption2).multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.yellow.opacity(0.7), lineWidth: 1))
    }
}

/// Root view hosted on the external UIWindowScene — output only.
///
/// `viewport`, when non-nil, switches from the plain aspect-fit `VideoView`
/// to `PanZoomVideoView` and wires the host's CURSOR_POS reports into
/// cursor-follow auto-pan. Only External Display Only mode passes one — the
/// existing Display B path (`ExternalDisplaySceneDelegate` / ClamshellControl)
/// is unaffected, matching the existing "off unless opted in" convention for
/// this mode. See PanZoomVideoView / Viewport below.
struct ExternalDisplayView: View {
    @ObservedObject var client: StreamClient
    var viewport: Viewport? = nil

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if case .streaming = client.status {
                if let viewport {
                    PanZoomVideoView(client: client, viewport: viewport).ignoresSafeArea()
                } else {
                    VideoView(client: client, interactive: false).ignoresSafeArea()
                }
            }
        }
        .onChange(of: client.cursorPos) { _, newValue in
            guard let newValue, let viewport else { return }
            viewport.follow(cursor: newValue)
        }
    }
}

// MARK: - Manual pan + zoom / cursor-follow auto-pan (External Display Only)
//
// Three-part feature for viewing a large/ultrawide Mac display on a smaller
// portable external monitor while in External Display Only mode:
//  1. Manual pan+zoom — this file's Viewport + PanZoomContainerUIView render
//     a controllable crop of the video instead of forcing the whole frame to
//     fit (which would shrink an ultrawide source to a sliver on a
//     differently-shaped monitor).
//  2. Cursor-follow auto-pan — Viewport.follow(cursor:), driven by the host's
//     new CURSOR_POS protocol message (see StreamClient.cursorPos,
//     PROTOCOL.md "Cursor-follow auto-pan").
//  3. Manual override — see the doc comment on Viewport.pan(delta:).
//
// The gesture surface (PanZoomUIView) is deliberately NOT on the video view
// itself: in External Display Only mode the video plays only on the external
// screen, and the iPad's own screen is free (ContentView.externalOnlyStatusView)
// — exactly the "control surface on the device, video on the external screen"
// split ClamshellControl already uses for its trackpad. Two-finger drag pans
// (one-finger is left alone, matching TrackpadUIView's touch-count convention
// even though nothing here uses single-finger for anything yet), pinch zooms.

/// Client-side pan+zoom viewport state. Pure rendering/gesture state — no
/// protocol messages of its own.
///
/// **Manual-override design choice:** a manual pinch or two-finger drag
/// immediately turns `autoFollow` off, rather than "auto-follow resumes after
/// N seconds idle" or blending the two. The gesture surface is on a screen the
/// user isn't even looking at while streaming (the video is on the external
/// monitor) — a follow that silently snaps the view back mid-decision would
/// be more surprising than useful. The user re-enables it explicitly via the
/// "Auto-Follow Cursor" toggle next to the gesture surface.
final class Viewport: ObservableObject {
    @Published var zoom: CGFloat = 1.0
    /// Normalized 0..1 point (source-frame space) currently centered in the
    /// viewport.
    @Published var centerNorm = CGPoint(x: 0.5, y: 0.5)
    @Published var autoFollow = true

    let minZoom: CGFloat = 1.0
    let maxZoom: CGFloat = 6.0

    private var pinchStartZoom: CGFloat = 1.0

    func pinchBegan() { pinchStartZoom = zoom }
    func pinchChanged(scale: CGFloat) {
        zoom = min(max(pinchStartZoom * scale, minZoom), maxZoom)
        clamp()
    }

    // ponytail: fixed gain, no acceleration curve — tuned so a full
    // gesture-surface-width two-finger drag pans roughly the whole visible
    // viewport at 2x zoom. Add a sensitivity setting if it feels off.
    private let panGain: CGFloat = 1.0 / 1200
    func pan(delta: CGPoint) {
        autoFollow = false // manual pan overrides auto-follow — see class doc
        centerNorm.x -= delta.x * panGain / zoom
        centerNorm.y -= delta.y * panGain / zoom
        clamp()
    }

    /// Called on every CURSOR_POS update. No-ops unless auto-follow is on,
    /// the view is actually zoomed in (at zoom 1 the whole frame is already
    /// visible — nothing to follow), and the cursor is on *this* display
    /// (StreamClient reports raw, unclamped coordinates for exactly this check).
    func follow(cursor: CGPoint) {
        guard autoFollow, zoom > 1.01,
              cursor.x >= 0, cursor.x <= 1, cursor.y >= 0, cursor.y <= 1 else { return }
        centerNorm = cursor
        clamp()
    }

    func reset() {
        zoom = 1
        centerNorm = CGPoint(x: 0.5, y: 0.5)
        autoFollow = true
    }

    // ponytail: per-axis half-visible-fraction (0.5/zoom) ignores any
    // mismatch between the video's aspect ratio and the container's — exact
    // clamping would need the letterbox rect too. Good enough to keep the
    // viewport from panning past the frame edge; revisit if it visibly clips
    // on a very differently-shaped portable monitor.
    private func clamp() {
        let half = 0.5 / max(zoom, 1)
        centerNorm.x = min(max(centerNorm.x, half), 1 - half)
        centerNorm.y = min(max(centerNorm.y, half), 1 - half)
    }
}

/// Non-interactive video render surface that applies `Viewport`'s zoom/pan
/// transform instead of the plain aspect-fit `VideoUIView` uses directly.
/// Has no gesture recognizers of its own — see the file-header note.
final class PanZoomContainerUIView: UIView {
    private let videoView = VideoUIView(frame: .zero, interactive: false)

    weak var client: StreamClient? {
        didSet { videoView.client = client }
    }
    var videoSize: CGSize = .zero { didSet { setNeedsLayout() } }
    var zoom: CGFloat = 1 { didSet { setNeedsLayout() } }
    var centerNorm = CGPoint(x: 0.5, y: 0.5) { didSet { setNeedsLayout() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .black
        addSubview(videoView)
    }
    required init?(coder: NSCoder) { fatalError() }

    func enqueue(_ sample: CMSampleBuffer) { videoView.enqueue(sample) }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyTransform()
    }

    /// Lays the video out at its normal aspect-fit rect (zoom 1), then scales
    /// + repositions it so the point at `centerNorm` (within that fit rect)
    /// lands on the container's own center — the standard "scale about
    /// center, then correct center" trick, so no manual matrix math is
    /// needed for the pan.
    private func applyTransform() {
        guard videoSize.width > 0, videoSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            videoView.transform = .identity
            videoView.frame = bounds
            return
        }
        videoView.videoSize = videoSize
        videoView.transform = .identity
        let fit = AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
        videoView.frame = fit
        let fitCenter = CGPoint(x: fit.midX, y: fit.midY)
        let focus = CGPoint(x: fit.minX + centerNorm.x * fit.width, y: fit.minY + centerNorm.y * fit.height)
        let mid = CGPoint(x: bounds.midX, y: bounds.midY)
        videoView.transform = CGAffineTransform(scaleX: zoom, y: zoom)
        videoView.center = CGPoint(x: mid.x - (focus.x - fitCenter.x) * zoom,
                                   y: mid.y - (focus.y - fitCenter.y) * zoom)
    }
}

struct PanZoomVideoView: UIViewRepresentable {
    @ObservedObject var client: StreamClient
    @ObservedObject var viewport: Viewport

    func makeUIView(context: Context) -> PanZoomContainerUIView {
        let view = PanZoomContainerUIView()
        view.client = client
        client.onSampleBuffer = { [weak view] sample in view?.enqueue(sample) }
        return view
    }

    func updateUIView(_ view: PanZoomContainerUIView, context: Context) {
        view.videoSize = client.videoSize
        view.zoom = viewport.zoom
        view.centerNorm = viewport.centerNorm
    }
}

/// The gesture half of manual pan+zoom: two-finger drag pans, pinch zooms.
/// Mutates `Viewport` only — no video, no protocol messages. Lives on the
/// iPad's own screen (see the file-header note) via `PanZoomGestureSurface`.
final class PanZoomUIView: UIView {
    let viewport: Viewport
    private var lastPan: CGPoint = .zero

    init(viewport: Viewport) {
        self.viewport = viewport
        super.init(frame: .zero)
        backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch))
        addGestureRecognizer(pinch)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        if g.state == .began { lastPan = .zero }
        let t = g.translation(in: self)
        let delta = CGPoint(x: t.x - lastPan.x, y: t.y - lastPan.y)
        lastPan = t
        if delta.x != 0 || delta.y != 0 { viewport.pan(delta: delta) }
    }

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began: viewport.pinchBegan()
        case .changed: viewport.pinchChanged(scale: g.scale)
        default: break
        }
    }
}

struct PanZoomGestureSurface: UIViewRepresentable {
    @ObservedObject var viewport: Viewport
    func makeUIView(context: Context) -> PanZoomUIView { PanZoomUIView(viewport: viewport) }
    func updateUIView(_ view: PanZoomUIView, context: Context) {}
}
