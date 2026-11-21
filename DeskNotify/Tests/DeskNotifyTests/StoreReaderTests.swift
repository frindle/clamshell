import XCTest
@testable import DeskNotify

final class StoreReaderTests: XCTestCase {
    func testFirstRunStartsAtHeadWithoutReplay() {
        let store = FakeStore()
        store.rows = [Fix.row(1, date: 100), Fix.row(2, date: 110)]
        let r = NotificationStoreReader(store: store, storage: MemoryCursorStorage())
        XCTAssertEqual(r.poll(now: 0), [])
        XCTAssertEqual(r.cursor?.lastRec, 2)
    }

    func testNewRowsAreFoundOnce() {
        let store = FakeStore()
        store.rows = [Fix.row(1, date: 100)]
        let r = NotificationStoreReader(store: store, storage: MemoryCursorStorage())
        _ = r.poll(now: 0)
        store.rows.append(Fix.row(2, date: 120, title: "Lunch", body: "Noon?"))
        let got = r.poll(now: 1)
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got.first?.title, "Lunch")
        XCTAssertEqual(got.first?.body, "Noon?")
        XCTAssertEqual(got.first?.bundleId, Fix.slack)
        XCTAssertEqual(r.poll(now: 2), [])
    }

    func testCursorRestartSkipsWhatWasSeen() {
        let store = FakeStore()
        store.rows = [Fix.row(1, date: 100)]
        let storage = MemoryCursorStorage()
        let first = NotificationStoreReader(store: store, storage: storage)
        _ = first.poll(now: 0)
        store.rows.append(Fix.row(2, date: 120, title: "One"))
        XCTAssertEqual(first.poll(now: 1).count, 1)

        // The agent restarts. Row 3 arrives while it is down.
        store.rows.append(Fix.row(3, date: 130, title: "Two"))
        let second = NotificationStoreReader(store: store, storage: storage)
        let got = second.poll(now: 0)
        XCTAssertEqual(got.map { $0.title }, ["Two"])
    }

    func testBadSavedCursorIsTreatedAsFirstRun() {
        let store = FakeStore()
        store.rows = [Fix.row(1, date: 100)]
        let r = NotificationStoreReader(store: store, storage: MemoryCursorStorage(text: "garbage"))
        XCTAssertEqual(r.poll(now: 0), [])
        XCTAssertEqual(r.cursor?.lastRec, 1)
    }

    func testCursorTextRoundTrips() {
        let c = StoreCursor(lastRec: 42, lastDate: 785_000_123.456, identity: "a|b")
        XCTAssertEqual(StoreCursor.decode(c.encoded()), c)
        XCTAssertNil(StoreCursor.decode("v2|1|2|x"))
        XCTAssertNil(StoreCursor.decode("v1|x|2|x"))
    }

    func testFileCursorStorageRoundTrips() {
        let dir = Fix.tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let s = FileCursorStorage(path: dir + "/cursor")
        XCTAssertNil(s.load())
        s.save("v1|1|2|x")
        XCTAssertEqual(s.load(), "v1|1|2|x")
    }

    func testCorruptPayloadIsSkippedAndCursorAdvances() {
        let store = FakeStore()
        let r = NotificationStoreReader(store: store, storage: MemoryCursorStorage())
        _ = r.poll(now: 0)
        let logs = Logs()
        let r2 = NotificationStoreReader(store: store, storage: MemoryCursorStorage(text: r.cursor?.encoded()), log: logs.sink)
        store.rows = [
            RawStoreRow(recId: 1, appIdentifier: Fix.slack, date: 10, data: [0xde, 0xad, 0xbe, 0xef]),
            RawStoreRow(recId: 2, appIdentifier: Fix.slack, date: 11, data: []),
            RawStoreRow(recId: 3, appIdentifier: nil, date: 12, data: Fix.payload(app: nil, title: "No app")),
            Fix.row(4, date: 13, title: "Good"),
        ]
        let got = r2.poll(now: 1)
        XCTAssertEqual(got.map { $0.title }, ["Good"])
        XCTAssertEqual(r2.cursor?.lastRec, 4)
        XCTAssertTrue(logs.lines.contains { $0.contains("3 row(s)") })
        XCTAssertFalse(logs.lines.joined().contains("Good"))
    }

    func testBundleIdFallsBackToAppTable() {
        let store = FakeStore()
        let r = NotificationStoreReader(store: store, storage: MemoryCursorStorage(text: "v1|0|0|file-1"))
        store.rows = [RawStoreRow(recId: 1, appIdentifier: Fix.mail, date: 5, data: Fix.payload(app: nil, title: "Hi"))]
        XCTAssertEqual(r.poll(now: 0).first?.bundleId, Fix.mail)
    }

    func testRotationDoesNotReplayAndFindsNewRows() {
        let store = FakeStore()
        store.rows = [Fix.row(1, date: 100), Fix.row(2, date: 110), Fix.row(3, date: 120)]
        let logs = Logs()
        let r = NotificationStoreReader(store: store, storage: MemoryCursorStorage(), log: logs.sink)
        _ = r.poll(now: 0)

        // The store is replaced. Row ids start over; two old rows are carried into the new file.
        store.ident = "file-2"
        store.rows = [Fix.row(1, date: 100, title: "Old"), Fix.row(2, date: 115, title: "Older"), Fix.row(3, date: 130, title: "Fresh")]
        let got = r.poll(now: 1)
        XCTAssertEqual(got.map { $0.title }, ["Fresh"])
        XCTAssertEqual(r.cursor?.identity, "file-2")
        XCTAssertTrue(logs.lines.contains { $0.contains("replaced") })

        store.rows.append(Fix.row(4, date: 140, title: "Next"))
        XCTAssertEqual(r.poll(now: 2).map { $0.title }, ["Next"])
        XCTAssertEqual(r.poll(now: 3), [])
    }

    func testRowIdsReusedAfterHistoryClearAreFoundByDate() {
        let store = FakeStore()
        store.rows = [Fix.row(1, date: 100), Fix.row(2, date: 110), Fix.row(3, date: 120)]
        let r = NotificationStoreReader(store: store, storage: MemoryCursorStorage())
        _ = r.poll(now: 0)
        // History cleared in place: same file, ids start over.
        store.rows = [Fix.row(1, date: 200, title: "After clear")]
        XCTAssertEqual(r.poll(now: 1).map { $0.title }, ["After clear"])
    }

    func testFailureReturnsNothingBacksOffAndRecovers() {
        let store = FakeStore()
        store.rows = [Fix.row(1, date: 100)]
        let logs = Logs()
        let r = NotificationStoreReader(store: store, storage: MemoryCursorStorage(), log: logs.sink)
        _ = r.poll(now: 0)
        store.rows.append(Fix.row(2, date: 110, title: "Late"))

        store.error = .locked
        XCTAssertEqual(r.poll(now: 10), [])
        XCTAssertEqual(r.nextAttempt, 11)
        XCTAssertEqual(r.poll(now: 10.5), [])          // too early; the store is not touched
        XCTAssertEqual(r.poll(now: 11), [])
        XCTAssertEqual(r.nextAttempt, 13)
        XCTAssertEqual(logs.lines.filter { $0.contains("locked") }.count, 1)   // same failure is logged once

        store.error = nil
        XCTAssertEqual(r.poll(now: 13).map { $0.title }, ["Late"])
        XCTAssertEqual(r.failures, 0)
        XCTAssertTrue(logs.lines.contains { $0.contains("readable again") })
    }

    func testBackoffIsCapped() {
        let store = FakeStore()
        store.error = .missing
        let r = NotificationStoreReader(store: store, storage: MemoryCursorStorage())
        var now = 0.0
        var delay = 0.0
        for _ in 0..<20 {
            _ = r.poll(now: now)
            delay = r.nextAttempt - now
            XCTAssertLessThanOrEqual(delay, 60)
            now = r.nextAttempt
        }
        XCTAssertEqual(delay, 60)
    }

    func testEveryStoreErrorFailsClosed() {
        for e in [StoreError.missing, .noAccess, .locked, .corrupt, .schema("x"), .other("y")] {
            let store = FakeStore()
            store.rows = [Fix.row(1, date: 1)]
            store.error = e
            let r = NotificationStoreReader(store: store, storage: MemoryCursorStorage(text: "v1|0|0|file-1"))
            XCTAssertEqual(r.poll(now: 0), [], e.label)
            XCTAssertNotEqual(r.nextAttempt, 0)
        }
    }

    func testDecoderReadsAllFields() {
        let row = RawStoreRow(recId: 9, appIdentifier: nil, date: 77,
                              data: Fix.payload(app: Fix.mail, title: "T", subtitle: "S", body: "B", thread: "th-1"))
        let rec = RecordDecoder.decode(row)
        XCTAssertEqual(rec, NotificationRecord(recId: 9, bundleId: Fix.mail, title: "T", subtitle: "S", body: "B", date: 77, thread: "th-1"))
    }
}
