import SwiftUI
import Network
import AVFoundation
import CoreMedia

// ClamshellViewer — Phase 1 iPad client for the Clamshell stream protocol
// (see ../PROTOCOL.md). One full-screen view: connect to the Mac, receive
// framed HEVC/H.264 NAL units, hardware-decode + render them via
// AVSampleBufferDisplayLayer, and forward touches as mouse input.
// StreamProtocol.swift and FrameAssembler.swift are shared with the Mac host.

@main
struct ViewerApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

// MARK: - Network client

final class StreamClient: ObservableObject {
    enum Status: Equatable {
        case idle, connecting, streaming(String), failed(String)
    }

    @Published var status: Status = .idle
    @Published var videoSize: CGSize = .zero

    /// Decoded-ready compressed samples for the display layer. Called on the
    /// network queue; AVSampleBufferDisplayLayer enqueue is thread-safe.
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    private var connection: NWConnection?
    private var parser: StreamMessageParser?
    private var assembler: FrameAssembler?
    private let queue = DispatchQueue(label: "clamshell.viewer.net")

    func connect(host: String) {
        disconnect()
        status = .connecting
        guard let port = NWEndpoint.Port(rawValue: streamDefaultPort) else { return }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        connection = conn

        let parser = StreamMessageParser()
        parser.onMessage = { [weak self] type, payload in self?.handle(type: type, payload: payload) }
        self.parser = parser

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                conn.send(content: StreamMessage.hello(requestedCodec: .hevc),
                          completion: .contentProcessed { _ in })
            case .failed(let error):
                DispatchQueue.main.async { self?.status = .failed("\(error)") }
            case .cancelled:
                DispatchQueue.main.async { if self?.status != .idle { self?.status = .idle } }
            default: break
            }
        }
        conn.start(queue: queue)
        receiveLoop(conn)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        parser = nil
        assembler = nil
        status = .idle
        videoSize = .zero
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, complete, error in
            guard let self, self.connection === conn else { return }
            if let data, !data.isEmpty { self.parser?.feed(data) }
            if complete || error != nil {
                DispatchQueue.main.async { self.status = .failed("connection closed") }
                return
            }
            self.receiveLoop(conn)
        }
    }

    private func handle(type: StreamMessageType, payload: Data) {
        switch type {
        case .helloAck:
            guard payload.count >= 10,
                  let codec = StreamCodec(rawValue: payload[payload.startIndex + 1]) else { return }
            let width = payload.beUInt32(at: 2), height = payload.beUInt32(at: 6)
            assembler = FrameAssembler(codec: codec)
            DispatchQueue.main.async {
                self.videoSize = CGSize(width: Double(width), height: Double(height))
                self.status = .streaming("\(codec == .hevc ? "HEVC" : "H.264") \(width)x\(height)")
            }
        case .videoFrame:
            guard let sample = assembler?.assemble(payload: payload) else { return }
            onSampleBuffer?(sample)
        default:
            break // client never receives input/hello/keyframeRequest
        }
    }

    // MARK: Input (normalized 0..1 display coordinates)

    private func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    func sendMouseMove(x: Float, y: Float) { send(StreamMessage.mouseMove(x: x, y: y)) }
    func sendMouseButton(button: UInt8, down: Bool, x: Float, y: Float) {
        send(StreamMessage.mouseButton(button: button, down: down, x: x, y: y))
    }
    func requestKeyframe() { send(StreamMessage.frame(type: .keyframeRequest)) }
}

// MARK: - Video view (render + touch capture)

final class VideoUIView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    weak var client: StreamClient?
    var videoSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        displayLayer.videoGravity = .resizeAspect
        isMultipleTouchEnabled = false
        backgroundColor = .black
    }
    required init?(coder: NSCoder) { fatalError() }

    func enqueue(_ sample: CMSampleBuffer) {
        if displayLayer.status == .failed {
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

    func makeUIView(context: Context) -> VideoUIView {
        let view = VideoUIView(frame: .zero)
        view.client = client
        client.onSampleBuffer = { [weak view] sample in view?.enqueue(sample) }
        return view
    }

    func updateUIView(_ view: VideoUIView, context: Context) {
        view.videoSize = client.videoSize
    }
}

// MARK: - UI

struct ContentView: View {
    @StateObject private var client = StreamClient()
    @AppStorage("hostAddress") private var host = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if case .streaming = client.status {
                VideoView(client: client)
                    .ignoresSafeArea()
                    .overlay(alignment: .topTrailing) {
                        Button {
                            client.disconnect()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title)
                                .foregroundStyle(.white.opacity(0.35))
                        }
                        .padding()
                    }
            } else {
                connectForm
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }

    private var connectForm: some View {
        VStack(spacing: 16) {
            Text("Clamshell Viewer").font(.title2).foregroundStyle(.white)
            TextField("Mac address (e.g. 10.0.1.5 or mac.tailnet.ts.net)", text: $host)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .frame(maxWidth: 420)
            Button("Connect") { client.connect(host: host.trimmingCharacters(in: .whitespaces)) }
                .buttonStyle(.borderedProminent)
                .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
            switch client.status {
            case .connecting: ProgressView().tint(.white)
            case .failed(let reason): Text(reason).font(.footnote).foregroundStyle(.red)
            default: EmptyView()
            }
        }
        .padding()
    }
}
