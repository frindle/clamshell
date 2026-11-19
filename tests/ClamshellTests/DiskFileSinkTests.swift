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

    func testNamesThatStillMisleadAreCleaned() {
        // Line and paragraph separators and the Hangul filler are removed.
        XCTAssertEqual(FileTransfer.storedName(for: "a\u{2028}b\u{2029}c\u{3164}.txt"), "abc.txt")
        // Unicode blanks at both ends go, like spaces do; inside they stay.
        XCTAssertEqual(FileTransfer.storedName(for: "\u{00A0}\u{3000}report one.pdf\u{3000}\u{00A0}"), "report one.pdf")
        XCTAssertEqual(FileTransfer.storedName(for: "\u{3000}\u{00A0}"), "file")
        XCTAssertEqual(FileTransfer.storedName(for: "\u{00A0}.hidden"), "hidden")
        // Look-alike dots and slashes become `_`, so no extension is faked and no path is hinted at.
        XCTAssertEqual(FileTransfer.storedName(for: "photo\u{FF0E}jpg"), "photo_jpg")
        XCTAssertEqual(FileTransfer.storedName(for: "a\u{2215}b\u{FF0F}c"), "a_b_c")
        XCTAssertEqual(FileTransfer.storedName(for: "x\u{2024}y\u{FE52}z\u{FF3C}w"), "x_y_z_w")
        // A name made only of such characters is not empty any more, and is still a plain child.
        XCTAssertEqual(FileTransfer.storedName(for: "\u{FF0E}\u{FF0E}"), "__")
        // Trailing dots stay (the shared vectors say so); ordinary dots and a real slash are unchanged.
        XCTAssertEqual(FileTransfer.storedName(for: "trailing.dot."), "trailing.dot.")
        XCTAssertEqual(FileTransfer.storedName(for: "dir/scan.pdf"), "scan.pdf")
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

    func testFormatCharactersAreStrippedFromStoredNames() {
        // Bidirectional overrides and isolates, zero-width and direction marks, BOM.
        let ranges: [ClosedRange<UInt32>] = [0x202A...0x202E, 0x2066...0x2069, 0x200B...0x200F, 0xFEFF...0xFEFF]
        for range in ranges {
            for value in range {
                let c = String(UnicodeScalar(value)!)
                XCTAssertEqual(FileTransfer.storedName(for: "re\(c)port.\(c)pdf"), "report.pdf",
                               "U+\(String(value, radix: 16, uppercase: true))")
            }
        }
        // The classic right-to-left override trick: the name must not end up reading as ".exe" reversed.
        XCTAssertEqual(FileTransfer.storedName(for: "invoice\u{202E}fdp.exe"), "invoicefdp.exe")
        // Nothing but format characters leaves the fallback name.
        XCTAssertEqual(FileTransfer.storedName(for: "\u{202E}\u{200B}\u{FEFF}"), "file")
        // Ordinary non-ASCII letters stay.
        XCTAssertEqual(FileTransfer.storedName(for: "résumé 日本.txt"), "résumé 日本.txt")
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

    func testOpenTransfersCountAgainstFreeSpace() {
        // 5000 free, 1000 reserve: 4000 may be taken. Two offers of 3000 each fit alone, not together.
        let s = sink(free: 5000)
        let r = FileReceiver(store: s)
        let first = FileTransfer.offer(id: 1, name: "a.bin", size: 3000)
        XCTAssertEqual(r.receive(type: first.type, payload: first.payload, now: 0), [FileTransfer.answer(id: 1, status: 0)])
        let second = FileTransfer.offer(id: 2, name: "b.bin", size: 3000)
        // The existing full-disk status.
        XCTAssertEqual(r.receive(type: second.type, payload: second.payload, now: 1), [FileTransfer.answer(id: 2, status: 2)])
        XCTAssertEqual(r.openCount, 1)
        // Something that fits next to the first one is still accepted.
        let small = FileTransfer.offer(id: 3, name: "c.bin", size: 1000)
        XCTAssertEqual(r.receive(type: small.type, payload: small.payload, now: 2), [FileTransfer.answer(id: 3, status: 0)])
        // Once they are over, their sizes no longer count.
        r.closeAll()
        let again = FileTransfer.offer(id: 4, name: "d.bin", size: 3000)
        XCTAssertEqual(r.receive(type: again.type, payload: again.payload, now: 3), [FileTransfer.answer(id: 4, status: 0)])
        r.closeAll()
        // The sum cannot wrap around.
        let t = sink(free: UInt64.max)
        XCTAssertTrue(t.begin(id: 1, storedName: "x", size: UInt64.max - 1000))
        XCTAssertFalse(t.hasRoom(forBytes: 2000))
        t.discard(id: 1)
    }

    /// An offer of `size` to a second sink on the same folder, answered the way the host would.
    private func answer(of s: DiskFileSink, id: UInt32, size: UInt64) -> [FileTransferMessage] {
        let r = FileReceiver(store: s)
        let o = FileTransfer.offer(id: id, name: "n\(id).bin", size: size)
        return r.receive(type: o.type, payload: o.payload, now: 0)
    }

    func testReserveCoversEverySinkOnTheSameFolder() {
        // 5000 free, 1000 reserve: 4000 may be taken in total, over all sinks.
        let s1 = sink(free: 5000)
        let s2 = sink(free: 5000)
        XCTAssertTrue(s1.begin(id: 1, storedName: "a.bin", size: 3000))
        XCTAssertEqual(DiskFileSink.openTotal(inFolder: folder), 3000)
        XCTAssertFalse(s2.hasRoom(forBytes: 3000))
        XCTAssertEqual(answer(of: s2, id: 1, size: 3000), [FileTransfer.answer(id: 1, status: 2)])
        XCTAssertFalse(s2.begin(id: 2, storedName: "b.bin", size: 3000))
        XCTAssertEqual(DiskFileSink.openTotal(inFolder: folder), 3000)
        // What fits next to the first transfer is still accepted by the other sink.
        XCTAssertTrue(s2.begin(id: 3, storedName: "c.bin", size: 1000))
        s2.discard(id: 3)
        s1.discard(id: 1)
        XCTAssertEqual(DiskFileSink.openTotal(inFolder: folder), 0)
    }

    func testOtherSinkIsAcceptedAfterTheFirstTransferIsCancelled() {
        let s1 = sink(free: 5000)
        let s2 = sink(free: 5000)
        XCTAssertTrue(s1.begin(id: 1, storedName: "a.bin", size: 3000))
        XCTAssertEqual(answer(of: s2, id: 1, size: 3000), [FileTransfer.answer(id: 1, status: 2)])
        s1.discard(id: 1)
        // A second end of the same transfer takes nothing away again.
        s1.discard(id: 1)
        XCTAssertEqual(DiskFileSink.openTotal(inFolder: folder), 0)
        let r2 = FileReceiver(store: s2)
        let o = FileTransfer.offer(id: 2, name: "b.bin", size: 3000)
        XCTAssertEqual(r2.receive(type: o.type, payload: o.payload, now: 1), [FileTransfer.answer(id: 2, status: 0)])
        r2.closeAll()
        XCTAssertEqual(DiskFileSink.openTotal(inFolder: folder), 0)
    }

    func testOtherSinkIsAcceptedAfterTheFirstSinkIsReleased() {
        let s2 = sink(free: 5000)
        var s1: DiskFileSink? = sink(free: 5000)
        XCTAssertTrue(s1!.begin(id: 1, storedName: "a.bin", size: 3000))
        XCTAssertFalse(s2.hasRoom(forBytes: 3000))
        // No cancel: the sink's deinit ends the transfer.
        s1 = nil
        XCTAssertEqual(DiskFileSink.openTotal(inFolder: folder), 0)
        XCTAssertTrue(s2.begin(id: 2, storedName: "b.bin", size: 3000))
        s2.discard(id: 2)
        XCTAssertEqual(DiskFileSink.openTotal(inFolder: folder), 0)
    }

    func testFinishedTransferReleasesItsSize() {
        let s1 = sink(free: 5000)
        XCTAssertTrue(s1.begin(id: 1, storedName: "a.bin", size: 3))
        XCTAssertTrue(s1.write(id: 1, bytes: Data([1, 2, 3])))
        XCTAssertTrue(s1.finish(id: 1))
        XCTAssertEqual(DiskFileSink.openTotal(inFolder: folder), 0)
    }

    func testLeftoverPartFilesAreRemovedBeforeTheFirstTransfer() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let elsewhere = root.appendingPathComponent("elsewhere.txt")
        try Data("keep me".utf8).write(to: elsewhere)
        func put(_ name: String, in dir: URL? = nil) throws {
            try Data("x".utf8).write(to: (dir ?? folder).appendingPathComponent(name))
        }
        try put(".clamshell-OLD1.part")
        try put(".clamshell-OLD2.part")
        try put(".clamshell-notapart.txt")          // wrong ending
        try put("clamshell-visible.part")           // wrong start
        try put("received.pdf")                     // a real received file
        try fm.createSymbolicLink(at: folder.appendingPathComponent(".clamshell-LINK.part"), withDestinationURL: elsewhere)
        try fm.createDirectory(at: folder.appendingPathComponent(".clamshell-DIR.part"), withIntermediateDirectories: false)
        let sub = folder.appendingPathComponent("sub", isDirectory: true)
        try fm.createDirectory(at: sub, withIntermediateDirectories: false)
        try put(".clamshell-NESTED.part", in: sub)

        let s = sink()
        XCTAssertTrue(s.begin(id: 1, storedName: "live.bin", size: 3)) // sweeps first, then opens its own part
        let afterBegin = names(in: folder)
        XCTAssertFalse(afterBegin.contains(".clamshell-OLD1.part"))
        XCTAssertFalse(afterBegin.contains(".clamshell-OLD2.part"))
        for kept in [".clamshell-notapart.txt", "clamshell-visible.part", "received.pdf", ".clamshell-LINK.part", ".clamshell-DIR.part", "sub"] {
            XCTAssertTrue(afterBegin.contains(kept), kept)
        }
        XCTAssertTrue(fm.fileExists(atPath: elsewhere.path), "a link is never followed")
        XCTAssertTrue(fm.fileExists(atPath: sub.appendingPathComponent(".clamshell-NESTED.part").path), "only the folder itself is swept")

        // A second sink on the same folder (another connection) must not delete the first one's open part.
        let other = sink()
        XCTAssertEqual(other.removeLeftovers(), 0)
        let livePart = names(in: folder).filter { $0.hasPrefix(".clamshell-") && $0.hasSuffix(".part") && $0 != ".clamshell-LINK.part" && $0 != ".clamshell-DIR.part" }
        XCTAssertEqual(livePart.count, 1, "the open transfer's own part is still there")
        XCTAssertTrue(s.write(id: 1, bytes: Data([1, 2, 3])))
        XCTAssertTrue(s.finish(id: 1))
        XCTAssertTrue(names(in: folder).contains("live.bin"))

        // After the transfer is over its temporary name is no longer protected, but nothing is left of it anyway.
        try put(".clamshell-OLD3.part")
        XCTAssertEqual(s.removeLeftovers(), 1)
    }

    func testRealFreeSpaceCheckWorks() {
        let s = DiskFileSink(folder: folder)
        _ = s.hasRoom(forBytes: 0) // the folder does not exist yet: the check walks up to a folder that does
        XCTAssertFalse(s.hasRoom(forBytes: UInt64.max / 2))
    }
}
