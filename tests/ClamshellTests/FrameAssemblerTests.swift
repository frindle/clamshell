import XCTest
@testable import Clamshell

/// Bad input must be dropped, never crash: the payload comes off the network.
final class FrameAssemblerTests: XCTestCase {
    private func payload(keyframe: Bool, nal: Data) -> Data {
        var p = Data([keyframe ? 1 : 0])
        p.appendBE(UInt64(1000))
        p.append(nal)
        return p
    }

    func testTooShortPayloadIsDropped() {
        let a = FrameAssembler(codec: .h264)
        XCTAssertNil(a.assemble(payload: Data()))
        XCTAssertNil(a.assemble(payload: Data(repeating: 0, count: 9)))
    }

    func testNalLengthPastEndIsDropped() {
        var nal = Data(); nal.appendBE(UInt32(500)); nal.append(Data([0x65, 1, 2]))
        for codec in [StreamCodec.h264, .hevc] {
            XCTAssertNil(FrameAssembler(codec: codec).assemble(payload: payload(keyframe: true, nal: nal)))
        }
    }

    func testZeroNalLengthIsDropped() {
        var nal = Data(); nal.appendBE(UInt32(0)); nal.append(Data([0x65, 1, 2, 3]))
        XCTAssertNil(FrameAssembler(codec: .h264).assemble(payload: payload(keyframe: false, nal: nal)))
    }

    /// A delta frame before any keyframe has no parameter sets to decode with.
    func testDeltaBeforeKeyframeIsDropped() {
        var nal = Data(); nal.appendBE(UInt32(3)); nal.append(Data([0x41, 1, 2]))
        let a = FrameAssembler(codec: .h264)
        XCTAssertNil(a.assemble(payload: payload(keyframe: false, nal: nal)))
        XCTAssertNil(a.formatDescription)
    }
}
