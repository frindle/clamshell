import XCTest
@testable import Clamshell

/// In-memory storage for the receiver.
final class MemoryFileStore: FileTransferStore {
    var room: UInt64 = .max
    var refuseBegin = false
    var refuseWrite = false
    var refuseFinish = false
    private(set) var begun: [UInt32: (name: String, size: UInt64)] = [:]
    private(set) var partial: [UInt32: Data] = [:]
    private(set) var finished: [UInt32: Data] = [:]
    private(set) var discarded: [UInt32] = []

    func hasRoom(forBytes size: UInt64) -> Bool { size <= room }
    func begin(id: UInt32, storedName: String, size: UInt64) -> Bool {
        if refuseBegin { return false }
        begun[id] = (storedName, size)
        partial[id] = Data()
        return true
    }
    func write(id: UInt32, bytes: Data) -> Bool {
        if refuseWrite { return false }
        partial[id]?.append(bytes)
        return true
    }
    func finish(id: UInt32) -> Bool {
        if refuseFinish { return false }
        finished[id] = partial.removeValue(forKey: id)
        return true
    }
    func discard(id: UInt32) {
        partial[id] = nil
        discarded.append(id)
    }
}

/// Checks the file transfer core against tests/vectors/file-transfer-v1.json
/// (PROTOCOL.md "File transfer"), plus the receiver's limits.
final class FileTransferVectorTests: XCTestCase {
    private typealias Dict = [String: Any]

    private lazy var root: Dict = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("vectors/file-transfer-v1.json")
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
    private func n(_ v: Any?) -> Int { (v as! NSNumber).intValue }
    private func u32(_ v: Any?) -> UInt32 { UInt32(truncating: v as! NSNumber) }
    private func payload(of frame: Data) -> Data { frame.subdata(in: 5 ..< frame.count) }

    // MARK: constants and framing

    func testConstants() {
        let types = root["messageTypes"] as! [String: Int]
        XCTAssertEqual(types["FILE_OFFER"], Int(FileTransfer.offerType))
        XCTAssertEqual(types["FILE_ANSWER"], Int(FileTransfer.answerType))
        XCTAssertEqual(types["FILE_DATA"], Int(FileTransfer.dataType))
        XCTAssertEqual(types["FILE_END"], Int(FileTransfer.endType))
        XCTAssertEqual(n(root["maxNameBytes"]), FileTransfer.maxNameBytes)
        XCTAssertEqual(n(root["maxDataBytes"]), FileTransfer.maxDataBytes)
    }

    func testOfferExample() {
        let ex = root["offerExample"] as! Dict
        let frame = hex(ex["frame"] as! String)
        XCTAssertEqual(frame[0], FileTransfer.offerType)
        guard case let .usable(offer) = FileTransfer.parseOffer(payload(of: frame)) else { return XCTFail("not usable") }
        XCTAssertEqual(offer, FileOffer(id: 7, name: "scan.pdf", size: 1048576, modified: 1794000000))
        // An encoded offer reads back as the same offer.
        let built = FileTransfer.offer(id: 7, name: "scan.pdf", size: 1048576, modified: 1794000000)
        XCTAssertEqual(built.type, FileTransfer.offerType)
        XCTAssertEqual(FileTransfer.parseOffer(built.payload), .usable(offer))
        XCTAssertEqual(built.frame[0], FileTransfer.offerType)
    }

    func testAnswers() {
        for v in list("answer") {
            let m = FileTransfer.answer(id: u32(v["id"]), status: UInt8(n(v["status"])))
            XCTAssertEqual(m.payload, hex(v["payload"] as! String))
            XCTAssertEqual(m.frame, hex(v["frame"] as! String))
            let d = FileTransfer.decodeStatus(hex(v["payload"] as! String))
            XCTAssertEqual(d?.id, u32(v["id"]))
            XCTAssertEqual(d?.status, UInt8(n(v["status"])))
        }
    }

    func testData() {
        for v in list("data") {
            let name = v["name"] as! String
            let bytes = hex(v["bytes"] as! String)
            let m = FileTransfer.data(id: u32(v["id"]), bytes: bytes)
            XCTAssertEqual(m.payload, hex(v["payload"] as! String), name)
            XCTAssertEqual(m.frame, hex(v["frame"] as! String), name)
            let d = FileTransfer.decodeData(hex(v["payload"] as! String))
            XCTAssertEqual(d?.id, u32(v["id"]), name)
            XCTAssertEqual(d?.bytes, bytes, name)
        }
        XCTAssertNil(FileTransfer.decodeData(Data([0, 0, 7])))
    }

    func testEnds() {
        for v in list("end") {
            let m = FileTransfer.end(id: u32(v["id"]), status: UInt8(n(v["status"])))
            XCTAssertEqual(m.payload, hex(v["payload"] as! String))
            XCTAssertEqual(m.frame, hex(v["frame"] as! String))
            let d = FileTransfer.decodeStatus(hex(v["payload"] as! String))
            XCTAssertEqual(d?.id, u32(v["id"]))
            XCTAssertEqual(d?.status, UInt8(n(v["status"])))
        }
        XCTAssertNil(FileTransfer.decodeStatus(Data([0, 0, 0, 7])))
    }

    func testDataSize() {
        for v in list("dataSize") {
            let name = v["name"] as! String
            let byte = hex(v["repeatByte"] as! String)[0]
            let count = n(v["count"])
            let store = MemoryFileStore()
            let r = FileReceiver(store: store)
            _ = r.receive(type: FileTransfer.offerType,
                          payload: FileTransfer.offer(id: 7, name: "big", size: 200_000).payload, now: 0)
            let msg = FileTransfer.data(id: 7, bytes: Data(repeating: byte, count: count))
            if (v["valid"] as? Bool) == false {
                let reply = r.receive(type: msg.type, payload: msg.payload, now: 1)
                XCTAssertEqual(reply, [FileTransfer.end(id: 7, status: 2)], name)
                XCTAssertEqual(r.state(of: 7), .failed, name)
            } else {
                XCTAssertEqual(msg.payload.count, n(v["payloadLength"]), name)
                XCTAssertEqual(r.receive(type: msg.type, payload: msg.payload, now: 1), [], name)
                XCTAssertEqual(r.state(of: 7), .open, name)
            }
        }
    }

    // MARK: offers

    func testOffers() {
        for v in list("offers") {
            let name = v["name"] as! String
            let got = FileTransfer.parseOffer(Data((v["json"] as! String).utf8))
            if (v["valid"] as! Bool) {
                let o = v["offer"] as! Dict
                let modified = (o["modified"] as? NSNumber).map { Int64(truncating: $0) }
                let expected = FileOffer(id: u32(o["id"]), name: o["name"] as! String,
                                         size: UInt64(truncating: o["size"] as! NSNumber), modified: modified)
                XCTAssertEqual(got, .usable(expected), name)
            } else if (v["answerable"] as! Bool) {
                XCTAssertEqual(got, .decline(id: u32(v["id"])), name)
            } else {
                XCTAssertEqual(got, .ignore, name)
            }
        }
    }

    func testDeclinedOfferIsAnsweredWithStatusOne() {
        for v in list("offers") where (v["valid"] as! Bool) == false {
            let name = v["name"] as! String
            let r = FileReceiver(store: MemoryFileStore())
            let reply = r.receive(type: FileTransfer.offerType, payload: Data((v["json"] as! String).utf8), now: 0)
            if (v["answerable"] as! Bool) {
                XCTAssertEqual(reply, [FileTransfer.answer(id: u32(v["id"]), status: 1)], name)
            } else {
                XCTAssertEqual(reply, [], name)
            }
            XCTAssertEqual(r.openCount, 0, name)
        }
    }

    // MARK: names

    func testNames() {
        for v in list("names") {
            let offered = v["name"] as! String
            XCTAssertEqual(FileTransfer.storedName(for: offered), v["stored"] as! String, "\(offered.debugDescription)")
        }
    }

    func testFreeNames() {
        for v in list("freeNames") {
            let taken = Set(v["taken"] as! [String])
            XCTAssertEqual(FileTransfer.freeName(v["name"] as! String, isTaken: { taken.contains($0) }),
                           v["stored"] as! String, "\(v)")
        }
    }

    // MARK: sequences

    func testSequences() {
        for v in list("sequences") {
            let name = v["name"] as! String
            let id = u32(v["id"])
            let size = UInt64(n(v["size"]))
            let store = MemoryFileStore()
            let r = FileReceiver(store: store)
            let offer = FileTransfer.offer(id: id, name: "seq.bin", size: size)
            XCTAssertEqual(r.receive(type: offer.type, payload: offer.payload, now: 0),
                           [FileTransfer.answer(id: id, status: 0)], name)
            XCTAssertEqual(r.state(of: id), .open, name)
            XCTAssertEqual(store.begun[id]?.name, "seq.bin", name)
            XCTAssertEqual(store.begun[id]?.size, size, name)

            var sent = Data()
            var t: TimeInterval = 0
            for (k, step) in (v["steps"] as! [Dict]).enumerated() {
                t += 1
                let label = "\(name) step \(k)"
                let frame = hex(step["frame"] as! String)
                if (step["kind"] as! String) == "data" { sent.append(hex(step["bytes"] as! String)) }
                let reply = r.receive(type: frame[0], payload: payload(of: frame), now: t)
                if let wanted = step["reply"] as? String {
                    XCTAssertEqual(reply.map { $0.frame }, [hex(wanted)], label)
                } else {
                    XCTAssertEqual(reply, [], label)
                }
                let state: FileTransferState
                switch step["state"] as! String {
                case "open": state = .open
                case "stored": state = .stored
                case "failed": state = .failed
                case "cancelled": state = .cancelled
                default: return XCTFail("\(label): unknown state")
                }
                XCTAssertEqual(r.state(of: id), state, label)
            }
            let last = (v["steps"] as! [Dict]).last!["state"] as! String
            if last == "stored" {
                XCTAssertEqual(store.finished[id], sent, name)
            } else {
                XCTAssertNil(store.finished[id], name)
                XCTAssertNil(store.partial[id], "\(name): partial kept")
            }
        }
    }

    // MARK: receiver limits

    private func offerPayload(_ id: UInt32, size: UInt64 = 10, name: String = "f") -> Data {
        FileTransfer.offer(id: id, name: name, size: size).payload
    }

    func testAtMostFourOpen() {
        let r = FileReceiver(store: MemoryFileStore())
        for id in 1...4 {
            XCTAssertEqual(r.receive(type: 0x58, payload: offerPayload(UInt32(id)), now: 0),
                           [FileTransfer.answer(id: UInt32(id), status: 0)])
        }
        XCTAssertEqual(r.receive(type: 0x58, payload: offerPayload(5), now: 0), [FileTransfer.answer(id: 5, status: 3)])
        XCTAssertEqual(r.openCount, 4)
        // Ending one makes room.
        _ = r.receive(type: 0x5B, payload: FileTransfer.end(id: 1, status: 1).payload, now: 1)
        XCTAssertEqual(r.receive(type: 0x58, payload: offerPayload(5), now: 1), [FileTransfer.answer(id: 5, status: 0)])
    }

    func testOfferReusingOpenIdIsIgnored() {
        let store = MemoryFileStore()
        let r = FileReceiver(store: store)
        _ = r.receive(type: 0x58, payload: offerPayload(1), now: 0)
        XCTAssertEqual(r.receive(type: 0x58, payload: offerPayload(1, name: "other"), now: 0), [])
        XCTAssertEqual(store.begun[1]?.name, "f")
        XCTAssertEqual(r.openCount, 1)
        // A closed id can be used again.
        _ = r.receive(type: 0x5B, payload: FileTransfer.end(id: 1, status: 1).payload, now: 0)
        XCTAssertEqual(r.receive(type: 0x58, payload: offerPayload(1), now: 0), [FileTransfer.answer(id: 1, status: 0)])
    }

    func testNoRoomAndTurnedOff() {
        let store = MemoryFileStore()
        store.room = 100
        let r = FileReceiver(store: store)
        XCTAssertEqual(r.receive(type: 0x58, payload: offerPayload(1, size: 101), now: 0), [FileTransfer.answer(id: 1, status: 2)])
        XCTAssertEqual(r.receive(type: 0x58, payload: offerPayload(1, size: 100), now: 0), [FileTransfer.answer(id: 1, status: 0)])
        store.refuseBegin = true
        XCTAssertEqual(r.receive(type: 0x58, payload: offerPayload(2), now: 0), [FileTransfer.answer(id: 2, status: 2)])
        r.transfersEnabled = false
        XCTAssertEqual(r.receive(type: 0x58, payload: offerPayload(3), now: 0), [FileTransfer.answer(id: 3, status: 4)])
        XCTAssertEqual(r.openCount, 1)
    }

    func testOfferedNameIsNeverPassedToStore() {
        let store = MemoryFileStore()
        let r = FileReceiver(store: store)
        _ = r.receive(type: 0x58, payload: offerPayload(1, name: "../../etc/passwd"), now: 0)
        XCTAssertEqual(store.begun[1]?.name, "passwd")
    }

    func testIdleFailureAfterSixtySeconds() {
        let store = MemoryFileStore()
        let r = FileReceiver(store: store)
        _ = r.receive(type: 0x58, payload: offerPayload(1), now: 100)
        _ = r.receive(type: 0x58, payload: offerPayload(2), now: 100)
        _ = r.receive(type: 0x5A, payload: FileTransfer.data(id: 2, bytes: Data([1])).payload, now: 130)
        XCTAssertEqual(r.tick(now: 159.9), [])
        XCTAssertEqual(r.tick(now: 160), [FileTransfer.end(id: 1, status: 2)])
        XCTAssertEqual(r.state(of: 1), .failed)
        XCTAssertEqual(r.state(of: 2), .open)
        XCTAssertEqual(r.tick(now: 190), [FileTransfer.end(id: 2, status: 2)])
        XCTAssertEqual(r.openCount, 0)
        XCTAssertNil(store.partial[1])
        XCTAssertNil(store.partial[2])
        // Data for a transfer that is gone is ignored.
        XCTAssertEqual(r.receive(type: 0x5A, payload: FileTransfer.data(id: 1, bytes: Data([1])).payload, now: 191), [])
    }

    func testCloseAllDiscardsEverything() {
        let store = MemoryFileStore()
        let r = FileReceiver(store: store)
        _ = r.receive(type: 0x58, payload: offerPayload(1), now: 0)
        _ = r.receive(type: 0x58, payload: offerPayload(2), now: 0)
        r.closeAll()
        XCTAssertEqual(r.openCount, 0)
        XCTAssertEqual(Set(store.discarded), [1, 2])
        XCTAssertTrue(store.partial.isEmpty)
    }

    func testStoreFailuresFailTheTransfer() {
        let store = MemoryFileStore()
        let r = FileReceiver(store: store)
        _ = r.receive(type: 0x58, payload: offerPayload(1, size: 4), now: 0)
        store.refuseWrite = true
        XCTAssertEqual(r.receive(type: 0x5A, payload: FileTransfer.data(id: 1, bytes: Data([1, 2])).payload, now: 1),
                       [FileTransfer.end(id: 1, status: 2)])
        store.refuseWrite = false
        _ = r.receive(type: 0x58, payload: offerPayload(2, size: 1), now: 1)
        _ = r.receive(type: 0x5A, payload: FileTransfer.data(id: 2, bytes: Data([1])).payload, now: 1)
        store.refuseFinish = true
        XCTAssertEqual(r.receive(type: 0x5B, payload: FileTransfer.end(id: 2, status: 0).payload, now: 2),
                       [FileTransfer.end(id: 2, status: 2)])
        XCTAssertEqual(r.state(of: 2), .failed)
    }

    // MARK: sender

    func testSenderFlow() {
        var s = FileSender(id: 3, name: "a.bin", size: 150_000)
        XCTAssertEqual(s.phase, .offered)
        XCTAssertEqual(s.offerMessage().type, FileTransfer.offerType)
        XCTAssertEqual(s.nextPieceLength(), 0)
        XCTAssertNil(s.pieceMessage(Data([1])))
        s.handleAnswer(status: 0)
        XCTAssertEqual(s.phase, .accepted)
        XCTAssertEqual(s.nextPieceLength(), 65_536)
        XCTAssertEqual(s.nextPieceLength(maxPiece: 1000), 1000)
        XCTAssertNil(s.endMessage())
        XCTAssertNotNil(s.pieceMessage(Data(repeating: 0, count: 65_536)))
        XCTAssertEqual(s.phase, .sending)
        XCTAssertNil(s.pieceMessage(Data(repeating: 0, count: 65_537)))
        XCTAssertNotNil(s.pieceMessage(Data(repeating: 0, count: 65_536)))
        XCTAssertEqual(s.nextPieceLength(), 150_000 - 131_072)
        XCTAssertNil(s.pieceMessage(Data(repeating: 0, count: 150_000 - 131_072 + 1)))
        XCTAssertNotNil(s.pieceMessage(Data(repeating: 0, count: 150_000 - 131_072)))
        XCTAssertTrue(s.allSent)
        XCTAssertEqual(s.nextPieceLength(), 0)
        XCTAssertEqual(s.endMessage(), FileTransfer.end(id: 3, status: 0))
        XCTAssertEqual(s.phase, .finishing)
        s.handleEnd(status: 0)
        XCTAssertEqual(s.phase, .ended(.stored))
    }

    func testSenderDeclinedCancelledAndEmpty() {
        var a = FileSender(id: 1, name: "a", size: 1)
        a.handleAnswer(status: 3)
        XCTAssertEqual(a.phase, .ended(.declined(status: 3)))
        XCTAssertNil(a.cancel())

        var b = FileSender(id: 2, name: "b", size: 10)
        b.handleAnswer(status: 0)
        XCTAssertEqual(b.cancel(), FileTransfer.end(id: 2, status: 1))
        XCTAssertEqual(b.phase, .ended(.cancelled))

        var c = FileSender(id: 4, name: "c", size: 0)
        c.handleAnswer(status: 0)
        XCTAssertEqual(c.nextPieceLength(), 0)
        XCTAssertEqual(c.endMessage(), FileTransfer.end(id: 4, status: 0))
        c.handleEnd(status: 2)
        XCTAssertEqual(c.phase, .ended(.failed))

        var d = FileSender(id: 5, name: "d", size: 5)
        d.handleAnswer(status: 0)
        d.connectionClosed()
        XCTAssertEqual(d.phase, .ended(.failed))
    }
}
