import XCTest
@testable import Clamshell

final class ProbeMathTests: XCTestCase {
    private func frame(_ w: Int, _ h: Int, _ v: UInt8) -> [UInt8] {
        var b = [UInt8](repeating: v, count: w * h * 4)
        for i in stride(from: 3, to: b.count, by: 4) { b[i] = 255 }
        return b
    }

    func testFlatFrameHasZeroStddev() throws {
        let st = try XCTUnwrap(ProbeMath.lumaStats(rgba: frame(8, 8, 200), pixelCount: 64))
        XCTAssertEqual(st.mean, 200, accuracy: 0.01)
        XCTAssertEqual(st.stddev, 0, accuracy: 0.01)
    }

    func testHalfBlackHalfWhiteStddev() throws {
        var f = frame(4, 1, 0)
        for i in 2..<4 { for c in 0..<3 { f[i * 4 + c] = 255 } }
        let st = try XCTUnwrap(ProbeMath.lumaStats(rgba: f, pixelCount: 4))
        XCTAssertEqual(st.mean, 127.5, accuracy: 0.01)
        XCTAssertEqual(st.stddev, 127.5, accuracy: 0.01)
    }

    func testLumaStatsRejectsShortBuffer() {
        XCTAssertNil(ProbeMath.lumaStats(rgba: [0, 0, 0, 255], pixelCount: 2))
        XCTAssertNil(ProbeMath.lumaStats(rgba: [], pixelCount: 0))
    }

    func testGridDiffCountsChangedCellsOnly() {
        let w = 64, h = 36
        let a = frame(w, h, 10)
        XCTAssertEqual(ProbeMath.gridDiff(a, a, width: w, height: h), 0)
        var b = a
        // One bright pixel: one cell.
        for c in 0..<3 { b[(5 * w + 5) * 4 + c] = 250 }
        XCTAssertEqual(ProbeMath.gridDiff(a, b, width: w, height: h), 1)
        // A second pixel in a different cell: two cells.
        for c in 0..<3 { b[(30 * w + 60) * 4 + c] = 250 }
        XCTAssertEqual(ProbeMath.gridDiff(a, b, width: w, height: h), 2)
    }

    func testGridDiffIgnoresSmallNoiseAndBadSizes() {
        let w = 32, h = 18
        let a = frame(w, h, 100)
        XCTAssertEqual(ProbeMath.gridDiff(a, frame(w, h, 105), width: w, height: h), 0)
        XCTAssertEqual(ProbeMath.gridDiff(a, frame(w, h, 200), width: w, height: h), 32 * 18)
        XCTAssertNil(ProbeMath.gridDiff(a, [0], width: w, height: h))
        XCTAssertNil(ProbeMath.gridDiff(a, a, width: 0, height: h))
    }

    func testParseTCCRows() {
        let out = "kTCCServiceScreenCapture|2\nkTCCServiceAccessibility|2\nkTCCServicePostEvent|0\n"
        XCTAssertEqual(ProbeMath.parseTCCRows(out), ["Accessibility=2", "PostEvent=0", "ScreenCapture=2"])
    }

    func testParseTCCRowsSkipsJunkAndReturnsNilWhenEmpty() {
        XCTAssertNil(ProbeMath.parseTCCRows(""))
        XCTAssertNil(ProbeMath.parseTCCRows("Error: unable to open database file\n"))
        XCTAssertEqual(ProbeMath.parseTCCRows("garbage\nkTCCServiceListenEvent|x\nkTCCServiceListenEvent|2\n"),
                       ["ListenEvent=2"])
    }

    func testSummaryLineFormat() {
        var s = ProbeMath.Summary()
        s.ts = "2026-01-01T00:00:00Z"
        s.label = "loginwindow"
        s.uid = "0"
        s.consoleUser = "loginwindow"
        s.locked = "false"
        s.captureOK = true
        s.lumaStddev = 31.256
        s.frameChanged = 4
        s.pointerMoved = true
        s.keyPosted = true
        s.keySeen = false
        s.screenRecording = false
        s.accessibility = true
        s.postEvent = true
        s.listenEvent = false
        s.tcc = "unreadable"
        XCTAssertEqual(ProbeMath.summaryLine(s),
            "2026-01-01T00:00:00Z loginwindow 0 loginwindow locked=false capture_ok=true luma_stddev=31.26 " +
            "frame_changed=4 pointer_moved=true key_seen=false sr=false ax=true post=true " +
            "key_posted=true listen=false tcc=unreadable")
    }

    func testSummaryLineWithMissingValues() {
        let line = ProbeMath.summaryLine(ProbeMath.Summary())
        XCTAssertTrue(line.contains("capture_ok=- luma_stddev=- frame_changed=- pointer_moved=- key_seen=-"))
        XCTAssertTrue(line.contains("sr=- ax=- post=-"))
    }
}
