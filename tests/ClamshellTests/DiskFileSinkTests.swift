import XCTest
@testable import Clamshell

/// DiskFileSink against a temporary directory (PROTOCOL.md "File transfer",
/// receiver rules).
final class DiskFileSinkTests: XCTestCase {
    private var root: URL!
    private var folder: URL { root.appendingPathComponent("inbox", isDirectory: true) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clamshell-sink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func names(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private func sink(free: UInt64? = UInt64.max) -> DiskFileSink {
        DiskFileSink(folder: folder, reserveBytes: 1000, freeSpace: { _ in free })
    }

    /// Whole transfer through the receiver, as the host would run it.
    @discardableResult
    private func receive(_ sink: DiskFileSink, id: UInt32 = 1, name: String, bytes: Data) -> [FileTransferMessage] {
        let r = FileReceiver(store: sink)
        let offer = FileTransfer.offer(id: id, name: name, size: UInt64(bytes.count))
        var replies = r.receive(type: offer.type, payload: offer.payload, now: 0)
        let d = FileTransfer.data(id: id, bytes: bytes)
        if !bytes.isEmpty { replies += r.receive(type: d.type, payload: d.payload, now: 1) }
        let e = FileTransfer.end(id: id, status: 0)
        replies += r.receive(type: e.type, payload: e.payload, now: 2)
        return replies
    }

    func testStoredWithContentModeAndQuarantine() throws {
        let s = sink()
        let bytes = Data("hello".utf8)
        let replies = receive(s, name: "scan.pdf", bytes: bytes)
        XCTAssertEqual(replies, [FileTransfer.answer(id: 1, status: 0), FileTransfer.end(id: 1, status: 0)])
        XCTAssertEqual(names(in: folder), ["scan.pdf"])
        let url = folder.appendingPathComponent("scan.pdf")
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        let values = try url.resourceValues(forKeys: [.quarantinePropertiesKey])
        XCTAssertNotNil(values.quarantineProperties)
        XCTAssertEqual(s.lastStoredURL?.lastPathComponent, "scan.pdf")
    }

    func testEmptyFileIsStored() throws {
        receive(sink(), name: "empty", bytes: Data())
        XCTAssertEqual(names(in: folder), ["empty"])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("empty")).count, 0)
    }

    func testNeverOverwrites() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let existing = folder.appendingPathComponent("scan.pdf")
        try Data("original".utf8).write(to: existing)

        let s = sink()
        receive(s, id: 1, name: "scan.pdf", bytes: Data("one".utf8))
        receive(s, id: 2, name: "scan.pdf", bytes: Data("two".utf8))
        XCTAssertEqual(names(in: folder), ["scan 2.pdf", "scan 3.pdf", "scan.pdf"])
        XCTAssertEqual(try Data(contentsOf: existing), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("scan 2.pdf")), Data("one".utf8))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("scan 3.pdf")), Data("two".utf8))
    }

    func testSameNameInFlightTwice() throws {
        let s = sink()
        XCTAssertTrue(s.begin(id: 1, storedName: "a.txt", size: 1))
        XCTAssertTrue(s.begin(id: 2, storedName: "a.txt", size: 1))
        XCTAssertTrue(s.write(id: 1, bytes: Data([1])))
        XCTAssertTrue(s.write(id: 2, bytes: Data([2])))
        XCTAssertTrue(s.finish(id: 2))
        XCTAssertTrue(s.finish(id: 1))
        XCTAssertEqual(names(in: folder), ["a 2.txt", "a.txt"])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("a.txt")), Data([2]))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("a 2.txt")), Data([1]))
    }

    func testPartialFileRemovedOnDiscard() {
        let s = sink()
        XCTAssertTrue(s.begin(id: 1, storedName: "x.bin", size: 10))
        XCTAssertTrue(s.write(id: 1, bytes: Data([1, 2, 3])))
        XCTAssertEqual(names(in: folder).count, 1)
        s.discard(id: 1)
        XCTAssertEqual(names(in: folder), [])
        s.discard(id: 1) // already gone: harmless
    }

    func testPartialFileRemovedWhenTransferFailsOrConnectionEnds() {
        let s = sink()
        let r = FileReceiver(store: s)
        let offer = FileTransfer.offer(id: 1, name: "x.bin", size: 4)
        _ = r.receive(type: offer.type, payload: offer.payload, now: 0)
        let d = FileTransfer.data(id: 1, bytes: Data([1, 2]))
        _ = r.receive(type: d.type, payload: d.payload, now: 1)
        // Ended early: fails and leaves nothing.
        let e = FileTransfer.end(id: 1, status: 0)
        XCTAssertEqual(r.receive(type: e.type, payload: e.payload, now: 2), [FileTransfer.end(id: 1, status: 2)])
        XCTAssertEqual(names(in: folder), [])

        let offer2 = FileTransfer.offer(id: 2, name: "y.bin", size: 4)
        _ = r.receive(type: offer2.type, payload: offer2.payload, now: 3)
        XCTAssertEqual(names(in: folder).count, 1)
        r.closeAll()
        XCTAssertEqual(names(in: folder), [])
    }

    func testHostileNamesStayInsideFolder() throws {
        let s = sink()
        receive(s, id: 1, name: "../../evil.txt", bytes: Data("x".utf8))
        receive(s, id: 2, name: "/etc/passwd", bytes: Data("x".utf8))
        receive(s, id: 3, name: "..\\..\\evil2.txt", bytes: Data("x".utf8))
        receive(s, id: 4, name: "..", bytes: Data("x".utf8))
        receive(s, id: 5, name: ".hidden", bytes: Data("x".utf8))
        XCTAssertEqual(names(in: folder), ["evil.txt", "evil2.txt", "file", "hidden", "passwd"])
        // Nothing appeared next to the folder.
        XCTAssertEqual(names(in: root), ["inbox"])
    }

    func testSinkRefusesNamesThatAreNotPlainChildren() {
        let s = sink()
        XCTAssertFalse(s.begin(id: 1, storedName: "../evil", size: 1))
        XCTAssertFalse(s.begin(id: 2, storedName: "a/b", size: 1))
        XCTAssertFalse(s.begin(id: 3, storedName: "..", size: 1))
        XCTAssertFalse(s.begin(id: 4, storedName: ".", size: 1))
        XCTAssertFalse(s.begin(id: 5, storedName: "", size: 1))
        XCTAssertEqual(names(in: root).filter { $0 != "inbox" }, [])
        XCTAssertEqual(names(in: folder), [])
    }

    func testFolderCreatedWhenFirstNeeded() {
        let s = sink()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(s.hasRoom(forBytes: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(s.begin(id: 1, storedName: "a", size: 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        s.discard(id: 1)
    }

    func testFreeSpaceReserve() {
        let s = sink(free: 5000)
        XCTAssertTrue(s.hasRoom(forBytes: 4000))
        XCTAssertFalse(s.hasRoom(forBytes: 4001))
        XCTAssertFalse(s.hasRoom(forBytes: UInt64.max))
        XCTAssertFalse(sink(free: nil).hasRoom(forBytes: 1))
        // An offer that does not fit is answered with status 2.
        let r = FileReceiver(store: s)
        let offer = FileTransfer.offer(id: 1, name: "big", size: 4001)
        XCTAssertEqual(r.receive(type: offer.type, payload: offer.payload, now: 0), [FileTransfer.answer(id: 1, status: 2)])
        XCTAssertEqual(names(in: folder), [])
    }

    func testRealFreeSpaceCheckWorks() {
        let s = DiskFileSink(folder: folder)
        _ = s.hasRoom(forBytes: 0) // the folder does not exist yet: the check walks up to a folder that does
        XCTAssertFalse(s.hasRoom(forBytes: UInt64.max / 2))
    }
}
