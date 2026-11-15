import XCTest
import CoreGraphics
@testable import Clamshell

/// Checks the host's input decoding and InputCore against the shared vectors in
/// tests/vectors/input-v1.json (PROTOCOL.md "Input mapping").
final class InputVectorTests: XCTestCase {
    private typealias Dict = [String: Any]

    private lazy var root: Dict = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("vectors/input-v1.json")
        let data = try! Data(contentsOf: url)
        return try! JSONSerialization.jsonObject(with: data) as! Dict
    }()

    private func list(_ key: String) -> [Dict] { root[key] as! [Dict] }

    private func hex(_ s: String) -> Data {
        var d = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            d.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return d
    }

    private func typeNamed(_ name: String) -> StreamMessageType {
        let n = (root["messageTypes"] as! [String: Int])[name]!
        return StreamMessageType(rawValue: UInt8(n))!
    }

    private func f(_ v: Any?) -> Float32 { (v as! NSNumber).floatValue }
    private func i(_ v: Any?) -> Int { (v as! NSNumber).intValue }
    private func b(_ v: Any?) -> Bool { (v as! NSNumber).boolValue }

    private func makeCore() -> InputCore {
        InputCore(boundsProvider: { CGRect(x: 0, y: 0, width: 1000, height: 800) },
                  displaysProvider: { [CGRect(x: 0, y: 0, width: 1000, height: 800)] },
                  cursorProvider: { CGPoint(x: 500, y: 400) },
                  clock: { 0 }, doubleClickInterval: { 0.5 })
    }

    /// What InputCore does with a decoded message.
    private func events(_ m: InputMessage, _ core: InputCore) -> [InputEvent] {
        switch m {
        case let .mouseMove(x, y): return core.mouseMove(x: x, y: y)
        case let .mouseButton(button, down, x, y): return core.mouseButton(button: button, down: down, x: x, y: y)
        case let .key(code, down, flags): return core.key(macKeyCode: code, down: down, flags: flags)
        case let .scroll(dx, dy): return core.scroll(dx: dx, dy: dy, invert: false)
        case let .mouseRelative(dx, dy): return core.mouseRelative(dx: dx, dy: dy)
        case let .mouseButtonAtCursor(button, down): return core.mouseButtonAtCursor(button: button, down: down)
        case let .text(data): return core.text(data)
        }
    }

    private func decodeFrame(_ frame: Data) -> InputMessage? {
        let type = StreamMessageType(rawValue: frame[frame.startIndex])!
        return InputMessage.decode(type: type, payload: frame.subdata(in: frame.startIndex + 5 ..< frame.endIndex))
    }

    // MARK: frames

    func testFrames() {
        for v in list("frames") {
            let name = v["name"] as! String
            let type = typeNamed(v["type"] as! String)
            let payload = hex(v["payload"] as! String)
            let frame = hex(v["frame"] as! String)

            let built: Data
            let expected: InputMessage
            switch v["type"] as! String {
            case "INPUT_MOUSE_MOVE":
                expected = .mouseMove(x: f(v["x"]), y: f(v["y"]))
                built = StreamMessage.mouseMove(x: f(v["x"]), y: f(v["y"]))
            case "INPUT_MOUSE_BUTTON":
                expected = .mouseButton(button: UInt8(i(v["button"])), down: b(v["down"]), x: f(v["x"]), y: f(v["y"]))
                built = StreamMessage.mouseButton(button: UInt8(i(v["button"])), down: b(v["down"]), x: f(v["x"]), y: f(v["y"]))
            case "INPUT_KEY":
                let flags = hex(v["flags"] as! String).beUInt64(at: 0)
                expected = .key(macKeyCode: UInt16(i(v["macKeyCode"])), down: b(v["down"]), flags: flags)
                built = StreamMessage.key(macKeyCode: UInt16(i(v["macKeyCode"])), down: b(v["down"]), flags: flags)
            case "INPUT_SCROLL":
                expected = .scroll(dx: f(v["dx"]), dy: f(v["dy"]))
                built = StreamMessage.scroll(dx: f(v["dx"]), dy: f(v["dy"]))
            case "INPUT_MOUSE_RELATIVE":
                expected = .mouseRelative(dx: f(v["dx"]), dy: f(v["dy"]))
                built = StreamMessage.mouseRelative(dx: f(v["dx"]), dy: f(v["dy"]))
            case "INPUT_MOUSE_BUTTON_AT_CURSOR":
                expected = .mouseButtonAtCursor(button: UInt8(i(v["button"])), down: b(v["down"]))
                built = StreamMessage.mouseButtonAtCursor(button: UInt8(i(v["button"])), down: b(v["down"]))
            case "INPUT_TEXT":
                expected = .text(Data((v["text"] as! String).utf8))
                built = StreamMessage.text(v["text"] as! String)
            default:
                XCTFail("\(name): unknown type"); continue
            }
            XCTAssertEqual(built, frame, "\(name): builder bytes")
            XCTAssertEqual(frame[frame.startIndex], type.rawValue, "\(name): type byte")
            XCTAssertEqual(String(describing: InputMessage.decode(type: type, payload: payload) as Any),
                           String(describing: Optional(expected) as Any), "\(name): decode")
        }
    }

    // MARK: ignored and longer

    func testIgnored() {
        for v in list("ignored") {
            let name = v["name"] as! String
            let frame = hex(v["frame"] as! String)
            XCTAssertEqual(hex(v["payload"] as! String), frame.subdata(in: 5 ..< frame.count), "\(name): payload vs frame")
            guard let m = decodeFrame(frame) else { continue } // dropped at decode
            let core = makeCore()
            XCTAssertEqual(events(m, core), [], "\(name): produced events")
            XCTAssertEqual(core.heldButtonCount, 0, "\(name): held button")
            XCTAssertEqual(core.heldKeyCount, 0, "\(name): held key")
        }
    }

    func testLonger() {
        let frames = list("frames")
        for v in list("longer") {
            let name = v["name"] as! String
            let target = frames.first { ($0["name"] as! String) == (v["decodesAs"] as! String) }!
            let a = decodeFrame(hex(v["frame"] as! String))
            let bm = decodeFrame(hex(target["frame"] as! String))
            XCTAssertNotNil(a, name)
            XCTAssertEqual(String(describing: a as Any), String(describing: bm as Any), name)
        }
    }

    // MARK: scroll, relative, key flags

    func testScroll() {
        for v in list("scroll") {
            let name = v["name"] as! String
            let m = decodeFrame(hex(v["frame"] as! String))
            guard case let .scroll(dx, dy)? = m else { XCTFail("\(name): not a scroll"); continue }
            let got = makeCore().scroll(dx: dx, dy: dy, invert: false)
            if (v["ignored"] as? Bool) == true {
                XCTAssertEqual(got, [], name)
            } else {
                XCTAssertEqual(got, [.scroll(dx: Int32(i(v["dxUsed"])), dy: Int32(i(v["dyUsed"])))], name)
            }
        }
    }

    func testRelative() {
        for v in list("relative") {
            let name = v["name"] as! String
            let m = decodeFrame(hex(v["frame"] as! String))
            guard case let .mouseRelative(dx, dy)? = m else { XCTFail("\(name): not relative"); continue }
            let got = makeCore().mouseRelative(dx: dx, dy: dy)
            if (v["ignored"] as? Bool) == true {
                XCTAssertEqual(got, [], name)
                continue
            }
            guard got.count == 1, case let .mouse(_, _, _, _, delta?) = got[0] else {
                XCTFail("\(name): expected one move with a delta, got \(got)"); continue
            }
            XCTAssertEqual(delta.dx, CGFloat(i(v["dxUsed"])), name)
            XCTAssertEqual(delta.dy, CGFloat(i(v["dyUsed"])), name)
        }
    }

    func testKeyFlags() {
        for v in list("keyFlags") {
            let name = v["name"] as! String
            let flags = hex(v["flags"] as! String).beUInt64(at: 0)
            let used = hex(v["used"] as! String).beUInt64(at: 0)
            XCTAssertEqual(makeCore().key(macKeyCode: 0, down: true, flags: flags),
                           [.key(code: 0, down: true, flags: used)], name)
        }
        XCTAssertEqual(hex(root["modifierMask"] as! String).beUInt64(at: 0), InputCore.modifierFlagMask)
    }

    func testConstants() {
        XCTAssertEqual(i(root["maxTextBytes"]), InputCore.maxTextBytes)
        XCTAssertEqual(Double(i(root["deltaCap"])), InputCore.maxRelativeDelta)
    }

    // MARK: text

    private func steps(_ events: [InputEvent]) -> [String] {
        let keys = Dictionary(uniqueKeysWithValues: (root["textKeys"] as! [String: Int]).map { ($0.value, $0.key) })
        var out: [String] = []
        var idx = 0
        while idx < events.count {
            switch events[idx] {
            case let .text(s):
                if let last = out.last, last.hasPrefix("text:") {
                    out[out.count - 1] = last + s
                } else {
                    out.append("text:" + s)
                }
                idx += 1
            case let .key(code, true, _):
                guard idx + 1 < events.count, case .key(code, false, _) = events[idx + 1] else {
                    out.append("unpaired:\(code)"); idx += 1; continue
                }
                out.append("key:" + (keys[Int(code)] ?? "\(code)"))
                idx += 2
            default:
                out.append("other:\(events[idx])"); idx += 1
            }
        }
        return out
    }

    func testText() {
        for v in list("text") {
            let name = v["name"] as! String
            let payload = hex(v["utf8"] as! String)
            let frame = StreamMessage.frame(type: .text, payload: payload)
            guard case let .text(data)? = decodeFrame(frame) else { XCTFail("\(name): decode"); continue }
            let got = makeCore().text(data)
            let wanted = (v["steps"] as? [Dict]) ?? []
            if (v["ignored"] as? Bool) == true || wanted.isEmpty {
                XCTAssertEqual(got, [], name)
                continue
            }
            let expected = wanted.map { s -> String in
                if let t = s["text"] as? String { return "text:" + t }
                return "key:" + (s["key"] as! String)
            }
            XCTAssertEqual(steps(got), expected, name)
            // Pieces never split a code point.
            for case let .text(s) in got { XCTAssertNotNil(String(data: Data(s.utf8), encoding: .utf8), name) }
        }
    }

    func testTextSize() {
        for v in list("textSize") {
            let name = v["name"] as! String
            let byte = hex(v["repeatByte"] as! String)[0]
            let payload = Data(repeating: byte, count: i(v["count"]))
            let got = makeCore().text(payload)
            if (v["ignored"] as? Bool) == true {
                XCTAssertEqual(got, [], name)
            } else {
                let typed = got.reduce(0) { n, e in if case let .text(s) = e { return n + s.count } else { return n } }
                XCTAssertEqual(typed, i(v["typedLength"]), name)
            }
        }
    }
}
