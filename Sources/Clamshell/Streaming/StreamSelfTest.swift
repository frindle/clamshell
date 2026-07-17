import Foundation
import Network
import CoreMedia
import CoreVideo
import VideoToolbox

// `Clamshell stream-selftest` — verifies the pipeline end-to-end without a
// display or an iPad: synthetic frames -> hardware encode -> wire framing ->
// real TCP loopback -> parse -> FrameAssembler -> hardware decode. Exercises
// everything except ScreenCaptureKit capture and input injection.

enum StreamSelfTest {
    static func run() -> Bool {
        let width: Int32 = 1280, height: Int32 = 720
        let frameCount = 60
        let port: UInt16 = 5999

        let encoder: VideoEncoder
        do {
            encoder = try VideoEncoder.makeHardwareEncoder(width: width, height: height)
        } catch {
            print("FAIL: \(error)")
            return false
        }
        print("encoder: \(encoder.codec) (hardware)")

        // Decode side state.
        let negotiatedCodec = encoder.codec
        let assembler = FrameAssembler(codec: negotiatedCodec)
        var decodeSession: VTDecompressionSession?
        var decodedFrames = 0
        var sawKeyframe = false
        let done = DispatchSemaphore(value: 0)
        let decodeLock = NSLock()

        // TCP loopback: server sends encoded frames, client decodes.
        let listener = try! NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
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
            print("FAIL: listener did not become ready")
            return false
        }

        let parser = StreamMessageParser()
        parser.onMessage = { type, payload in
            guard type == .videoFrame else { return }
            let keyframe = payload[payload.startIndex] & 1 == 1
            if keyframe { sawKeyframe = true }
            guard let sample = assembler.assemble(payload: payload) else {
                print("FAIL: could not assemble sample buffer (keyframe=\(keyframe))")
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
                    print("FAIL: no hardware decoder (status \(s))")
                    done.signal()
                    return
                }
                print("decoder: hardware \(negotiatedCodec) session created")
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
                    print("FAIL: decode error \(status)")
                }
            }
            if s != noErr { print("FAIL: VTDecompressionSessionDecodeFrame \(s)") }
        }

        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        func receiveLoop() {
            client.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, complete, error in
                if let data { parser.feed(data) }
                if complete || error != nil { return }
                receiveLoop()
            }
        }
        // Wait for the loopback connection before encoding.
        let connected = DispatchSemaphore(value: 0)
        client.stateUpdateHandler = { if case .ready = $0 { connected.signal() } }
        client.start(queue: DispatchQueue(label: "selftest.client"))
        receiveLoop()
        guard connected.wait(timeout: .now() + 5) == .success else {
            print("FAIL: loopback connection did not establish")
            return false
        }

        encoder.onEncodedFrame = { keyframe, pts, nalData in
            serverConn?.send(content: StreamMessage.videoFrame(keyframe: keyframe, ptsMicros: pts, nalData: nalData),
                             completion: .contentProcessed { _ in })
        }

        // Synthetic moving-gradient NV12 frames.
        for i in 0..<frameCount {
            guard let pb = makeNV12Frame(width: width, height: height, seed: i) else {
                print("FAIL: could not create pixel buffer")
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
        print(ok ? "PASS: \(decodedFrames)/\(frameCount) frames encoded (\(negotiatedCodec)) -> TCP -> decoded, keyframe seen"
                 : "FAIL: decoded \(decodedFrames)/\(frameCount) frames, keyframe seen: \(sawKeyframe)")
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
