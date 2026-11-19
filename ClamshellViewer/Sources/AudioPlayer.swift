import Foundation
import AVFoundation

// iPad-side audio playback: AAC-LC packets in (from AUDIO_FRAME) -> PCM via
// AVAudioConverter -> AVAudioEngine player node. The wire format is the fixed
// 48 kHz stereo AAC-LC the Mac's AudioEncoder produces, so no cookie is needed.
//
// Buffers are scheduled as they arrive and counted until they have played. When
// about 200 ms is already waiting (a host sending faster than real time), the
// new buffer is dropped so latency and memory stay bounded. There is no PLL and
// no sample-rate drift correction. If the engine has stopped (for example after
// an audio interruption) it is started again on the next packet.

final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private let aacFormat: AVAudioFormat
    private let pcmFormat: AVAudioFormat
    /// Guards `gate`, the engine and the player node: play runs on the network queue,
    /// stop and open on others, and a start racing a stop is undefined for AVAudioEngine.
    private let engineLock = NSLock()
    private var gate = AudioStartGate()
    /// Each buffer is 1024 frames at 48 kHz, about 21 ms: 9 of them is about 192 ms.
    private static let maxQueued = 9
    private let queueLock = NSLock()
    private var queued = 0
    /// Bumped when the player is stopped, so completions of buffers it threw
    /// away do not lower the count of the next run.
    private var generation = 0
    private var dropped = 0

    init?() {
        var desc = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024,
            mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        guard let aac = AVAudioFormat(streamDescription: &desc),
              let pcm = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2) else {
            clogViewer("audio: FAILED to derive AAC/PCM formats — audio disabled for this session")
            return nil
        }
        aacFormat = aac
        pcmFormat = pcm
        converter = AVAudioConverter(from: aac, to: pcm)
        if converter == nil {
            // The no-magic-cookie AAC path is the untested risk area; make its
            // failure unmissable rather than silently dropping every packet.
            clogViewer("audio: AVAudioConverter creation FAILED for cookie-less AAC-LC 48kHz stereo — audio disabled")
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: pcm)
    }

    /// Called with `engineLock` held. Returns false when the packet should not be played.
    private func startIfNeededLocked() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if gate.started, !engine.isRunning {
            // Stopped under us (an interruption, a route change): start again.
            gate.recordEngineStopped()
            resetQueue()
        }
        switch gate.decide(now: now) {
        case .skip: return false
        case .running: return true
        case .tryStart: break
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        do {
            try engine.start()
            player.play()
            gate.recordStarted()
            clogViewer("audio: engine started (AAC-LC 48kHz stereo -> PCM)")
            return true
        } catch {
            if let held = gate.recordFailure(now: now) {
                clogViewer("audio: engine start FAILED: \(error.localizedDescription)" +
                           (held > 0 ? " (\(held) more failures not logged)" : "") + " — retrying with back-off")
            }
            return false
        }
    }

    /// A new session begins (HELLO_ACK): audio may start again.
    func open() {
        engineLock.lock()
        gate.open()
        engineLock.unlock()
    }

    /// Decodes and schedules one AAC packet. Called on the network queue.
    func play(aac: Data) {
        guard let converter, !aac.isEmpty else { return } // empty AUDIO_FRAME: nothing to decode
        engineLock.lock()
        let ok = startIfNeededLocked()
        engineLock.unlock()
        guard ok else { return }

        let compressed = AVAudioCompressedBuffer(
            format: aacFormat, packetCapacity: 1, maximumPacketSize: aac.count)
        compressed.byteLength = UInt32(aac.count)
        compressed.packetCount = 1
        aac.withUnsafeBytes { raw in
            compressed.data.copyMemory(from: raw.baseAddress!, byteCount: aac.count)
        }
        if let pd = compressed.packetDescriptions {
            pd.pointee = AudioStreamPacketDescription(
                mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(aac.count))
        }

        guard let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 1024) else { return }
        var fed = false
        var err: NSError?
        let status = converter.convert(to: pcm, error: &err) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return compressed
        }
        guard status != .error, pcm.frameLength > 0 else {
            // Runs per packet (~46/s), so throttle: first few, then 1-per-500.
            decodeErrors += 1
            if decodeErrors <= 5 || decodeErrors % 500 == 0 {
                clogViewer("audio: AAC decode error #\(decodeErrors): \(err?.localizedDescription ?? "no PCM produced (status \(status.rawValue))")")
            }
            return
        }
        // Scheduling happens under the engine lock and only while the engine is started: a
        // buffer decoded for a session that has since closed must not wait in the player
        // and be heard at the start of the next one.
        engineLock.lock()
        defer { engineLock.unlock() }
        guard gate.isOpen, gate.started else { return }
        queueLock.lock()
        if queued >= Self.maxQueued {
            dropped += 1
            let n = dropped
            queueLock.unlock()
            if n <= 5 || n % 500 == 0 { clogViewer("audio: queue full, dropped a buffer (#\(n))") }
            return
        }
        queued += 1
        let mine = generation
        queueLock.unlock()
        player.scheduleBuffer(pcm, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.queueLock.lock()
            if self.generation == mine, self.queued > 0 { self.queued -= 1 }
            self.queueLock.unlock()
        }
    }

    private func resetQueue() {
        queueLock.lock()
        generation += 1
        queued = 0
        queueLock.unlock()
    }
    private var decodeErrors = 0

    /// The session ended. Shuts the gate first, under the lock, so a packet already on its
    /// way cannot start the engine again; `open()` reopens it for the next session.
    func stop() {
        engineLock.lock()
        gate.close()
        player.stop()
        engine.stop()
        resetQueue()
        engineLock.unlock()
    }
}
