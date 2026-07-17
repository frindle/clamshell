import Foundation
import AVFoundation

// iPad-side audio playback: AAC-LC packets in (from AUDIO_FRAME) -> PCM via
// AVAudioConverter -> AVAudioEngine player node. The wire format is the fixed
// 48 kHz stereo AAC-LC the Mac's AudioEncoder produces, so no cookie is needed.
//
// ponytail: a small scheduled-buffer jitter buffer is all a LAN/tunnel
// remote-desktop stream needs — no PLL, no sample-rate drift correction.

final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private let aacFormat: AVAudioFormat
    private let pcmFormat: AVAudioFormat
    private var started = false

    init?() {
        var desc = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024,
            mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        guard let aac = AVAudioFormat(streamDescription: &desc),
              let pcm = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2) else { return nil }
        aacFormat = aac
        pcmFormat = pcm
        converter = AVAudioConverter(from: aac, to: pcm)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: pcm)
    }

    private func startIfNeeded() {
        guard !started else { return }
        started = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        do { try engine.start(); player.play() }
        catch { started = false }
    }

    /// Decodes and schedules one AAC packet. Called on the network queue.
    func play(aac: Data) {
        guard let converter else { return }
        startIfNeeded()

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
        guard status != .error, pcm.frameLength > 0 else { return }
        player.scheduleBuffer(pcm, completionHandler: nil)
    }

    func stop() {
        player.stop()
        engine.stop()
        started = false
    }
}
