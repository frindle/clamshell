import XCTest
import Foundation
@testable import DeskProtocol

final class RoundTripTests: XCTestCase {
    static let menu: [MenuItem] = [
        MenuItem(itemId: 1, title: "File", children: [
            MenuItem(itemId: 2, title: "New Window", keyCode: 45, modifiers: 0x100000),
            MenuItem(itemId: 3, title: "", separator: true),
            MenuItem(itemId: 4, title: "Close", enabled: false, checked: true, keyCode: 13, modifiers: 0x100000),
        ]),
        MenuItem(itemId: 5, title: "Edit"),
    ]

    static let samples: [DeskMessage] = [
        .windowListRequest,
        .windowListResponse([WindowInfo(windowId: 9, title: "Inbox", appName: "Mail", widthPx: 2880, heightPx: 1800),
                             WindowInfo(windowId: 10, title: "", appName: "Notes", widthPx: 1, heightPx: 1)]),
        .windowListResponse([]),
        .handoffBegin(windowId: 3, crossX: 0.25, crossY: 0.5, title: "Doc", appName: "Pages", widthPx: 800, heightPx: 600),
        .handoffAccept(windowId: 3),
        .handoffReject(windowId: 3, reason: "busy"),
        .windowStreamStart(windowId: 3),
        .windowStreamFrame(windowId: 3, flags: 1, ptsMicros: 123_456_789, nal: [0, 0, 0, 2, 0x65, 0x88]),
        .windowInputMouseMove(windowId: 3, x: 0.5, y: 1.0),
        .windowInputMouseButton(windowId: 3, button: 1, down: true, x: 0.1, y: 0.2),
        .windowInputKey(windowId: 3, macKeyCode: 36, down: false, cgEventFlags: 0x0010_0000_0000_0102),
        .windowInputScroll(windowId: 3, dx: -4.5, dy: 12),
        .handoffReturn(windowId: 3),
        .windowClosed(windowId: 3),
        .appLaunch(requestId: 77, bundleId: "org.mozilla.firefox", activate: true, targets: ["https://example.com/a", "/Volumes/shared/x.pdf"]),
        .appLaunch(requestId: 78, bundleId: "com.tinyspeck.slackmacgap", activate: false, targets: []),
        .appLaunchResult(requestId: 77, status: 0, appId: 4),
        .appListRequest,
        .appList([AppInfo(appId: 4, bundleId: "org.mozilla.firefox", name: "Firefox", pid: 4242, windowCount: 3, residentMB: 6714, running: true),
                  AppInfo(appId: 5, bundleId: "com.hnc.Discord", name: "Discord", pid: -1, windowCount: 0, residentMB: 0, running: false)]),
        .windowAdded(windowId: 11, appId: 4, kind: .sheet, parentId: 10, title: "Save as", geometry: Geometry(x: 10, y: 20, width: 640, height: 480, scale: 2)),
        .windowMoved(windowId: 11, x: -30.5, y: 99),
        .windowResized(windowId: 11, width: 700, height: 500, scale: 2),
        .windowTitle(windowId: 11, title: "Untitled \u{2013} caf\u{00E9} \u{1F600}"),
        .windowResizeRequest(windowId: 11, width: 900, height: 700),
        .childWindow(windowId: 12, parentId: 11, offsetX: 4, offsetY: -8, kind: .popover),
        .menuTree(appId: 4, generation: 2, items: menu),
        .menuTree(appId: 4, generation: 3, items: []),
        .menuInvoke(appId: 4, generation: 2, itemId: 2),
        .cursorShape(windowId: 11, shape: .iBeam, hotspotX: 0, hotspotY: 0, png: []),
        .cursorShape(windowId: 11, shape: .custom, hotspotX: 8, hotspotY: 9, png: [0x89, 0x50, 0x4E, 0x47]),
        .pasteboardOffer(generation: 5, entries: [PasteboardEntry(uti: "public.utf8-plain-text", size: 12), PasteboardEntry(uti: "public.png", size: 1 << 33)]),
        .pasteboardFetch(generation: 5, uti: "public.png"),
        .pasteboardData(generation: 5, uti: "public.png", offset: 0, total: 3, data: [1, 2, 3]),
        .filePush(requestId: 1, windowId: 11, dropX: 0.3, dropY: 0.7, name: "report.pdf"),
        .filePush(requestId: 2, windowId: 0, dropX: 0, dropY: 0, name: "photo \u{00E9}.jpg"),
        .filePull(requestId: 3, fileId: 42),
        .filePromise([FilePromiseEntry(fileId: 42, name: "out.txt", size: 1 << 34), FilePromiseEntry(fileId: 43, name: "b", size: 0)]),
        .filePromise([]),
        .audioFrame(appId: 4, ptsMicros: 1_000_000, aac: [0xDE, 0xAD]),
        .badge(appId: 5, text: "12"),
        .badge(appId: 5, text: ""),
        .notify(appId: 5, notificationId: "n-1", title: "Penn", subtitle: "#general", body: "hello", sound: true),
        .unknown(type: 0xE0, payload: [1, 2, 3]),
    ]

    func testEveryMessageRoundTripsThroughAFrame() throws {
        for m in Self.samples {
            var p = FrameParser()
            let frames = try p.feed(try m.encodeFrame())
            XCTAssertEqual(frames.count, 1, "\(m)")
            XCTAssertEqual(try DeskMessage.decode(frames[0]), m, "\(m)")
        }
    }

    func testEveryNamedTypeHasASample() {
        let covered = Set(Self.samples.map { $0.typeByte })
        for raw in UInt8(0x40)...UInt8(0x85) {
            if let t = DeskType(rawValue: raw) { XCTAssertTrue(covered.contains(t.rawValue), "no sample for \(t)") }
        }
    }

    func testStreamedOneByteAtATimeAndBackToBack() throws {
        var wire: [UInt8] = []
        for m in Self.samples { wire += try m.encodeFrame() }
        var p = FrameParser()
        var got: [DeskMessage] = []
        for b in wire { for f in try p.feed([b]) { got.append(try DeskMessage.decode(f)) } }
        XCTAssertEqual(got, Self.samples)
        // And all at once.
        var q = FrameParser()
        XCTAssertEqual(try q.feed(wire).map { try DeskMessage.decode($0) }, Self.samples)
    }

    func testUnknownTypeIsPreservedNotRejected() throws {
        XCTAssertEqual(try DeskMessage.decode(type: 0xE1, payload: [9]), .unknown(type: 0xE1, payload: [9]))
    }

    func testTrailingBytesAreIgnoredOnFixedMessages() throws {
        XCTAssertEqual(try DeskMessage.decode(type: 0x43, payload: [0, 0, 0, 7, 0xFF, 0xFF]), .handoffAccept(windowId: 7))
    }
}

// MARK: collisions with the real v1 definitions

enum Repo {
    static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    /// Reads a repo file. In CI (DESK_REQUIRE_REPO=1) a missing file fails; elsewhere the test is skipped.
    static func read(_ rel: String) throws -> String {
        let url = root.appendingPathComponent(rel)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            if ProcessInfo.processInfo.environment["DESK_REQUIRE_REPO"] == "1" { XCTFail("missing \(rel)") }
            throw XCTSkip("\(rel) not available")
        }
        return text
    }
    static func matches(_ pattern: String, in text: String) -> [[String]] {
        let re = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { m in
            (1..<m.numberOfRanges).map { String(text[Range(m.range(at: $0), in: text)!]) }
        }
    }
}

final class CollisionTests: XCTestCase {
    func v1Types() throws -> [String: UInt8] {
        let text = try Repo.read("Sources/Clamshell/Streaming/StreamProtocol.swift")
        var out: [String: UInt8] = [:]
        for m in Repo.matches(#"^\s*case (\w+)\s*=\s*0x([0-9A-Fa-f]{2})\b"#, in: text) { out[m[0]] = UInt8(m[1], radix: 16)! }
        return out
    }

    func testNoDeskTypeCollidesWithARealV1Type() throws {
        let v1 = try v1Types()
        XCTAssertGreaterThanOrEqual(v1.count, 35, "parsed the v1 enum")
        XCTAssertEqual(v1["restartRequest"], 0x60, "parser sanity: known v1 value")
        let byValue = Dictionary(grouping: v1.keys, by: { v1[$0]! })
        for raw in UInt8(0)...UInt8(255) {
            if let t = DeskType(rawValue: raw) { XCTAssertNil(byValue[raw], "\(t) = \(raw) is already v1 \(byValue[raw] ?? [])") }
        }
    }

    func testDeskTypesAreUniqueAndInTheirRanges() {
        let all = (0...255).compactMap { DeskType(rawValue: UInt8($0)) }
        let v2 = all.filter { $0.rawValue < 0x60 }, v3 = all.filter { $0.rawValue >= 0x60 }
        XCTAssertTrue(v2.allSatisfy { (0x40...0x4C).contains($0.rawValue) })
        XCTAssertTrue(v3.allSatisfy { (0x70...0x85).contains($0.rawValue) })
        XCTAssertEqual(all.count, 13 + 22)
    }

    func testAppHostBitIsNotAV1CapabilityBit() throws {
        let text = try Repo.read("Sources/Clamshell/Streaming/StreamProtocol.swift")
        let bits = Repo.matches(#"static let \w+\s*=\s*StreamCapabilities\(rawValue: 1 << (\d+)\)"#, in: text).map { UInt32($0[0])! }
        XCTAssertGreaterThanOrEqual(bits.count, 9)
        for b in bits { XCTAssertNotEqual(DeskCapability.appHost, 1 << b, "appHost collides with v1 bit \(b)") }
    }

    func testProtocolDocCapabilityTableHasNoDuplicateBitsAndListsAppHostAt9() throws {
        let text = try Repo.read("PROTOCOL.md")
        let rows = Repo.matches(#"^\| (\d+) \| `(\w+)` \|"#, in: text)
        XCTAssertGreaterThanOrEqual(rows.count, 10)
        XCTAssertEqual(Set(rows.map { $0[0] }).count, rows.count, "duplicate capability bit in PROTOCOL.md")
        XCTAssertEqual(rows.first { $0[1] == "appHost" }?[0], "9")
        XCTAssertEqual(DeskCapability.appHost, 1 << 9)
    }

    func testDocTypeTableMatchesCode() throws {
        let text = try Repo.read("PROTOCOL.md")
        guard let start = text.range(of: "### New in v3") else { return XCTFail("no v3 table") }
        let rows = Repo.matches(#"^\| 0x([0-9A-F]{2}) \| (\w+)"#, in: String(text[start.lowerBound...]))
        let docTypes = rows.map { UInt8($0[0], radix: 16)! }
        XCTAssertEqual(Set(docTypes).count, docTypes.count, "duplicate type in v3 doc table")
        let codeV3 = Set((0x70...0x85).compactMap { DeskType(rawValue: UInt8($0))?.rawValue })
        XCTAssertEqual(Set(docTypes), codeV3)
    }
}

// MARK: file names

final class FileNameTests: XCTestCase {
    func testRule() {
        for ok in ["a", "report.pdf", "photo \u{00E9}.jpg", "a..b", "COM", "COM10", "console.txt", "\u{65E5}\u{672C}\u{8A9E}.txt", String(repeating: "n", count: 255)] { XCTAssertTrue(FileName.isSafe(ok), ok) }
        for bad in ["", ".", "..", ".hidden", "../x", "a/b", "/abs", "a\\b", "C:\\x", "a\u{0}b", "a\nb", "a\u{7F}", String(repeating: "n", count: 256),
                    "a:b", "name.", "name ", " name", "a\u{202E}fdp.exe", "a\u{200B}b", "a\u{85}b", "a\u{FEFF}", "a\u{FF0E}b", "a|b", "a?b", "CON", "nul.txt", "COM1", "lpt9.log"] {
            XCTAssertFalse(FileName.isSafe(bad), bad.debugDescription)
        }
    }

    func testEncoderAndDecoderRefuseUnsafeNames() throws {
        for bad in ["../etc/passwd", "/etc/passwd", "a\\b", ".ssh", "", "x\u{0}y"] {
            XCTAssertThrowsError(try DeskMessage.filePush(requestId: 1, windowId: 0, dropX: 0, dropY: 0, name: bad).encodeFrame(), bad.debugDescription)
            XCTAssertThrowsError(try DeskMessage.filePromise([FilePromiseEntry(fileId: 1, name: bad, size: 1)]).encodeFrame())
            // A hostile peer writes the bytes itself.
            let push = DeskMessage.filePush(requestId: 1, windowId: 0, dropX: 0, dropY: 0, name: bad).encodePayloadSkippingChecks()
            XCTAssertThrowsError(try DeskMessage.decode(type: DeskType.filePush.rawValue, payload: push), bad.debugDescription)
            let promise = DeskMessage.filePromise([FilePromiseEntry(fileId: 1, name: bad, size: 1)]).encodePayloadSkippingChecks()
            XCTAssertThrowsError(try DeskMessage.decode(type: DeskType.filePromise.rawValue, payload: promise))
        }
    }
}

final class HostileInputTests: XCTestCase {
    func testTruncationAlwaysThrowsNeverTraps() {
        for m in RoundTripTests.samples {
            let payload = try! m.encodePayload()
            guard !payload.isEmpty else { continue }
            // Messages whose tail is free-form bytes legitimately decode when cut inside the tail.
            for cut in 0..<payload.count {
                _ = try? DeskMessage.decode(type: m.typeByte, payload: Array(payload[0..<cut]))
            }
        }
        XCTAssertThrowsError(try DeskMessage.decode(type: DeskType.handoffAccept.rawValue, payload: [0, 0, 1]))
        XCTAssertThrowsError(try DeskMessage.decode(type: DeskType.windowTitle.rawValue, payload: [0, 0, 0, 1, 0, 9, 0x41]))
    }

    func testNonFiniteFloatRejected() {
        let nan: [UInt8] = [0, 0, 0, 1, 0x7F, 0xC0, 0, 0, 0, 0, 0, 0]
        XCTAssertThrowsError(try DeskMessage.decode(type: DeskType.windowInputMouseMove.rawValue, payload: nan))
    }

    func testOversizeFrameLengthIsFatal() throws {
        var p = FrameParser()
        XCTAssertThrowsError(try p.feed([0x10, 0xFF, 0xFF, 0xFF, 0xFF])) { XCTAssertEqual($0 as? DecodeError, .frameTooLarge(Int(UInt32.max))) }
        XCTAssertLessThan(Framing.maxPayload, 4_194_304, "fits the v1 SECURE limit")
        // No resynchronising: the connection must be closed, so every later feed fails too.
        XCTAssertThrowsError(try p.feed(try DeskMessage.windowListRequest.encodeFrame()))
        XCTAssertThrowsError(try p.feed([]))
        // The limit itself is accepted as a length (the frame is simply incomplete).
        var q = FrameParser()
        XCTAssertEqual(try q.feed([0x10, 0x00, 0x3D, 0x09, 0x00]).count, 0) // 4,000,000
        var r = FrameParser()
        XCTAssertThrowsError(try r.feed([0x10, 0x00, 0x3D, 0x09, 0x01]))
    }

    func testEncoderRefusesOversizeFrame() throws {
        let big = [UInt8](repeating: 0, count: Framing.maxPayload + 1)
        XCTAssertThrowsError(try Framing.encode(type: 0x46, payload: big)) { XCTAssertEqual($0 as? EncodeError, .frameTooLarge(Framing.maxPayload + 1)) }
        XCTAssertThrowsError(try DeskMessage.audioFrame(appId: 1, ptsMicros: 2, aac: big).encodeFrame())
        XCTAssertEqual(try Framing.encode(type: 0x46, payload: [UInt8](repeating: 0, count: Framing.maxPayload)).count, Framing.maxPayload + 5)
    }

    func testListCountLargerThanLimitRefused() {
        XCTAssertThrowsError(try DeskMessage.decode(type: DeskType.appList.rawValue, payload: [0xFF, 0xFF])) { e in
            XCTAssertEqual(e as? DecodeError, .tooManyItems)
        }
    }

    func testMenuDepthLimit() throws {
        var item = MenuItem(itemId: 0, title: "leaf")
        for i in 1..<Limits.maxMenuDepth { item = MenuItem(itemId: UInt32(i), title: "n", children: [item]) }
        let ok = DeskMessage.menuTree(appId: 1, generation: 1, items: [item])
        XCTAssertEqual(try DeskMessage.decode(type: ok.typeByte, payload: try ok.encodePayload()), ok)
        // One level deeper: the encoder refuses, so the receiver never sees an unreadable tree.
        let deeper = DeskMessage.menuTree(appId: 1, generation: 1, items: [MenuItem(itemId: 99, title: "x", children: [item])])
        XCTAssertThrowsError(try deeper.encodePayload())
        // A hand-built payload that is too deep is refused.
        var w = ByteWriter(); w.u32(1); w.u32(1)
        for _ in 0...Limits.maxMenuDepth { w.u16(1); w.u32(0); try! w.str16(""); w.u8(1); w.u16(0xFFFF); w.u32(0) }
        w.u16(0)
        XCTAssertThrowsError(try DeskMessage.decode(type: DeskType.menuTree.rawValue, payload: w.bytes)) { e in
            XCTAssertEqual(e as? DecodeError, .treeTooDeep)
        }
    }

    func testMenuNodeBudget() {
        var w = ByteWriter(); w.u32(1); w.u32(1); w.u16(UInt16(Limits.maxMenuNodes + 1))
        XCTAssertThrowsError(try DeskMessage.decode(type: DeskType.menuTree.rawValue, payload: w.bytes)) { e in
            XCTAssertEqual(e as? DecodeError, .tooManyItems)
        }
    }

    func testLongStringsAndListsAreRefusedNotCut() throws {
        let long = String(repeating: "\u{00E9}", count: 200) // 400 bytes, over the 255 limit of str8
        XCTAssertThrowsError(try DeskMessage.handoffReject(windowId: 1, reason: long).encodePayload()) { XCTAssertEqual($0 as? EncodeError, .stringTooLong(400)) }
        XCTAssertThrowsError(try DeskMessage.windowTitle(windowId: 1, title: String(repeating: "a", count: 65536)).encodePayload())
        XCTAssertNoThrow(try DeskMessage.windowTitle(windowId: 1, title: String(repeating: "a", count: 65535)).encodePayload())
        let many = (0...Limits.maxListEntries).map { AppInfo(appId: UInt32($0), bundleId: "a", name: "b", pid: 1, windowCount: 0, residentMB: 0, running: true) }
        XCTAssertThrowsError(try DeskMessage.appList(many).encodePayload())
        let png = [UInt8](repeating: 0, count: Limits.maxCursorPNG + 1)
        XCTAssertThrowsError(try DeskMessage.cursorShape(windowId: 1, shape: .custom, hotspotX: 0, hotspotY: 0, png: png).encodePayload())
        let entries = (0..<256).map { PasteboardEntry(uti: "u\($0)", size: 1) }
        XCTAssertThrowsError(try DeskMessage.pasteboardOffer(generation: 1, entries: entries).encodePayload())
    }

    func testBadEnumValuesRejectedOrDegraded() throws {
        var w = ByteWriter(); w.u32(1); w.u8(42)
        XCTAssertThrowsError(try DeskMessage.decode(type: DeskType.cursorShape.rawValue, payload: w.bytes))
        // Unknown window kind degrades to .other rather than failing.
        var a = ByteWriter(); a.u32(1); a.u32(1); a.u8(77); a.u32(0); try! a.str16("t")
        for _ in 0..<5 { a.f32(1) }
        guard case .windowAdded(_, _, let kind, _, _, _) = try DeskMessage.decode(type: DeskType.windowAdded.rawValue, payload: a.bytes) else { return XCTFail() }
        XCTAssertEqual(kind, .other)
    }

    func testByteReaderWriterPrimitives() throws {
        var w = ByteWriter()
        w.u16(0xBEEF); w.u32(0xDEADBEEF); w.u64(0x0102030405060708)
        var r = ByteReader(w.bytes)
        XCTAssertEqual(try r.u16(), 0xBEEF)
        XCTAssertEqual(try r.u32(), 0xDEADBEEF)
        XCTAssertEqual(try r.u64(), 0x0102030405060708)
        XCTAssertEqual(r.remaining, 0)
        XCTAssertThrowsError(try r.u8())
    }
}

final class RangeAndChunkTests: XCTestCase {
    func testOutOfRangeValuesAreRefusedByEncoderAndDecoder() throws {
        let bad: [DeskMessage] = [
            .windowAdded(windowId: 1, appId: 1, kind: .main, parentId: 0, title: "t", geometry: Geometry(x: 0, y: 0, width: 1e30, height: 10, scale: 2)),
            .windowAdded(windowId: 1, appId: 1, kind: .main, parentId: 0, title: "t", geometry: Geometry(x: 0, y: 0, width: 10, height: 10, scale: 0)),
            .windowAdded(windowId: 1, appId: 1, kind: .main, parentId: 0, title: "t", geometry: Geometry(x: 0, y: 0, width: -1, height: 10, scale: 2)),
            .windowResized(windowId: 1, width: 10, height: 10, scale: 1000),
            .windowResizeRequest(windowId: 1, width: 1e9, height: 10),
            .windowMoved(windowId: 1, x: 5e9, y: 0),
            .windowInputMouseMove(windowId: 1, x: 1.5, y: 0.5),
            .windowInputMouseButton(windowId: 1, button: 0, down: true, x: -0.1, y: 0.5),
            .windowInputScroll(windowId: 1, dx: 1e12, dy: 0),
            .windowListResponse([WindowInfo(windowId: 1, title: "", appName: "", widthPx: 70000, heightPx: 10)]),
            .handoffBegin(windowId: 1, crossX: 0, crossY: 0, title: "", appName: "", widthPx: 10, heightPx: 4_000_000_000),
        ]
        for m in bad {
            XCTAssertThrowsError(try m.encodePayload(), "\(m)")
            // A peer builds the bytes itself, skipping the encoder check.
            let raw = m.encodePayloadSkippingChecks()
            XCTAssertThrowsError(try DeskMessage.decode(type: m.typeByte, payload: raw), "\(m)")
        }
        let ok = DeskMessage.windowAdded(windowId: 1, appId: 1, kind: .main, parentId: 0, title: "t", geometry: Geometry(x: -50, y: 20, width: 800, height: 600, scale: 2))
        XCTAssertEqual(try DeskMessage.decode(type: ok.typeByte, payload: try ok.encodePayload()), ok)
    }

    func testClipboardTravelsInChunksAndReassembles() throws {
        let data = (0..<300_000).map { UInt8($0 & 0xFF) }
        let chunks = try PasteboardChunker.chunks(generation: 4, uti: "public.png", data: data)
        XCTAssertEqual(chunks.count, 5)
        for c in chunks { XCTAssertLessThan(try c.encodeFrame().count, 70_000) }
        var a = PasteboardAssembler(generation: 4, uti: "public.png", expectedSize: UInt64(data.count))
        var result: [UInt8]?
        for c in chunks { result = try a.add(try DeskMessage.decode(type: c.typeByte, payload: try c.encodePayload())) }
        XCTAssertEqual(result, data)
        // Out of order, wrong size, wrong item, too large.
        var b = PasteboardAssembler(generation: 4, uti: "public.png", expectedSize: UInt64(data.count))
        XCTAssertThrowsError(try b.add(chunks[1]))
        var c = PasteboardAssembler(generation: 5, uti: "public.png", expectedSize: UInt64(data.count))
        XCTAssertThrowsError(try c.add(chunks[0]))
        var d = PasteboardAssembler(generation: 4, uti: "public.png", expectedSize: 10)
        XCTAssertThrowsError(try d.add(chunks[0]))
        let oversize = DeskMessage.pasteboardData(generation: 1, uti: "u", offset: 0, total: 5, data: [UInt8](repeating: 0, count: Limits.maxPasteboardChunk + 1))
        XCTAssertThrowsError(try oversize.encodePayload())
        XCTAssertThrowsError(try DeskMessage.pasteboardData(generation: 1, uti: "u", offset: 4, total: 5, data: [1, 2]).encodePayload())
        XCTAssertEqual(try PasteboardChunker.chunks(generation: 1, uti: "u", data: []).count, 1)
    }

    func testWindowRegistryRefusesReuseAndUnknownIds() {
        var r = WindowRegistry()
        XCTAssertFalse(r.accepts(7))
        XCTAssertTrue(r.announce(7))
        XCTAssertTrue(r.accepts(7))
        XCTAssertFalse(r.announce(7), "same id twice")
        XCTAssertFalse(r.announce(0))
        r.close(7)
        XCTAssertFalse(r.accepts(7))
        XCTAssertFalse(r.announce(7), "ids are not reused after close")
        r.listed([9, 10]); XCTAssertTrue(r.accepts(9)); XCTAssertFalse(r.accepts(11))
    }

    func testParserKeepsOrderAcrossManySmallFeeds() throws {
        var p = FrameParser()
        var bytes: [UInt8] = []
        for i in 0..<2000 { bytes += try DeskMessage.windowClosed(windowId: UInt32(i)).encodeFrame() }
        var got: [UInt32] = []
        var i = 0
        while i < bytes.count {
            let n = min(7, bytes.count - i)
            for f in try p.feed(Array(bytes[i..<(i + n)])) { if case .windowClosed(let id) = try DeskMessage.decode(f) { got.append(id) } }
            i += n
        }
        XCTAssertEqual(got, (0..<2000).map { UInt32($0) })
    }
}

extension DeskMessage {
    /// Test helper: the payload without the range check, standing in for a hostile peer that writes its own bytes.
    func encodePayloadSkippingChecks() -> [UInt8] { (try? encodePayloadRaw()) ?? [] }
}
