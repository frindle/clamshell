#if os(macOS)
import AVFoundation

/// Plays host audio on the Mac. The iOS AudioPlayer relies on AVAudioSession, which macOS does not have, so
/// this one drives AVAudioEngine alone. It takes interleaved 16-bit PCM. A failed engine start backs off
/// (0.5 s, doubling to 5 s) so it is not retried on every packet, the same idea as the iOS AudioStartGate.
public final class DeskAudioPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let lock = NSLock()
    private var wired = false
    private var started = false
    private var failures = 0
    private var retryAt: TimeInterval = 0

    public init?(sampleRate: Double = 48_000, channels: UInt32 = 2) {
        guard let f = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: channels, interleaved: true) else {
            return nil
        }
        format = f
    }

    /// Queues one packet of interleaved 16-bit samples.
    public func play(pcm: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0, pcm.count >= bytesPerFrame else { return }
        guard startIfNeeded() else { return }
        let frames = AVAudioFrameCount(pcm.count / bytesPerFrame)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        guard let dst = buffer.audioBufferList.pointee.mBuffers.mData else { return }
        pcm.withUnsafeBytes { raw in
            if let base = raw.baseAddress { dst.copyMemory(from: base, byteCount: Int(frames) * bytesPerFrame) }
        }
        node.scheduleBuffer(buffer, completionHandler: nil)
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        if started {
            node.stop()
            engine.stop()
        }
        started = false
        failures = 0
        retryAt = 0
    }

    private func startIfNeeded() -> Bool {
        if started { return true }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= retryAt else { return false }
        if !wired {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            wired = true
        }
        do {
            try engine.start()
            node.play()
            started = true
            failures = 0
            return true
        } catch {
            failures += 1
            retryAt = now + min(0.5 * pow(2, Double(failures - 1)), 5)
            return false
        }
    }
}
#endif
