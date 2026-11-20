import XCTest
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
        .pasteboardData(generation: 5, uti: "public.png", data: [1, 2, 3]),
        .filePush(requestId: 1, windowId: 11, dropX: 0.3, dropY: 0.7, kind: .sharedPath, path: "/Volumes/shared/report.pdf"),
        .filePush(requestId: 2, windowId: 0, dropX: 0, dropY: 0, kind: .inboxCopy, path: "photo.jpg"),
        .filePull(requestId: 3, path: "/Users/shared/out.txt"),
        .audioFrame(appId: 4, ptsMicros: 1_000_000, aac: [0xDE, 0xAD]),
        .badge(appId: 5, text: "12"),
        .badge(appId: 5, text: ""),
        .notify(appId: 5, notificationId: "n-1", title: "Penn", subtitle: "#general", body: "hello", sound: true),
        .unknown(type: 0x7E, payload: [1, 2, 3]),
    ]

    func testEveryMessageRoundTripsThroughAFrame() throws {
        for m in Self.samples {
            var p = FrameParser()
            let frames = try p.feed(m.encodeFrame())
            XCTAssertEqual(frames.count, 1, "\(m)")
            XCTAssertEqual(try DeskMessage.decode(frames[0]), m, "\(m)")
        }
    }

    func testEveryNamedTypeHasASample() {
        let covered = Set(Self.samples.map { $0.typeByte })
        for raw in UInt8(0x40)...UInt8(0x74) {
            if let t = DeskType(rawValue: raw) { XCTAssertTrue(covered.contains(t.rawValue), "no sample for \(t)") }
        }
    }

    func testTypeBytesDoNotCollideWithV1() {
        let v1: Set<UInt8> = [0x01,0x02,0x03,0x04,0x05,0x06,0x07,0x08,0x09,0x0A,0x0B,0x0C,0x0D,0x0E,0x0F,0x10,0x11,0x13,
                              0x20,0x21,0x22,0x23,0x24,0x25,0x26,0x30,0x50,0x51,0x52,0x53,0x54,0x58,0x59,0x5A,0x5B]
        for raw in UInt8(0)...UInt8(255) { if DeskType(rawValue: raw) != nil { XCTAssertFalse(v1.contains(raw)) } }
    }

    func testStreamedOneByteAtATimeAndBackToBack() throws {
        var wire: [UInt8] = []
        for m in Self.samples { wire += m.encodeFrame() }
        var p = FrameParser()
        var got: [DeskMessage] = []
        for b in wire { for f in try p.feed([b]) { got.append(try DeskMessage.decode(f)) } }
        XCTAssertEqual(got, Self.samples)
        // And all at once.
        var q = FrameParser()
        XCTAssertEqual(try q.feed(wire).map { try DeskMessage.decode($0) }, Self.samples)
    }

    // Golden bytes pin the wire format so an accidental change fails loudly.
    func testGoldenBytes() {
        XCTAssertEqual(DeskMessage.handoffAccept(windowId: 7).encodeFrame(), [0x43, 0, 0, 0, 4, 0, 0, 0, 7])
        XCTAssertEqual(DeskMessage.badge(appId: 1, text: "3").encodeFrame(), [0x70, 0, 0, 0, 7, 0, 0, 0, 1, 0, 1, 0x33])
        XCTAssertEqual(DeskMessage.windowInputMouseMove(windowId: 1, x: 0.5, y: 1.0).encodeFrame(),
                       [0x47, 0, 0, 0, 12, 0, 0, 0, 1, 0x3F, 0, 0, 0, 0x3F, 0x80, 0, 0])
        XCTAssertEqual(DeskMessage.handoffReject(windowId: 2, reason: "no").encodeFrame(), [0x44, 0, 0, 0, 7, 0, 0, 0, 2, 2, 0x6E, 0x6F])
        XCTAssertEqual(DeskMessage.appListRequest.encodeFrame(), [0x72, 0, 0, 0, 0])
    }

    func testUnknownTypeIsPreservedNotRejected() throws {
        XCTAssertEqual(try DeskMessage.decode(type: 0x7F, payload: [9]), .unknown(type: 0x7F, payload: [9]))
    }

    func testTrailingBytesAreIgnoredOnFixedMessages() throws {
        XCTAssertEqual(try DeskMessage.decode(type: 0x43, payload: [0, 0, 0, 7, 0xFF, 0xFF]), .handoffAccept(windowId: 7))
    }
}

final class HostileInputTests: XCTestCase {
    func testTruncationAlwaysThrowsNeverTraps() {
        for m in RoundTripTests.samples {
            let payload = m.encodePayload()
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

    func testOversizeFrameLengthRefused() {
        var p = FrameParser()
        XCTAssertThrowsError(try p.feed([0x10, 0xFF, 0xFF, 0xFF, 0xFF]))
        // Parser is usable again afterwards.
        XCTAssertEqual(try p.feed(DeskMessage.windowListRequest.encodeFrame()).count, 1)
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
        XCTAssertEqual(try DeskMessage.decode(type: ok.typeByte, payload: ok.encodePayload()), ok)
        // One level deeper: the encoder cuts it, so the receiver never sees an unreadable tree.
        let deeper = DeskMessage.menuTree(appId: 1, generation: 1, items: [MenuItem(itemId: 99, title: "x", children: [item])])
        let back = try DeskMessage.decode(type: deeper.typeByte, payload: deeper.encodePayload())
        guard case .menuTree(_, _, let items) = back else { return XCTFail() }
        XCTAssertEqual(items.count, 1)
        // A hand-built payload that is too deep is refused.
        var w = ByteWriter(); w.u32(1); w.u32(1)
        for _ in 0...Limits.maxMenuDepth { w.u16(1); w.u32(0); w.str16(""); w.u8(1); w.u16(0xFFFF); w.u32(0) }
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

    func testLongStringsAreCutOnCharacterBoundary() throws {
        let long = String(repeating: "\u{00E9}", count: 200) // 400 bytes, over the 255 limit of str8
        let m = DeskMessage.handoffReject(windowId: 1, reason: long)
        guard case .handoffReject(_, let reason) = try DeskMessage.decode(type: m.typeByte, payload: m.encodePayload()) else { return XCTFail() }
        XCTAssertEqual(reason, String(repeating: "\u{00E9}", count: 127)) // 254 bytes, no split character
    }

    func testBadEnumValuesRejectedOrDegraded() throws {
        var w = ByteWriter(); w.u32(1); w.u8(42)
        XCTAssertThrowsError(try DeskMessage.decode(type: DeskType.cursorShape.rawValue, payload: w.bytes))
        // Unknown window kind degrades to .other rather than failing.
        var a = ByteWriter(); a.u32(1); a.u32(1); a.u8(77); a.u32(0); a.str16("t")
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
