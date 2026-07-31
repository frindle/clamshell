import Foundation
import CoreGraphics
import RDPBridge

// Swift-facing RDP connection, same shape as StreamClient but for the RDP
// connection mode (see RDPBridge/RDPBridge.h for the Obj-C layer underneath,
// and RDPView.swift / RDPKeyMap.swift for rendering + input, mirroring
// VideoView.swift / KeyMap.swift on the Clamshell-protocol path).
final class RDPSession: ObservableObject {
    enum Status: Equatable {
        case idle, connecting, streaming(String), failed(String)
    }

    @Published var status: Status = .idle
    @Published var desktopSize: CGSize = .zero
    /// Latest composited framebuffer. RDPView draws this directly (no
    /// decode step — FreeRDP's GDI backend already gives us a bitmap).
    @Published var frame: CGImage?

    /// Presented when the server's certificate can't be verified. Wire this
    /// up in the UI layer; if left nil, unverifiable certs are rejected
    /// (RDPBridgeSession's safe default) unless ignoreCertErrors was set.
    var onCertificatePrompt: ((_ subject: String, _ issuer: String, _ fingerprint: String, _ completion: @escaping (Bool) -> Void) -> Void)?

    private var bridge: RDPBridgeSession?

    func connect(host: String, port: UInt16, username: String, password: String,
                 domain: String?, width: Int, height: Int, ignoreCertErrors: Bool) {
        disconnect()
        status = .connecting
        clogViewer("RDP connecting to \(host):\(port) as \(username)")

        let session = RDPBridgeSession(host: host, port: port, username: username,
                                       password: password, domain: domain,
                                       width: Int32(width), height: Int32(height),
                                       ignoreCertErrors: ignoreCertErrors)
        session.onConnected = { [weak self] w, h in
            DispatchQueue.main.async {
                guard let self else { return }
                self.desktopSize = CGSize(width: Int(w), height: Int(h))
                self.status = .streaming("\(w)x\(h)")
                clogViewer("RDP connected: \(w)x\(h)")
            }
        }
        session.onFrameUpdate = { [weak self] image in
            DispatchQueue.main.async { self?.frame = image }
        }
        session.onDisconnected = { [weak self] errorMessage in
            DispatchQueue.main.async {
                guard let self else { return }
                if let errorMessage {
                    clogViewer("RDP disconnected: \(errorMessage)")
                    self.status = .failed(errorMessage)
                } else {
                    self.status = .idle
                }
                self.frame = nil
            }
        }
        session.onCertificateVerify = { [weak self] subject, issuer, fingerprint, completion in
            guard let prompt = self?.onCertificatePrompt else {
                completion(false)
                return
            }
            prompt(subject, issuer, fingerprint, completion)
        }

        bridge = session
        session.start()
    }

    func disconnect() {
        bridge?.stop()
        bridge = nil
        status = .idle
        frame = nil
        desktopSize = .zero
    }

    // MARK: Input (normalized 0..1 over desktopSize, matching StreamClient's
    // INPUT_MOUSE_MOVE convention so RDPView can reuse VideoView's touch
    // normalization logic unchanged).

    func sendMouseMove(x: Float, y: Float) { bridge?.sendMouseMoveX(x, y: y) }

    func sendMouseButton(button: UInt8, down: Bool, x: Float, y: Float) {
        let rdpButton: RDPMouseButton = button == 1 ? .right : (button == 2 ? .middle : .left)
        bridge?.send(rdpButton, down: down, x: x, y: y)
    }

    func sendScroll(dy: Float) { bridge?.sendScrollDeltaY(dy) }

    func sendScancode(_ code: UInt16, extended: Bool, down: Bool) {
        bridge?.sendScancode(code, extended: extended, down: down)
    }
}
