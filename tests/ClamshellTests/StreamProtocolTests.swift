import XCTest
@testable import Clamshell

final class StreamProtocolTests: XCTestCase {
    /// Feeds `data` to a fresh parser in chunks of `chunk` bytes and returns
    /// what it emitted.
    private func parse(_ data: Data, chunk: Int? = nil) -> (messages: [(StreamMessageType, Data)], corrupt: Bool) {
        let parser = StreamMessageParser()
        var out: [(StreamMessageType, Data)] = []
        parser.onMessage = { out.append(($0, $1)) }
        if let chunk {
            var i = 0
            while i < data.count {
                let end = min(i + chunk, data.count)
                parser.feed(data.subdata(in: i ..< end))
                i = end
            }
        } else {
            parser.feed(data)
        }
        return (out, parser.corrupt)
    }

    // MARK: big-endian helpers

    func testBigEndianRoundTrip() {
        var d = Data()
        d.appendBE(UInt16(0xBEEF))
        d.appendBE(UInt32(0xDEADBEEF))
        d.appendBE(UInt64(0x0102_0304_0506_0708))
        d.appendBE(Float32(0.25))
        XCTAssertEqual(d.count, 18)
        XCTAssertEqual(d.beUInt16(at: 0), 0xBEEF)
        XCTAssertEqual(d.beUInt32(at: 2), 0xDEADBEEF)
        XCTAssertEqual(d.beUInt64(at: 6), 0x0102_0304_0506_0708)
        XCTAssertEqual(d.beFloat32(at: 14), 0.25)
    }

    /// A slice keeps its parent's indices; the readers must offset from
    /// `startIndex`, not from zero.
    func testBigEndianReadsOnSlice() {
        var d = Data([0xFF, 0xFF, 0xFF])
        d.appendBE(UInt32(0x11223344))
        d.appendBE(UInt16(0x5566))
        let slice = d[3...]
        XCTAssertEqual(slice.startIndex, 3)
        XCTAssertEqual(slice.beUInt32(at: 0), 0x11223344)
        XCTAssertEqual(slice.beUInt16(at: 4), 0x5566)
    }

    // MARK: framing

    func testFrameLayout() {
        let f = StreamMessage.frame(type: .clipboard, payload: Data([1, 2, 3]))
        XCTAssertEqual([UInt8](f), [0x30, 0, 0, 0, 3, 1, 2, 3])
        XCTAssertEqual([UInt8](StreamMessage.frame(type: .keyframeRequest)), [0x11, 0, 0, 0, 0])
        XCTAssertEqual([UInt8](StreamMessage.frame(type: .ping)), [0x07, 0, 0, 0, 0])
    }

    func testHelloVariants() {
        let legacy = parse(StreamMessage.hello(requestedCodec: .h264)).messages
        XCTAssertEqual(legacy.count, 1)
        XCTAssertEqual(legacy[0].0, .hello)
        XCTAssertEqual([UInt8](legacy[0].1), [streamProtocolVersion, StreamCodec.h264.rawValue])

        let sized = parse(StreamMessage.hello(requestedCodec: .hevc,
                                              displayInfo: (2560, 1440, false))).messages[0].1
        XCTAssertEqual(sized.count, 11)
        XCTAssertEqual(sized.beUInt32(at: 2), 2560)
        XCTAssertEqual(sized.beUInt32(at: 6), 1440)
        XCTAssertEqual(sized[sized.startIndex + 10], 0)

        let dual = parse(StreamMessage.hello(requestedCodec: .hevc,
                                             displayInfo: (2732, 2048, true),
                                             secondSize: (1920, 1080))).messages[0].1
        XCTAssertEqual(dual.count, 19)
        XCTAssertEqual(dual[dual.startIndex + 10], 1)
        XCTAssertEqual(dual.beUInt32(at: 11), 1920)
        XCTAssertEqual(dual.beUInt32(at: 15), 1080)

        // A second-display size is only sent when the flag is set.
        let ignored = parse(StreamMessage.hello(requestedCodec: .hevc,
                                                displayInfo: (800, 600, false),
                                                secondSize: (1920, 1080))).messages[0].1
        XCTAssertEqual(ignored.count, 11)
    }

    func testInputMessagesRoundTrip() {
        let move = parse(StreamMessage.mouseMove(x: 0.25, y: 0.75)).messages[0]
        XCTAssertEqual(move.0, .mouseMove)
        XCTAssertEqual(move.1.beFloat32(at: 0), 0.25)
        XCTAssertEqual(move.1.beFloat32(at: 4), 0.75)

        let button = parse(StreamMessage.mouseButton(button: 2, down: true, x: 1, y: 0)).messages[0]
        XCTAssertEqual(button.0, .mouseButton)
        XCTAssertEqual(button.1.count, 10)
        XCTAssertEqual(button.1[button.1.startIndex], 2)
        XCTAssertEqual(button.1[button.1.startIndex + 1], 1)
        XCTAssertEqual(button.1.beFloat32(at: 2), 1)

        let key = parse(StreamMessage.key(macKeyCode: 0x24, down: false, flags: 0x10_0000)).messages[0]
        XCTAssertEqual(key.0, .key)
        XCTAssertEqual(key.1.count, 11)
        XCTAssertEqual(key.1.beUInt16(at: 0), 0x24)
        XCTAssertEqual(key.1[key.1.startIndex + 2], 0)
        XCTAssertEqual(key.1.beUInt64(at: 3), 0x10_0000)

        let scroll = parse(StreamMessage.scroll(dx: -3, dy: 12.5)).messages[0]
        XCTAssertEqual(scroll.0, .scroll)
        XCTAssertEqual(scroll.1.beFloat32(at: 0), -3)
        XCTAssertEqual(scroll.1.beFloat32(at: 4), 12.5)
    }

    func testHostMessagesRoundTrip() {
        let ack = parse(StreamMessage.helloAck(codec: .hevc, width: 5120, height: 1440,
                                               hardwareEncoder: true)).messages[0]
        XCTAssertEqual(ack.0, .helloAck)
        XCTAssertEqual(ack.1.count, 11)
        XCTAssertEqual(ack.1[ack.1.startIndex + 1], StreamCodec.hevc.rawValue)
        XCTAssertEqual(ack.1.beUInt32(at: 2), 5120)
        XCTAssertEqual(ack.1.beUInt32(at: 6), 1440)
        XCTAssertEqual(ack.1[ack.1.startIndex + 10], 1)

        let nal = Data([0, 0, 0, 1, 0x65])
        let video = parse(StreamMessage.videoFrame(keyframe: true, ptsMicros: 1_234_567, nalData: nal)).messages[0]
        XCTAssertEqual(video.0, .videoFrame)
        XCTAssertEqual(video.1[video.1.startIndex], 1)
        XCTAssertEqual(video.1.beUInt64(at: 1), 1_234_567)
        XCTAssertEqual(video.1.subdata(in: video.1.startIndex + 9 ..< video.1.endIndex), nal)

        let status = parse(StreamMessage.streamStatus(bitrateKbps: 20_000)).messages[0]
        XCTAssertEqual(status.0, .streamStatus)
        XCTAssertEqual(status.1.beUInt16(at: 0), 20_000)

        XCTAssertEqual([UInt8](parse(StreamMessage.hostLockState(true)).messages[0].1), [1])
        XCTAssertEqual([UInt8](parse(StreamMessage.hostLockState(false)).messages[0].1), [0])

        let cursor = parse(StreamMessage.cursorPos(x: 0.5, y: 0.125)).messages[0]
        XCTAssertEqual(cursor.0, .cursorPos)
        XCTAssertEqual(cursor.1.beFloat32(at: 4), 0.125)

        let clip = parse(StreamMessage.clipboard(text: "héllo ✓")).messages[0]
        XCTAssertEqual(clip.0, .clipboard)
        XCTAssertEqual(String(data: clip.1, encoding: .utf8), "héllo ✓")
    }

    // MARK: parser

    private var threeMessages: Data {
        var d = StreamMessage.mouseMove(x: 0.1, y: 0.2)
        d.append(StreamMessage.frame(type: .keyframeRequest))
        d.append(StreamMessage.clipboard(text: "abc"))
        return d
    }

    func testParserHandlesSeveralMessagesInOneFeed() {
        let r = parse(threeMessages)
        XCTAssertFalse(r.corrupt)
        XCTAssertEqual(r.messages.map { $0.0 }, [.mouseMove, .keyframeRequest, .clipboard])
        XCTAssertEqual(r.messages[1].1.count, 0)
        XCTAssertEqual(String(data: r.messages[2].1, encoding: .utf8), "abc")
    }

    /// TCP hands the stream over in arbitrary pieces; every split point must
    /// produce the same messages.
    func testParserHandlesAnyFragmentation() {
        let whole = parse(threeMessages).messages
        for chunk in [1, 2, 3, 4, 5, 6, 7, 11] {
            let r = parse(threeMessages, chunk: chunk)
            XCTAssertFalse(r.corrupt, "chunk \(chunk)")
            XCTAssertEqual(r.messages.map { $0.0 }, whole.map { $0.0 }, "chunk \(chunk)")
            XCTAssertEqual(r.messages.map { $0.1 }, whole.map { $0.1 }, "chunk \(chunk)")
        }
    }

    func testParserWaitsForIncompleteMessage() {
        let msg = StreamMessage.clipboard(text: "partial")
        let parser = StreamMessageParser()
        var count = 0
        parser.onMessage = { _, _ in count += 1 }
        parser.feed(msg.prefix(msg.count - 1))
        XCTAssertEqual(count, 0)
        parser.feed(msg.suffix(1))
        XCTAssertEqual(count, 1)
    }

    /// Unknown types are skipped by length so newer peers can add messages.
    func testParserSkipsUnknownTypes() {
        var d = Data([0x7F]); d.appendBE(UInt32(4)); d.append(Data([9, 9, 9, 9]))
        d.append(StreamMessage.scroll(dx: 1, dy: 2))
        let r = parse(d)
        XCTAssertFalse(r.corrupt)
        XCTAssertEqual(r.messages.map { $0.0 }, [.scroll])
    }

    func testParserRejectsOversizedLengthAndStaysCorrupt() {
        var d = Data([StreamMessageType.clipboard.rawValue])
        d.appendBE(UInt32((64 << 20) + 1))
        let parser = StreamMessageParser()
        var count = 0
        parser.onMessage = { _, _ in count += 1 }
        parser.feed(d)
        XCTAssertTrue(parser.corrupt)
        parser.feed(StreamMessage.scroll(dx: 1, dy: 2))
        XCTAssertTrue(parser.corrupt)
        XCTAssertEqual(count, 0)
    }

    func testParserAcceptsLargestAllowedLengthHeader() {
        var d = Data([StreamMessageType.clipboard.rawValue])
        d.appendBE(UInt32(64 << 20))
        XCTAssertFalse(parse(d).corrupt)
    }
}
