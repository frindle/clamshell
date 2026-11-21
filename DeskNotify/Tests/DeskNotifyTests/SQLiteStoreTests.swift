import XCTest
import DeskNotify
import DeskNotifySQLite

final class SQLiteStoreTests: XCTestCase {
    var dir = ""
    var path: String { dir + "/db" }

    override func setUp() { dir = Fix.tempDir() }
    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    private func seeded() -> FixtureDB {
        let db = FixtureDB(path: path)
        db.addApp(1, Fix.slack)
        db.addApp(2, Fix.mail)
        db.addRecord(1, app: 1, date: 100, bytes: Fix.payload(app: Fix.slack, title: "First", body: "One"))
        db.addRecord(2, app: 2, date: 110, bytes: Fix.payload(app: Fix.mail, title: "Second", subtitle: "Sub", body: "Two", thread: "t"))
        db.addRecord(3, app: 1, date: 120, bytes: Fix.payload(app: Fix.slack, title: "Third", body: "Three"))
        return db
    }

    func testHead() throws {
        _ = seeded()
        let h = try SQLiteNotificationStore(path: path).head()
        XCTAssertEqual(h, StoreHead(maxRec: 3, maxDate: 120))
    }

    func testFetchAfterRecAndDate() throws {
        _ = seeded()
        let store = SQLiteNotificationStore(path: path)
        XCTAssertEqual(try store.fetch(afterRec: 1, afterDate: 1000).map { $0.recId }, [2, 3])
        XCTAssertEqual(try store.fetch(afterRec: 99, afterDate: 105).map { $0.recId }, [2, 3])
        XCTAssertEqual(try store.fetch(afterRec: 3, afterDate: 120), [])
        let row = try store.fetch(afterRec: 1, afterDate: 1000)[0]
        XCTAssertEqual(row.appIdentifier, Fix.mail)
        XCTAssertEqual(row.date, 110)
        XCTAssertEqual(row.data, Fix.payload(app: Fix.mail, title: "Second", subtitle: "Sub", body: "Two", thread: "t"))
    }

    func testReaderOverRealTables() throws {
        let db = seeded()
        let reader = NotificationStoreReader(store: SQLiteNotificationStore(path: path), storage: MemoryCursorStorage())
        XCTAssertEqual(reader.poll(now: 0), [])
        db.addRecord(4, app: 2, date: 130, bytes: Fix.payload(app: Fix.mail, title: "Fourth", body: "Four"))
        let got = reader.poll(now: 1)
        XCTAssertEqual(got.map { $0.title }, ["Fourth"])
        XCTAssertEqual(got.first?.bundleId, Fix.mail)
    }

    func testMissingFile() {
        XCTAssertThrowsError(try SQLiteNotificationStore(path: dir + "/none").head()) {
            XCTAssertEqual($0 as? StoreError, .missing)
        }
        XCTAssertThrowsError(try SQLiteNotificationStore(path: dir + "/none").identity()) {
            XCTAssertEqual($0 as? StoreError, .missing)
        }
    }

    func testNotADatabase() throws {
        try String(repeating: "this is not a database file. ", count: 20).write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try SQLiteNotificationStore(path: path).head()) {
            XCTAssertEqual($0 as? StoreError, .corrupt)
        }
    }

    func testEmptyDatabaseIsASchemaError() throws {
        FileManager.default.createFile(atPath: path, contents: Data())
        XCTAssertThrowsError(try SQLiteNotificationStore(path: path).fetch(afterRec: 0, afterDate: 0)) {
            guard case .schema? = $0 as? StoreError else { return XCTFail("expected schema error, got \($0)") }
        }
    }

    func testMissingDataColumnIsASchemaError() {
        let db = FixtureDB(path: path, recordColumns: "rec_id INTEGER PRIMARY KEY, app_id INTEGER, delivered_date REAL")
        db.exec("INSERT INTO record (rec_id, app_id, delivered_date) VALUES (1, 1, 5)")
        XCTAssertThrowsError(try SQLiteNotificationStore(path: path).head()) {
            XCTAssertEqual($0 as? StoreError, .schema("record.data"))
        }
    }

    func testRequestDateIsUsedWhenThereIsNoDeliveredDate() throws {
        let db = FixtureDB(path: path, recordColumns: "rec_id INTEGER PRIMARY KEY, app_id INTEGER, data BLOB, request_date REAL")
        db.addApp(1, Fix.slack)
        let hex = Fix.payload(app: Fix.slack, title: "Old schema").map { String(format: "%02x", $0) }.joined()
        db.exec("INSERT INTO record (rec_id, app_id, data, request_date) VALUES (1, 1, x'\(hex)', 50)")
        let store = SQLiteNotificationStore(path: path)
        XCTAssertEqual(try store.head(), StoreHead(maxRec: 1, maxDate: 50))
        XCTAssertEqual(try store.fetch(afterRec: 0, afterDate: 0).first?.date, 50)
    }

    func testNoDateColumnAndNoAppTable() throws {
        let db = FixtureDB(path: path, recordColumns: "rec_id INTEGER PRIMARY KEY, data BLOB", withAppTable: false)
        let hex = Fix.payload(app: Fix.slack, title: "Bare").map { String(format: "%02x", $0) }.joined()
        db.exec("INSERT INTO record (rec_id, data) VALUES (1, x'\(hex)')")
        db.exec("INSERT INTO record (rec_id, data) VALUES (2, x'\(hex)')")
        let store = SQLiteNotificationStore(path: path)
        let rows = try store.fetch(afterRec: 1, afterDate: 0)
        XCTAssertEqual(rows.map { $0.recId }, [2])
        XCTAssertNil(rows[0].date)
        XCTAssertNil(rows[0].appIdentifier)
        XCTAssertEqual(RecordDecoder.decode(rows[0])?.title, "Bare")
    }

    func testReplacedFileIsReadWithoutRestart() throws {
        _ = seeded()
        let store = SQLiteNotificationStore(path: path)
        XCTAssertEqual(try store.head().maxRec, 3)
        try FileManager.default.removeItem(atPath: path)
        let db = FixtureDB(path: path)
        db.addApp(1, Fix.slack)
        db.addRecord(1, app: 1, date: 500, bytes: Fix.payload(app: Fix.slack, title: "New file"))
        XCTAssertEqual(try store.head(), StoreHead(maxRec: 1, maxDate: 500))
    }

    func testLockedDatabaseFailsClosed() throws {
        let db = seeded()
        db.exec("BEGIN EXCLUSIVE")
        defer { db.exec("ROLLBACK") }
        XCTAssertThrowsError(try SQLiteNotificationStore(path: path).fetch(afterRec: 0, afterDate: 0)) {
            XCTAssertEqual($0 as? StoreError, .locked)
        }
        let reader = NotificationStoreReader(store: SQLiteNotificationStore(path: path), storage: MemoryCursorStorage(text: "v1|0|0|1"))
        XCTAssertEqual(reader.poll(now: 0), [])
        XCTAssertGreaterThan(reader.nextAttempt, 0)
    }
}
