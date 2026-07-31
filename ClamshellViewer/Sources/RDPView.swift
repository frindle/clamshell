import SwiftUI
import AVFoundation

// RDP framebuffer rendering + input capture, same shape as VideoView.swift
// but simpler: FreeRDP's GDI backend hands back a plain composited bitmap
// (RDPSession.frame) instead of compressed video samples, so there's no
// decoder session to manage — just `layer.contents = image` on every
// update. Touch/hover/scroll/keyboard forwarding mirrors VideoUIView.
//
// ponytail: layer.contents on every framebuffer update redraws the whole
// bitmap rather than just the FreeRDP-reported dirty rect. Simplest correct
// thing (CALayer diffs identical-pointer contents cheaply, and typical RDP
// sessions are mostly idle between updates); revisit with a dirty-rect
// CALayer sublayer scheme only if profiling shows this is a bottleneck on
// real hardware.

final class RDPUIView: UIView {
    weak var session: RDPSession?
    var desktopSize: CGSize = .zero
    private let interactive: Bool

    init(frame: CGRect, interactive: Bool) {
        self.interactive = interactive
        super.init(frame: frame)
        backgroundColor = .black
        layer.contentsGravity = .resizeAspect
        isMultipleTouchEnabled = false
        guard interactive else { return }

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(onHover))
        addGestureRecognizer(hover)
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(onScroll))
        scroll.allowedScrollTypesMask = .all
        scroll.maximumNumberOfTouches = 0 // indirect (trackpad/wheel) scroll only
        addGestureRecognizer(scroll)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFirstResponder: Bool { interactive }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil && interactive { becomeFirstResponder() }
    }

    func setFrame(_ image: CGImage?) {
        layer.contents = image
    }

    @objc private func onHover(_ g: UIHoverGestureRecognizer) {
        guard let (x, y) = normalized(g.location(in: self)) else { return }
        session?.sendMouseMove(x: x, y: y)
    }

    private var lastScroll: CGPoint = .zero
    @objc private func onScroll(_ g: UIPanGestureRecognizer) {
        if g.state == .began { lastScroll = .zero }
        let t = g.translation(in: self)
        let dy = Float(t.y - lastScroll.y)
        lastScroll = t
        if dy != 0 { session?.sendScroll(dy: dy) }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !RDPKeyMap.forward(presses, down: true, to: session) { super.pressesBegan(presses, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !RDPKeyMap.forward(presses, down: false, to: session) { super.pressesEnded(presses, with: event) }
    }

    private func normalized(_ point: CGPoint) -> (Float, Float)? {
        guard desktopSize != .zero, bounds.width > 0, bounds.height > 0 else { return nil }
        let rect = AVMakeRect(aspectRatio: desktopSize, insideRect: bounds)
        guard rect.width > 0, rect.height > 0 else { return nil }
        let x = Float((point.x - rect.minX) / rect.width)
        let y = Float((point.y - rect.minY) / rect.height)
        guard x >= 0, x <= 1, y >= 0, y <= 1 else { return nil }
        return (x, y)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, let (x, y) = normalized(t.location(in: self)) else { return }
        session?.sendMouseButton(button: 0, down: true, x: x, y: y)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, let (x, y) = normalized(t.location(in: self)) else { return }
        session?.sendMouseMove(x: x, y: y)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, let (x, y) = normalized(t.location(in: self)) else { return }
        session?.sendMouseButton(button: 0, down: false, x: x, y: y)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, let (x, y) = normalized(t.location(in: self)) else { return }
        session?.sendMouseButton(button: 0, down: false, x: x, y: y)
    }
}

struct RDPView: UIViewRepresentable {
    @ObservedObject var session: RDPSession
    var interactive = true

    func makeUIView(context: Context) -> RDPUIView {
        let view = RDPUIView(frame: .zero, interactive: interactive)
        view.session = session
        return view
    }

    func updateUIView(_ view: RDPUIView, context: Context) {
        view.desktopSize = session.desktopSize
        view.setFrame(session.frame)
    }
}
