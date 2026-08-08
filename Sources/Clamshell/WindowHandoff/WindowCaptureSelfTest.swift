import Foundation
@preconcurrency import ScreenCaptureKit

// `clamshell window-capture-selftest [windowId]` — second slice of Window
// Handoff, after window-list (enumeration only). Proves SCContentFilter can
// actually capture a SINGLE window's frames, not just list it — the thing
// window-list can't tell you. No encode/network yet (that's proven
// separately by stream-selftest); this is capture-only, same incremental
// spirit as the rest of this feature.
//
// Without a windowId argument, captures whatever window-list would print
// first. windowId must be one printed by `clamshell window-list` in this
// same session -- SCWindow IDs are not guaranteed stable across relaunches
// of the target app.
enum WindowCaptureSelfTest {
    private final class Output: NSObject, SCStreamOutput, SCStreamDelegate {
        var onSample: ((CMSampleBuffer) -> Void)?
        var onStop: ((Error?) -> Void)?
        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen, sampleBuffer.isValid else { return }
            onSample?(sampleBuffer)
        }
        func stream(_ stream: SCStream, didStopWithError error: Error) {
            onStop?(error)
        }
    }

    static func run(windowId: UInt32?) async -> Int32 {
        if !CGPreflightScreenCaptureAccess() {
            print("FAILED: Screen Recording permission not granted.")
            return 1
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            print("FAILED: could not list shareable content: \(error)")
            return 1
        }

        let selfPid = ProcessInfo.processInfo.processIdentifier
        let candidates = content.windows.filter { w in
            guard let title = w.title, !title.isEmpty else { return false }
            guard let app = w.owningApplication, app.processID != selfPid else { return false }
            return w.frame.width >= 100 && w.frame.height >= 100
        }
        let target: SCWindow?
        if let windowId {
            target = candidates.first(where: { $0.windowID == windowId })
        } else {
            target = candidates.first
        }
        guard let target else {
            print("FAILED: no matching capturable window" + (windowId.map { " (id \($0))" } ?? ""))
            return 1
        }
        print("Capturing: \(target.owningApplication?.applicationName ?? "?") — \(target.title ?? "?") (\(Int(target.frame.width))x\(Int(target.frame.height)))")

        let config = SCStreamConfiguration()
        config.width = Int(target.frame.width)
        config.height = Int(target.frame.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.showsCursor = false // a remoted app window shouldn't carry the source machine's cursor

        // desktopIndependentWindow: the whole point -- this window's pixels
        // regardless of occlusion/off-screen position (not minimized), unlike
        // SCContentFilter(display:excludingWindows:) which needs a display.
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let output = Output()
        let stream = SCStream(filter: filter, configuration: config, delegate: output)

        var frameCount = 0
        var firstFrameSize: (Int, Int)?
        let lock = NSLock()
        let done = DispatchSemaphore(value: 0)
        var stopError: Error?

        output.onSample = { sample in
            let count: Int = lock.withLock {
                frameCount += 1
                if firstFrameSize == nil, let pb = sample.imageBuffer {
                    firstFrameSize = (CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb))
                }
                return frameCount
            }
            if count >= 30 { done.signal() } // ~1s at 30fps, enough to prove real frames are flowing
        }
        output.onStop = { error in
            stopError = error
            done.signal()
        }

        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "window-capture-selftest"))
            try await stream.startCapture()
        } catch {
            print("FAILED: could not start capture: \(error)")
            return 1
        }

        let result = done.wait(timeout: .now() + 10)
        try? await stream.stopCapture()

        let (finalCount, finalSize): (Int, (Int, Int)?) = lock.withLock {
            (frameCount, firstFrameSize)
        }

        if let stopError {
            print("FAILED: stream stopped with error: \(stopError)")
            return 1
        }
        guard result == .success, finalCount > 0 else {
            print("FAILED: no frames received within 10s (window occluded/minimized/off-screen with no compositor updates?)")
            return 1
        }
        let (w, h) = finalSize ?? (0, 0)
        print("PASS: \(finalCount) frames captured, \(w)x\(h)")
        return 0
    }
}
