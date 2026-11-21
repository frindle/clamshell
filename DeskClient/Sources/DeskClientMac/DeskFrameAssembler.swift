#if os(macOS)
import Foundation
import CoreMedia

/// Which video codec a window stream uses.
public enum DeskCodec {
    case h264
    case hevc
}

/// Turns the NAL bytes of a WINDOW_STREAM_FRAME into a CMSampleBuffer for AVSampleBufferDisplayLayer.
///
/// This is a copy of the iOS viewer's FrameAssembler, adapted to take plain bytes. It is copied, not shared,
/// because the iOS project compiles the original from the Streaming folder and must not change.
/// The bytes are AVCC: a 4-byte big-endian length before each NAL. Keyframes carry parameter sets in-band.
public final class DeskFrameAssembler {
    private let codec: DeskCodec
    public private(set) var formatDescription: CMVideoFormatDescription?
    public private(set) var dropCount = 0
    public private(set) var lastDropReason: String?

    public init(codec: DeskCodec) { self.codec = codec }

    private func drop(_ reason: String) -> CMSampleBuffer? {
        dropCount += 1
        lastDropReason = reason
        return nil
    }

    /// `flags` bit 0 marks a keyframe. `nal` is the AVCC data. `ptsMicros` is the presentation time.
    public func assemble(flags: UInt8, ptsMicros: UInt64, nal: [UInt8]) -> CMSampleBuffer? {
        let keyframe = flags & 1 == 1
        var parameterSets: [[UInt8]] = []
        var slices: [UInt8] = []
        slices.reserveCapacity(nal.count)

        var offset = 0
        while offset + 4 <= nal.count {
            let length = (Int(nal[offset]) << 24) | (Int(nal[offset + 1]) << 16) | (Int(nal[offset + 2]) << 8) | Int(nal[offset + 3])
            guard length > 0, offset + 4 + length <= nal.count else {
                return drop("malformed NAL length \(length) at offset \(offset)")
            }
            let unit = Array(nal[(offset + 4) ..< (offset + 4 + length)])
            if isParameterSet(unit) {
                parameterSets.append(unit)
            } else {
                slices.append(contentsOf: nal[offset ..< (offset + 4)])
                slices.append(contentsOf: unit)
            }
            offset += 4 + length
        }

        if !parameterSets.isEmpty, let fresh = makeFormatDescription(parameterSets) {
            formatDescription = fresh
        }
        guard let format = formatDescription else { return drop("no format description yet") }
        guard !slices.isEmpty else { return drop("frame had no slices") }

        var blockBuffer: CMBlockBuffer?
        let count = slices.count
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: count, flags: 0, blockBufferOut: &blockBuffer
        ) == noErr, let block = blockBuffer else { return drop("block buffer failed") }
        let copyStatus = slices.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: count)
        }
        guard copyStatus == noErr else { return drop("block buffer copy failed") }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(ptsMicros), timescale: 1_000_000),
            decodeTimeStamp: .invalid)
        var sizes = [count]
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sample
        ) == noErr, let sb = sample else { return drop("sample buffer failed") }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [CFMutableDictionary],
           let dict = attachments.first {
            if !keyframe {
                CFDictionarySetValue(dict,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            // A live stream: show each frame as soon as it is decoded.
            CFDictionarySetValue(dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }

    private func isParameterSet(_ unit: [UInt8]) -> Bool {
        guard let first = unit.first else { return false }
        switch codec {
        case .h264:
            let t = first & 0x1F
            return t == 7 || t == 8
        case .hevc:
            let t = (first >> 1) & 0x3F
            return t == 32 || t == 33 || t == 34
        }
    }

    private func makeFormatDescription(_ sets: [[UInt8]]) -> CMVideoFormatDescription? {
        var format: CMVideoFormatDescription?
        let status: OSStatus = withPointers(sets) { pointers, sizes in
            switch codec {
            case .h264:
                guard sets.count >= 2 else { return OSStatus(-1) }
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            case .hevc:
                guard sets.count >= 3 else { return OSStatus(-1) }
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
            }
        }
        return status == noErr ? format : nil
    }

    private func withPointers(_ sets: [[UInt8]], _ body: ([UnsafePointer<UInt8>], [Int]) -> OSStatus) -> OSStatus {
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        func recurse(_ i: Int) -> OSStatus {
            if i == sets.count { return body(pointers, sizes) }
            return sets[i].withUnsafeBufferPointer { buf in
                pointers.append(buf.baseAddress!)
                sizes.append(buf.count)
                return recurse(i + 1)
            }
        }
        return recurse(0)
    }
}
#endif
