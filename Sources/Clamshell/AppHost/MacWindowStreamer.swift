import AppKit
import CoreMedia
import DeskHost
@preconcurrency import ScreenCaptureKit

/// One window's capture and encode, using the same ScreenCaptureKit window filter and `VideoEncoder` as the
/// window-handoff self-tests. Full pixel size, 60 frames per second, no cursor.
/// Not yet done: re-creating the capture when the window changes size (the stream keeps its first size).
final class MacWindowStreamer: WindowStreamer {
    private var captures: [UInt32: Capture] = [:]

    func startStream(windowId: UInt32, sink: @escaping (Bool, UInt64, [UInt8]) -> Void) {
        guard captures[windowId] == nil else { return }
        let capture = Capture(windowId: windowId, sink: sink)
        captures[windowId] = capture
        Task { await capture.start() }
    }

    func stopStream(windowId: UInt32) {
        guard let capture = captures.removeValue(forKey: windowId) else { return }
        Task { await capture.stop() }
    }

    func requestKeyframe(windowId: UInt32) { captures[windowId]?.encoder?.requestKeyframe() }

    private final class Capture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
        let windowId: UInt32
        let sink: (Bool, UInt64, [UInt8]) -> Void
        var stream: SCStream?
        var encoder: VideoEncoder?
        private var stopped = false
        private let queue = DispatchQueue(label: "com.frindle.clamshell.apphost.capture")

        init(windowId: UInt32, sink: @escaping (Bool, UInt64, [UInt8]) -> Void) {
            self.windowId = windowId; self.sink = sink
        }

        func start() async {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                guard let window = content.windows.first(where: { $0.windowID == windowId }), !stopped else {
                    clog("APPHOST: window to stream not found")
                    return
                }
                let scale = CGFloat(MacWindowSource.scale(for: window.frame))
                let width = max(2, Int(window.frame.width * scale)) & ~1
                let height = max(2, Int(window.frame.height * scale)) & ~1
                let encoder = try VideoEncoder.makeEncoder(width: Int32(width), height: Int32(height), preferred: .hevc)
                encoder.onEncodedFrame = { [weak self] keyframe, pts, data in
                    guard let self = self else { return }
                    let bytes = [UInt8](data)
                    DispatchQueue.main.async { if !self.stopped { self.sink(keyframe, pts, bytes) } }
                }
                let config = SCStreamConfiguration()
                config.width = width
                config.height = height
                config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                config.queueDepth = 5
                config.showsCursor = false
                let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                self.encoder = encoder
                self.stream = stream
                try await stream.startCapture()
            } catch {
                clog("APPHOST: window capture did not start: \(error)")
            }
        }

        func stop() async {
            stopped = true
            encoder?.onEncodedFrame = nil
            try? await stream?.stopCapture()
            encoder?.invalidate()
            stream = nil; encoder = nil
        }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen, !stopped, sampleBuffer.isValid,
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                      as? [[SCStreamFrameInfo: Any]],
                  let statusRaw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: statusRaw) == .complete,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                  let enc = encoder,
                  CVPixelBufferGetWidth(pixelBuffer) == Int(enc.width),
                  CVPixelBufferGetHeight(pixelBuffer) == Int(enc.height) else { return }
            enc.encode(pixelBuffer, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }

        func stream(_ stream: SCStream, didStopWithError error: Error) {
            clog("APPHOST: window capture stopped: \(error)")
        }
    }
}
