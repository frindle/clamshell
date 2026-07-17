import Foundation
import Network
import CoreMedia
import CoreVideo
import VideoToolbox

// `Clamshell stream-selftest` — verifies the pipeline end-to-end without a
// display or an iPad: synthetic frames -> hardware encode -> wire framing ->
// real WebSocket loopback (NWListener server, URLSessionWebSocketTask client,
// exactly the transports the host and iPad use) -> parse -> FrameAssembler ->
// hardware decode. Exercises everything except ScreenCaptureKit capture and
// input injection.

enum StreamSelfTest {
    /// Runs TWO full pipelines concurrently — the dual-display case. The real
    /// risk of a second display is the second simultaneous VTCompressionSession
    /// falling back to software or hitting a session limit, so both encoders
    /// must confirm the hardware path engaged.
    static func run() -> Bool {
        let group = DispatchGroup()
        var resultA = false, resultB = false
        DispatchQueue.global().async(group: group) {
            resultA = runPipeline(label: "A", width: 1920, height: 1080, port: 5998)
        }
        DispatchQueue.global().async(group: group) {
            resultB = runPipeline(label: "B", width: 1280, height: 720, port: 5999)
        }
        guard group.wait(timeout: .now() + 60) == .success else {
            print("FAIL: dual-pipeline selftest timed out")
            return false
        }
        print(resultA && resultB ? "PASS: both concurrent pipelines hardware-encoded and decoded"
                                 : "FAIL: pipeline A=\(resultA) B=\(resultB)")
        return resultA && resultB
    }

    private static func runPipeline(label: String, width: Int32, height: Int32, port: UInt16) -> Bool {
        let frameCount = 60

        let encoder: VideoEncoder
        do {
            encoder = try VideoEncoder.makeHardwareEncoder(width: width, height: height)
        } catch {
            print("[\(label)] FAIL: \(error)")
            return false
        }
        guard encoder.isHardware else {
            print("[\(label)] FAIL: encoder created but hardware path did NOT engage (software fallback)")
            return false
        }
        print("[\(label)] encoder: \(encoder.codec) (hardware)")

        // Decode side state.
        let negotiatedCodec = encoder.codec
        let assembler = FrameAssembler(codec: negotiatedCodec)
        var decodeSession: VTDecompressionSession?
        var decodedFrames = 0
        var sawKeyframe = false
        let done = DispatchSemaphore(value: 0)
        let decodeLock = NSLock()

        // WebSocket loopback: server sends encoded frames, client decodes.
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        let listener = try! NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        let netQueue = DispatchQueue(label: "selftest.net")
        var serverConn: NWConnection?
        listener.newConnectionHandler = { conn in
            serverConn = conn
            conn.start(queue: netQueue)
        }
        let listening = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { listening.signal() } }
        listener.start(queue: netQueue)
        guard listening.wait(timeout: .now() + 5) == .success else {
            print("[\(label)] FAIL: listener did not become ready")
            return false
        }

        let parser = StreamMessageParser()
        parser.onMessage = { type, payload in
            guard type == .videoFrame else { return }
            let keyframe = payload[payload.startIndex] & 1 == 1
            if keyframe { sawKeyframe = true }
            guard let sample = assembler.assemble(payload: payload) else {
                print("[\(label)] FAIL: could not assemble sample buffer (keyframe=\(keyframe))")
                return
            }
            decodeLock.lock(); defer { decodeLock.unlock() }
            if decodeSession == nil, let format = assembler.formatDescription {
                let spec = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
                var session: VTDecompressionSession?
                let s = VTDecompressionSessionCreate(
                    allocator: kCFAllocatorDefault, formatDescription: format,
                    decoderSpecification: spec, imageBufferAttributes: nil,
                    outputCallback: nil, decompressionSessionOut: &session)
                guard s == noErr, let session else {
                    print("[\(label)] FAIL: no hardware decoder (status \(s))")
                    done.signal()
                    return
                }
                print("[\(label)] decoder: hardware \(negotiatedCodec) session created")
                decodeSession = session
            }
            guard let session = decodeSession else { return }
            let s = VTDecompressionSessionDecodeFrame(
                session, sampleBuffer: sample, flags: [], infoFlagsOut: nil
            ) { status, _, imageBuffer, _, _ in
                if status == noErr, imageBuffer != nil {
                    decodedFrames += 1
                    if decodedFrames == frameCount { done.signal() }
                } else {
                    print("[\(label)] FAIL: decode error \(status)")
                }
            }
            if s != noErr { print("[\(label)] FAIL: VTDecompressionSessionDecodeFrame \(s)") }
        }

        // Client transport is the same one the iPad uses.
        let client = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        client.maximumMessageSize = 64 << 20
        func receiveLoop() {
            client.receive { result in
                guard case .success(let message) = result else { return }
                if case .data(let data) = message { parser.feed(data) }
                receiveLoop()
            }
        }
        client.resume()
        receiveLoop()
        // Wait for the server to see the loopback connection before encoding.
        let deadline = Date().addingTimeInterval(5)
        while serverConn == nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        guard serverConn != nil else {
            print("[\(label)] FAIL: loopback connection did not establish")
            return false
        }

        encoder.onEncodedFrame = { keyframe, pts, nalData in
            let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
            let context = NWConnection.ContentContext(identifier: "msg", metadata: [metadata])
            serverConn?.send(content: StreamMessage.videoFrame(keyframe: keyframe, ptsMicros: pts, nalData: nalData),
                             contentContext: context, isComplete: true,
                             completion: .contentProcessed { _ in })
        }

        // Synthetic moving-gradient NV12 frames.
        for i in 0..<frameCount {
            guard let pb = makeNV12Frame(width: width, height: height, seed: i) else {
                print("[\(label)] FAIL: could not create pixel buffer")
                return false
            }
            encoder.encode(pb, pts: CMTime(value: CMTimeValue(i), timescale: 60))
            Thread.sleep(forTimeInterval: 1.0 / 120.0) // pace it slightly
        }

        let ok = done.wait(timeout: .now() + 10) == .success && decodedFrames >= frameCount && sawKeyframe
        encoder.invalidate()
        client.cancel()
        serverConn?.cancel()
        listener.cancel()
        print(ok ? "[\(label)] PASS: \(decodedFrames)/\(frameCount) frames encoded (\(negotiatedCodec)) -> WebSocket -> decoded, keyframe seen"
                 : "[\(label)] FAIL: decoded \(decodedFrames)/\(frameCount) frames, keyframe seen: \(sawKeyframe)")
        return ok
    }

    private static func makeNV12Frame(width: Int32, height: Int32, seed: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, Int(width), Int(height),
                                  kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                  attrs, &pb) == kCVReturnSuccess, let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        // Luma: diagonal gradient that shifts each frame so deltas are non-trivial.
        if let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let p = y.assumingMemoryBound(to: UInt8.self)
            for row in 0..<Int(height) {
                for col in 0..<Int(width) {
                    p[row * stride + col] = UInt8((row + col + seed * 4) & 0xFF)
                }
            }
        }
        // Chroma: flat gray.
        if let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            memset(uv, 128, stride * Int(height) / 2)
        }
        return buffer
    }
}
