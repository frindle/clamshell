import XCTest
@testable import Clamshell

final class ClientDisplayRequestTests: XCTestCase {
    private func payload(_ w: UInt32, _ h: UInt32, flags: UInt8, extra: [UInt32] = []) -> Data {
        var d = Data()
        d.appendBE(w); d.appendBE(h); d.append(flags)
        for e in extra { d.appendBE(e) }
        return d
    }

    func testFlagsZeroIsHiDPIDefault() {
        let r = ClientDisplayRequest.parse(payload(2732, 2048, flags: 0), at: 0)
        XCTAssertEqual(r?.widthPx, 2732)
        XCTAssertEqual(r?.heightPx, 2048)
        XCTAssertEqual(r?.oneX, false)
        XCTAssertEqual(r?.secondDisplay, false)
        XCTAssertEqual(r?.userInfo["scale"], "2")
    }

    func testFlagBitOneMeansPlain1x() {
        let r = ClientDisplayRequest.parse(payload(1920, 1080, flags: 2), at: 0)
        XCTAssertEqual(r?.oneX, true)
        XCTAssertEqual(r?.secondDisplay, false)
        XCTAssertEqual(r?.userInfo["scale"], "1")
    }

    func testSecondDisplayBitAndSize() {
        let r = ClientDisplayRequest.parse(payload(1920, 1080, flags: 1, extra: [1280, 720]), at: 0)
        XCTAssertEqual(r?.secondDisplay, true)
        XCTAssertEqual(r?.secondWidthPx, 1280)
        XCTAssertEqual(r?.userInfo["widthB"], "1280")
        XCTAssertEqual(r?.userInfo["external"], "1")
    }

    func testClampsAboveMaximum() {
        let r = ClientDisplayRequest.parse(payload(10240, 5760, flags: 0), at: 0)
        XCTAssertEqual(r?.widthPx, 7680)
        XCTAssertEqual(r?.heightPx, 4320)
    }

    func testRejectsBelowMinimumAndShortPayload() {
        XCTAssertNil(ClientDisplayRequest.parse(payload(600, 400, flags: 0), at: 0))
        XCTAssertNil(ClientDisplayRequest.parse(Data([1, 2, 3]), at: 0))
        XCTAssertNil(ClientDisplayRequest.parse(payload(1920, 1080, flags: 0).dropLast(), at: 0))
    }

    func testHelloOffsetAndSliceWithNonZeroStartIndex() {
        var hello = Data([1, 2])
        hello.append(payload(2560, 1440, flags: 2))
        XCTAssertEqual(ClientDisplayRequest.parse(hello, at: 2)?.widthPx, 2560)
        let sliced = Data([0xFF] + hello).dropFirst()
        let r = ClientDisplayRequest.parse(sliced, at: 2)
        XCTAssertEqual(r?.heightPx, 1440)
        XCTAssertEqual(r?.oneX, true)
    }

    func testPresetMath() {
        let hi = ClientDisplayRequest.preset(name: "t", widthPx: 2733, heightPx: 2048, scale: "2")
        XCTAssertEqual(hi.pointsWide, 1366)
        XCTAssertEqual(hi.pixelsWide, 2732)
        XCTAssertEqual(hi.scale, 2)
        let one = ClientDisplayRequest.preset(name: "t", widthPx: 2560, heightPx: 1440, scale: "1")
        XCTAssertEqual(one.pointsWide, 2560)
        XCTAssertEqual(one.pixelsHigh, 1440)
        XCTAssertEqual(ClientDisplayRequest.preset(name: "t", widthPx: 1920, heightPx: 1080, scale: nil).scale, 2)
    }

    func testSessionResizeDecision() {
        XCTAssertEqual(SessionResize.decide(sessionWidthPx: 2732, sessionHeightPx: 2048,
                                            displayWidthPx: 2732, displayHeightPx: 2048), .keep)
        XCTAssertEqual(SessionResize.decide(sessionWidthPx: 2732, sessionHeightPx: 2048,
                                            displayWidthPx: 5120, displayHeightPx: 2880),
                       .rebuild(widthPx: 5120, heightPx: 2880))
        XCTAssertEqual(SessionResize.decide(sessionWidthPx: 2732, sessionHeightPx: 2048,
                                            displayWidthPx: nil, displayHeightPx: nil), .keep)
        XCTAssertEqual(SessionResize.decide(sessionWidthPx: 2732, sessionHeightPx: 2048,
                                            displayWidthPx: 0, displayHeightPx: 0), .keep)
    }
}
