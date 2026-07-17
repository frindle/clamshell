import Foundation
import CoreMedia

// Decode-side: turns a VIDEO_FRAME payload into a CMSampleBuffer ready for
// AVSampleBufferDisplayLayer / VTDecompressionSession. Shared between the iOS
// ClamshellViewer client and the Mac-side self test.

final class FrameAssembler {
    private let codec: StreamCodec
    private(set) var formatDescription: CMVideoFormatDescription?

    init(codec: StreamCodec) {
        self.codec = codec
    }

    /// Parses a VIDEO_FRAME payload (flags + pts + AVCC NALs). Keyframes carry
    /// parameter sets in-band; those refresh the format description and are
    /// stripped before the sample buffer is built.
    func assemble(payload: Data) -> CMSampleBuffer? {
        guard payload.count > 9 else { return nil }
        let keyframe = payload[payload.startIndex] & 1 == 1
        let ptsMicros = payload.beUInt64(at: 1)
        let nalData = payload.subdata(in: payload.startIndex + 9 ..< payload.endIndex)

        var parameterSets: [Data] = []
        var sliceData = Data(capacity: nalData.count)

        var offset = 0
        while offset + 4 <= nalData.count {
            let length = Int(nalData.beUInt32(at: offset))
            guard length > 0, offset + 4 + length <= nalData.count else { return nil }
            let nal = nalData.subdata(in: nalData.startIndex + offset + 4 ..< nalData.startIndex + offset + 4 + length)
            if isParameterSet(nal) {
                parameterSets.append(nal)
            } else {
                var lenBE = Data(); lenBE.appendBE(UInt32(length))
                sliceData.append(lenBE)
                sliceData.append(nal)
            }
            offset += 4 + length
        }

        if !parameterSets.isEmpty {
            formatDescription = makeFormatDescription(parameterSets: parameterSets) ?? formatDescription
        }
        guard let format = formatDescription, !sliceData.isEmpty else { return nil }

        // AVCC slice data -> CMBlockBuffer (copied so the buffer owns it).
        var blockBuffer: CMBlockBuffer?
        let count = sliceData.count
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: count, flags: 0, blockBufferOut: &blockBuffer
        ) == noErr, let block = blockBuffer else { return nil }
        let copyErr = sliceData.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: count)
        }
        guard copyErr == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(ptsMicros), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sizes = [count]
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sample
        ) == noErr, let sb = sample else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [CFMutableDictionary],
           let dict = attachments.first {
            if !keyframe {
                CFDictionarySetValue(dict,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            // Render as soon as decoded — this is a live stream, not media playback.
            CFDictionarySetValue(dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }

    private func isParameterSet(_ nal: Data) -> Bool {
        guard let first = nal.first else { return false }
        switch codec {
        case .h264:
            let type = first & 0x1F
            return type == 7 || type == 8 // SPS, PPS
        case .hevc:
            let type = (first >> 1) & 0x3F
            return type == 32 || type == 33 || type == 34 // VPS, SPS, PPS
        }
    }

    private func makeFormatDescription(parameterSets: [Data]) -> CMVideoFormatDescription? {
        var format: CMVideoFormatDescription?
        // Keep the Data objects alive across the pointer-based C call.
        let status: OSStatus = withParameterSetPointers(parameterSets) { pointers, sizes in
            switch codec {
            case .h264:
                guard parameterSets.count >= 2 else { return OSStatus(-1) }
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: parameterSets.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            case .hevc:
                guard parameterSets.count >= 3 else { return OSStatus(-1) }
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: parameterSets.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
            }
        }
        return status == noErr ? format : nil
    }

    /// Pins each parameter set and hands stable pointers to `body`.
    private func withParameterSetPointers(
        _ sets: [Data], _ body: ([UnsafePointer<UInt8>], [Int]) -> OSStatus
    ) -> OSStatus {
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        func recurse(_ index: Int) -> OSStatus {
            if index == sets.count { return body(pointers, sizes) }
            return sets[index].withUnsafeBytes { raw in
                pointers.append(raw.bindMemory(to: UInt8.self).baseAddress!)
                sizes.append(raw.count)
                return recurse(index + 1)
            }
        }
        return recurse(0)
    }
}
