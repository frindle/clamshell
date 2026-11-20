import XCTest
@testable import DeskProtocol

/// One hand-written frame per message, with distinct field values, so two fields of the same
/// width swapped in the encoder or decoder change the bytes and fail here.
final class GoldenTests: XCTestCase {

    static let golden: [(DeskMessage, String)] = [
        (.windowListRequest, "40 00000000"),
        (.windowListResponse([WindowInfo(windowId: 1, title: "A", appName: "B", widthPx: 3, heightPx: 4)]),
         "41 00000012 0001 00000001 01 41 01 42 00000003 00000004"),
        (.handoffBegin(windowId: 1, crossX: 0.25, crossY: 0.5, title: "T", appName: "P", widthPx: 3, heightPx: 4),
         "42 00000018 00000001 3E800000 3F000000 01 54 01 50 00000003 00000004"),
        (.handoffAccept(windowId: 1), "43 00000004 00000001"),
        (.handoffReject(windowId: 1, reason: "no"), "44 00000007 00000001 02 6E 6F"),
        (.windowStreamStart(windowId: 1), "45 00000004 00000001"),
        (.windowStreamFrame(windowId: 1, flags: 2, ptsMicros: 3, nal: [9, 8]), "46 0000000F 00000001 02 0000000000000003 09 08"),
        (.windowInputMouseMove(windowId: 1, x: 0.5, y: 1.0), "47 0000000C 00000001 3F000000 3F800000"),
        (.handoffReturn(windowId: 1), "48 00000004 00000001"),
        (.windowClosed(windowId: 1), "49 00000004 00000001"),
        (.windowInputMouseButton(windowId: 1, button: 2, down: true, x: 0.5, y: 1.0), "4A 0000000E 00000001 02 01 3F000000 3F800000"),
        (.windowInputKey(windowId: 1, macKeyCode: 0x0102, down: true, cgEventFlags: 0x304), "4B 0000000F 00000001 0102 01 0000000000000304"),
        (.windowInputScroll(windowId: 1, dx: 2.0, dy: 4.0), "4C 0000000C 00000001 40000000 40800000"),
        (.appLaunch(requestId: 1, bundleId: "a.b", activate: true, targets: ["x", "yz"]),
         "70 00000013 00000001 0003 61 2E 62 01 0002 0001 78 0002 79 7A"),
        (.appList([AppInfo(appId: 1, bundleId: "a", name: "b", pid: -2, windowCount: 3, residentMB: 4, running: true)]),
         "71 00000017 0001 00000001 0001 61 0001 62 FFFFFFFE 0003 00000004 01"),
        (.windowAdded(windowId: 1, appId: 2, kind: .sheet, parentId: 3, title: "t", geometry: Geometry(x: 0.5, y: 1.0, width: 2.0, height: 4.0, scale: 3.0)),
         "72 00000024 00000001 00000002 01 00000003 0001 74 3F000000 3F800000 40000000 40800000 40400000"),
        (.windowMoved(windowId: 1, x: 0.5, y: 1.0), "73 0000000C 00000001 3F000000 3F800000"),
        (.windowResized(windowId: 1, width: 2.0, height: 4.0, scale: 3.0), "74 00000010 00000001 40000000 40800000 40400000"),
        (.windowTitle(windowId: 1, title: "t"), "75 00000007 00000001 0001 74"),
        (.windowResizeRequest(windowId: 1, width: 2.0, height: 4.0), "76 0000000C 00000001 40000000 40800000"),
        (.childWindow(windowId: 1, parentId: 2, offsetX: 0.5, offsetY: 1.0, kind: .popover), "77 00000011 00000001 00000002 3F000000 3F800000 02"),
        (.menuTree(appId: 1, generation: 2, items: [MenuItem(itemId: 3, title: "m", enabled: true, checked: true, keyCode: 4, modifiers: 5,
                                                              children: [MenuItem(itemId: 6, title: "", separator: true)])]),
         "78 00000029 00000001 00000002 0001 00000003 0001 6D 03 0004 00000005 0001 00000006 0000 05 FFFF 00000000 0000"),
        (.menuInvoke(appId: 1, generation: 2, itemId: 3), "79 0000000C 00000001 00000002 00000003"),
        (.cursorShape(windowId: 1, shape: .iBeam, hotspotX: 0, hotspotY: 0, png: []), "7A 00000005 00000001 01"),
        (.cursorShape(windowId: 1, shape: .custom, hotspotX: 2, hotspotY: 3, png: [9]), "7A 0000000A 00000001 FF 0002 0003 09"),
        (.pasteboardOffer(generation: 1, entries: [PasteboardEntry(uti: "u", size: 2)]), "7B 00000010 00000001 01 0001 75 0000000000000002"),
        (.pasteboardFetch(generation: 1, uti: "u"), "7C 00000007 00000001 0001 75"),
        (.filePush(requestId: 1, windowId: 2, dropX: 0.5, dropY: 1.0, name: "f.txt"), "7D 00000017 00000001 00000002 3F000000 3F800000 0005 66 2E 74 78 74"),
        (.filePull(requestId: 1, fileId: 2), "7E 00000008 00000001 00000002"),
        (.audioFrame(appId: 1, ptsMicros: 2, aac: [9]), "7F 0000000D 00000001 0000000000000002 09"),
        (.badge(appId: 1, text: "3"), "80 00000007 00000001 0001 33"),
        (.notify(appId: 1, notificationId: "n", title: "t", subtitle: "s", body: "b", sound: true), "81 00000011 00000001 0001 6E 0001 74 0001 73 0001 62 01"),
        (.appListRequest, "82 00000000"),
        (.pasteboardData(generation: 1, uti: "u", offset: 0, total: 2, data: [7, 8]), "83 00000019 00000001 0001 75 0000000000000000 0000000000000002 07 08"),
        (.appLaunchResult(requestId: 1, status: 2, appId: 3), "84 00000009 00000001 02 00000003"),
        (.filePromise([FilePromiseEntry(fileId: 1, name: "f", size: 2)]), "85 00000011 0001 00000001 0001 66 0000000000000002"),
        (.unknown(type: 0xE0, payload: [1, 2]), "E0 00000002 0102"),
    ]

    private static func bytes(_ s: String) -> [UInt8] {
        // Spaces separate fields; a field is written as whole bytes (pairs of hex digits).
        s.split(separator: " ").flatMap { f -> [UInt8] in
            let c = Array(f); return stride(from: 0, to: c.count, by: 2).map { UInt8(String(c[$0...$0 + 1]), radix: 16)! }
        }
    }

    func testEveryMessageHasAGoldenFrameThatEncodesAndDecodes() throws {
        for (m, h) in Self.golden {
            let want = Self.bytes(h)
            XCTAssertEqual(try m.encodeFrame(), want, "encode \(m)")
            var p = FrameParser()
            let frames = try p.feed(want)
            XCTAssertEqual(frames.count, 1)
            XCTAssertEqual(try DeskMessage.decode(frames[0]), m, "decode \(m)")
        }
    }

    func testGoldenCoversEveryNamedType() {
        let covered = Set(Self.golden.map { $0.0.typeByte })
        for raw in 0...255 { if let t = DeskType(rawValue: UInt8(raw)) { XCTAssertTrue(covered.contains(t.rawValue), "no golden frame for \(t)") } }
    }
}
