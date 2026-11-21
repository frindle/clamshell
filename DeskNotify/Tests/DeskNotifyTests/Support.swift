import Foundation
import DeskNotify
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// All text in these tests is invented.
enum Fix {
    static let slack = "com.example.chatapp"
    static let mail = "com.example.mailapp"
    static let other = "com.example.notes"

    static func payload(app: String?, title: String = "", subtitle: String = "", body: String = "", thread: String = "") -> [UInt8] {
        var req: [String: Any] = [:]
        if !title.isEmpty { req["titl"] = title }
        if !subtitle.isEmpty { req["subt"] = subtitle }
        if !body.isEmpty { req["body"] = body }
        if !thread.isEmpty { req["thre"] = thread }
        var top: [String: Any] = ["req": req]
        if let app = app { top["app"] = app }
        let data = try! PropertyListSerialization.data(fromPropertyList: top, format: .binary, options: 0)
        return [UInt8](data)
    }

    static func row(_ rec: Int64, app: String = slack, date: Double?, title: String = "Hello", body: String = "A message") -> RawStoreRow {
        RawStoreRow(recId: rec, appIdentifier: app, date: date, data: payload(app: app, title: title, body: body))
    }

    static func tempDir() -> String {
        let p = NSTemporaryDirectory() + "desknotify-" + UUID().uuidString
        try! FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }
}

/// A store in memory that behaves like the SQL one.
final class FakeStore: NotificationStore {
    var rows: [RawStoreRow] = []
    var ident = "file-1"
    var error: StoreError?
    func identity() throws -> String { if let e = error { throw e }; return ident }
    func head() throws -> StoreHead {
        if let e = error { throw e }
        return StoreHead(maxRec: rows.map { $0.recId }.max() ?? 0, maxDate: rows.compactMap { $0.date }.max() ?? 0)
    }
    func fetch(afterRec: Int64, afterDate: Double) throws -> [RawStoreRow] {
        if let e = error { throw e }
        return rows.filter { $0.recId > afterRec || ($0.date ?? -1) > afterDate }.sorted { $0.recId < $1.recId }
    }
}

final class Logs {
    var lines: [String] = []
    var sink: LogSink { { [self] in lines.append($0) } }
}

/// A database with the same tables as the real notification store: app, record, delivered, displayed, requests.
final class FixtureDB {
    let path: String
    private var handle: OpaquePointer?

    init(path: String, recordColumns: String = FixtureDB.realRecordColumns, withAppTable: Bool = true) {
        self.path = path
        precondition(sqlite3_open(path, &handle) == SQLITE_OK)
        if withAppTable { exec("CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier TEXT, badge INTEGER)") }
        exec("CREATE TABLE record (\(recordColumns))")
        for t in ["delivered", "displayed", "requests"] { exec("CREATE TABLE \(t) (app_id INTEGER, rec_id INTEGER)") }
    }

    deinit { sqlite3_close(handle) }

    static let realRecordColumns =
        "rec_id INTEGER PRIMARY KEY, app_id INTEGER, uuid BLOB, data BLOB, request_date REAL, request_last_date REAL, delivered_date REAL"

    func exec(_ sql: String) {
        precondition(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK, "sql failed: \(sql)")
    }

    func addApp(_ id: Int, _ bundle: String) { exec("INSERT INTO app (app_id, identifier, badge) VALUES (\(id), '\(bundle)', 0)") }

    func addRecord(_ rec: Int, app: Int = 1, date: Double, bytes: [UInt8]) {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        exec("INSERT INTO record (rec_id, app_id, uuid, data, request_date, request_last_date, delivered_date) VALUES (\(rec), \(app), x'00', x'\(hex)', \(date), \(date), \(date))")
    }
}
