import Foundation
import CoreMedia
import VideoToolbox

// Host-side hardware encoder. Hardware acceleration is REQUIRED — the whole
// point of this pipeline is the media engine, so we refuse to run a software
// encode rather than silently burning CPU. HEVC is tried first (Apple Silicon
// media engines handle it efficiently), falling back to hardware H.264.

enum VideoEncoderError: Error, CustomStringConvertible {
    case noHardwareEncoder(OSStatus)
    var description: String {
        switch self {
        case .noHardwareEncoder(let s):
            return "no hardware video encoder available (VTCompressionSessionCreate: \(s))"
        }
    }
}

// @unchecked Sendable: the VTCompressionSession serializes internally; the
// only cross-thread state is the forceNextKeyframe flag (benign flag race).
final class VideoEncoder: @unchecked Sendable {
    let codec: StreamCodec
    let width: Int32
    let height: Int32
    /// True when VideoToolbox confirms the hardware path actually engaged.
    private(set) var isHardware = false
    private var session: VTCompressionSession

    /// Called with a wire-ready AVCC frame. Keyframes include in-band
    /// parameter sets. Invoked on VideoToolbox's internal queue.
    var onEncodedFrame: ((_ keyframe: Bool, _ ptsMicros: UInt64, _ nalData: Data) -> Void)?

    private var forceNextKeyframe = true // first frame after connect is always a keyframe

    /// Tries HEVC hardware first, then H.264 hardware. Throws if neither exists.
    static func makeHardwareEncoder(width: Int32, height: Int32,
                                    preferred: StreamCodec = .hevc) throws -> VideoEncoder {
        let order: [StreamCodec] = preferred == .hevc ? [.hevc, .h264] : [.h264, .hevc]
        var lastStatus: OSStatus = 0
        for codec in order {
            do {
                let enc = try VideoEncoder(codec: codec, width: width, height: height)
                if codec != preferred {
                    clog("STREAM: preferred codec \(preferred) has no hardware encoder — fell back to \(codec)")
                }
                return enc
            } catch VideoEncoderError.noHardwareEncoder(let s) {
                lastStatus = s
                clog("STREAM: no hardware \(codec) encoder (status \(s))")
            }
        }
        clog("STREAM: REFUSING to start — no hardware encoder for HEVC or H.264. Software fallback is disabled by design.")
        throw VideoEncoderError.noHardwareEncoder(lastStatus)
    }

    init(codec: StreamCodec, width: Int32, height: Int32) throws {
        self.codec = codec
        self.width = width
        self.height = height

        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width, height: height,
            codecType: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil,
            compressionSessionOut: &s
        )
        guard status == noErr, let session = s else {
            throw VideoEncoderError.noHardwareEncoder(status)
        }
        self.session = session

        // Belt and braces: confirm the hardware path actually engaged.
        let valueOut = UnsafeMutablePointer<CFTypeRef?>.allocate(capacity: 1)
        valueOut.initialize(to: nil)
        defer { valueOut.deinitialize(count: 1); valueOut.deallocate() }
        VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                              allocator: kCFAllocatorDefault, valueOut: UnsafeMutableRawPointer(valueOut))
        let hw = (valueOut.pointee as? Bool) ?? false
        isHardware = hw
        clog("STREAM: encoder created: \(codec) \(width)x\(height), hardware=\(hw)")
        if !hw {
            clog("STREAM: WARNING — encoder reports NOT hardware accelerated despite Require flag")
        }

        // Low-latency live-streaming tuning (not offline-quality defaults).
        setProp(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        setProp(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse) // no B-frames
        // MaxFrameDelayCount is rejected by Apple Silicon HW encoders
        // (kVTPropertyNotSupportedErr) — reordering off already gives zero delay.
        setProp(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
        setProp(kVTCompressionPropertyKey_ExpectedFrameRate, 60 as CFNumber)
        setProp(kVTCompressionPropertyKey_MaxKeyFrameInterval, 120 as CFNumber)
        setProp(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2 as CFNumber)
        // ponytail: fixed 20 Mbps, adaptive bitrate is a future phase
        setProp(kVTCompressionPropertyKey_AverageBitRate, 20_000_000 as CFNumber)
        setProp(kVTCompressionPropertyKey_ProfileLevel,
                codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel
                               : kVTProfileLevel_H264_High_AutoLevel)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    private func setProp(_ key: CFString, _ value: CFTypeRef) {
        let s = VTSessionSetProperty(session, key: key, value: value)
        if s != noErr { clog("STREAM: encoder property \(key) rejected (status \(s))") }
    }

    func requestKeyframe() { forceNextKeyframe = true }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        var props: CFDictionary?
        if forceNextKeyframe {
            forceNextKeyframe = false
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer,
            presentationTimeStamp: pts, duration: .invalid,
            frameProperties: props, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self, status == noErr, let sb = sampleBuffer else { return }
            self.emit(sb)
        }
    }

    func invalidate() {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }

    // MARK: - Sample buffer -> wire AVCC data

    private func emit(_ sb: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let keyframe = !notSync

        var nalData = Data()
        if keyframe, let format = CMSampleBufferGetFormatDescription(sb) {
            for ps in parameterSets(of: format) {
                var len = Data(); len.appendBE(UInt32(ps.count))
                nalData.append(len)
                nalData.append(ps)
            }
        }
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let base = pointer else { return }
        // VideoToolbox emits AVCC with the format description's NAL header
        // length; we created descriptors with 4, and VT uses 4 in practice,
        // so the payload is wire-ready as-is.
        nalData.append(UnsafeBufferPointer(start: UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self),
                                           count: length))

        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let micros = pts.isValid ? UInt64(max(0, pts.seconds) * 1_000_000) : 0
        onEncodedFrame?(keyframe, micros, nalData)
    }

    private func parameterSets(of format: CMFormatDescription) -> [Data] {
        var sets: [Data] = []
        var count = 0
        var nalHeaderLen: Int32 = 0
        let probe: OSStatus
        if codec == .hevc {
            probe = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: &nalHeaderLen)
        } else {
            probe = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: &nalHeaderLen)
        }
        guard probe == noErr else { return sets }
        if nalHeaderLen != 4 {
            clog("STREAM: unexpected NAL header length \(nalHeaderLen) from encoder (expected 4)")
        }
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            let s: OSStatus
            if codec == .hevc {
                s = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            } else {
                s = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            }
            if s == noErr, let p = ptr {
                sets.append(Data(bytes: p, count: size))
            }
        }
        return sets
    }
}
