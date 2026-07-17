import Foundation
import AVFoundation

// Host-side system-audio encoder. SCStream delivers system audio as PCM
// CMSampleBuffers (same stream as video); we transcode to AAC-LC with
// AVAudioConverter and hand each compressed packet to the caller.
//
// The wire format is fixed 48 kHz stereo AAC-LC — the same format the iPad
// rebuilds from streamAACFormat(), so no magic cookie has to cross the wire.
//
// ponytail: fixed 48 kHz stereo AAC-LC. That's what SCStream hands us and what
// the viewer expects; make it negotiable only if a device ever differs.

/// Fixed AAC-LC format shared by encoder and decoder. Nil only if the OS
/// refuses the ASBD (never seen in practice).
func streamAACFormat() -> AVAudioFormat? {
    var desc = AudioStreamBasicDescription(
        mSampleRate: 48000, mFormatID: kAudioFormatMPEG4AAC,
        mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024,
        mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
    return AVAudioFormat(streamDescription: &desc)
}

final class AudioEncoder: @unchecked Sendable {
    private var converter: AVAudioConverter?
    private let outputFormat: AVAudioFormat
    var onEncodedPacket: ((Data) -> Void)?

    init?() {
        guard let out = streamAACFormat() else { return nil }
        outputFormat = out
    }

    /// Feeds one PCM CMSampleBuffer from SCStream's `.audio` output.
    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        let conv: AVAudioConverter
        if let c = converter { conv = c }
        else {
            guard let c = AVAudioConverter(from: pcm.format, to: outputFormat) else {
                clog("STREAM: could not create AAC converter for \(pcm.format)")
                return
            }
            converter = c
            conv = c
        }

        let out = AVAudioCompressedBuffer(format: outputFormat, packetCapacity: 8, maximumPacketSize: 1536)
        var fed = false
        var err: NSError?
        let status = conv.convert(to: out, error: &err) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return pcm
        }
        guard status != .error, out.packetCount > 0 else {
            if let err { clog("STREAM: AAC encode error \(err)") }
            return
        }
        // A single convert() can yield several AAC access units; emit each one
        // separately so the iPad decodes one packet per AUDIO_FRAME.
        let base = out.data
        if let pd = out.packetDescriptions, out.packetCount > 1 {
            for i in 0..<Int(out.packetCount) {
                let d = pd[i]
                onEncodedPacket?(Data(bytes: base + Int(d.mStartOffset), count: Int(d.mDataByteSize)))
            }
        } else {
            onEncodedPacket?(Data(bytes: base, count: Int(out.byteLength)))
        }
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc),
              let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        let err = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        return err == noErr ? pcm : nil
    }
}
