import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// Captures the main display with ScreenCaptureKit for RFB clients. Capture
/// runs only while at least one client is connected, at the display's size in
/// points, in BGRA. The newest frame is kept; the server polls it.
final class RFBScreenCapture: NSObject, RFBFrameSource, SCStreamOutput, SCStreamDelegate {
    private let lock = NSLock()
    private var holders = 0
    private var stream: SCStream?
    private var latest: CVPixelBuffer?
    private var widthPx = 0, heightPx = 0
    private var starting = false
    private let queue = DispatchQueue(label: "clamshell.rfb.capture")

    /// The display being captured, for input mapping.
    private(set) var displayID: CGDirectDisplayID = CGMainDisplayID()

    func acquireFrames() -> Bool {
        lock.lock()
        holders += 1
        let needStart = stream == nil && !starting
        if needStart { starting = true }
        lock.unlock()
        if needStart { startCapture() }
        // Wait for a first frame (the display may still be waking).
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            lock.lock(); let ready = latest != nil; lock.unlock()
            if ready { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        releaseFrames()
        return false
    }

    func releaseFrames() {
        lock.lock()
        holders = max(holders - 1, 0)
        let stop = holders == 0 ? stream : nil
        if holders == 0 { stream = nil; latest = nil; starting = false }
        lock.unlock()
        stop?.stopCapture { _ in }
    }

    var size: (width: Int, height: Int) {
        lock.lock(); defer { lock.unlock() }
        return (widthPx, heightPx)
    }

    func withLatestFrame(_ body: (RFBFrameView) -> Void) -> Bool {
        lock.lock()
        let buffer = latest
        lock.unlock()
        guard let buffer else { return false }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
        body(RFBFrameView(base: base.assumingMemoryBound(to: UInt8.self),
                          bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                          width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)))
        return true
    }

    private func startCapture() {
        Task {
            do {
                let found = try await DisplayWakeRetry.run(
                    wake: { DisplayWake.shared.wake("Clamshell screen share found no display") },
                    sleep: { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
                    attempt: { () async throws -> SCDisplay? in
                        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                        return content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first
                    })
                guard let display = found else {
                    clog("RFB: no display to capture")
                    markFailed()
                    return
                }
                let config = SCStreamConfiguration()
                config.width = display.width
                config.height = display.height
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                config.queueDepth = 3
                config.showsCursor = true
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let s = SCStream(filter: filter, configuration: config, delegate: self)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                try await s.startCapture()
                lock.lock()
                if holders == 0 {
                    lock.unlock()
                    s.stopCapture { _ in }
                    return
                }
                stream = s
                displayID = display.displayID
                widthPx = display.width
                heightPx = display.height
                starting = false
                lock.unlock()
            } catch {
                clog("RFB: capture failed to start: \(error.localizedDescription)")
                markFailed()
            }
        }
    }

    private func markFailed() {
        lock.lock(); starting = false; lock.unlock()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        latest = buffer
        widthPx = CVPixelBufferGetWidth(buffer)
        heightPx = CVPixelBufferGetHeight(buffer)
        lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        clog("RFB: capture stopped: \(error.localizedDescription)")
        lock.lock()
        self.stream = nil
        latest = nil
        starting = false
        let again = holders > 0
        if again { starting = true }
        lock.unlock()
        if again {
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in self?.startCapture() }
        }
    }
}

/// Starts and stops the RFB server for a process. Both the Clamshell app and
/// the login-window agent use it, and the loser of the port race keeps trying.
final class RFBRuntime {
    static let shared = RFBRuntime()
    private var server: RFBServer?
    private let capture = RFBScreenCapture()

    func start() {
        guard server == nil else { return }
        let capture = self.capture
        let s = RFBServer(
            options: .init(port: UInt16(RedirectPolicy.backendPort)),
            authenticator: OpenDirectoryAuthenticator(),
            source: capture,
            makeInput: { InjectorInputSink(displayID: capture.displayID) },
            enabled: { RemoteAccessSwitch.isEnabled() })
        server = s
        s.startWhenPossible()
    }

    func stop() {
        server?.stop()
        server = nil
    }
}
