import DeskNotify
import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// Reads the notification store (`record` and `app` tables) read-only.
/// The file is opened afresh on each call, so a replaced file is picked up at once.
/// The reader never writes, and it adapts to the columns it finds:
///  - needs `record.rec_id` and `record.data`
///  - date column: `delivered_date`, else `request_date`, else none
///  - bundle id: from `app.identifier` when `record.app_id` and the `app` table exist
public struct SQLiteNotificationStore: NotificationStore {
    public let path: String

    public init(path: String) { self.path = path }

    public func identity() throws -> String {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            if let n = attrs[.systemFileNumber] { return "\(n)" }
            return "?"
        } catch {
            throw StoreError.missing
        }
    }

    public func head() throws -> StoreHead {
        let conn = try SQLiteConn(path: path)
        let schema = try conn.schema()
        var head = StoreHead(maxRec: 0, maxDate: 0)
        let sql = "SELECT coalesce(max(rec_id), 0), coalesce(max(\(schema.dateColumn)), 0) FROM record r"
        try conn.run(sql, [], []) { st in
            head = StoreHead(maxRec: sqlite3_column_int64(st, 0), maxDate: sqlite3_column_double(st, 1))
        }
        return head
    }

    public func fetch(afterRec: Int64, afterDate: Double) throws -> [RawStoreRow] {
        let conn = try SQLiteConn(path: path)
        let schema = try conn.schema()
        let appSelect = schema.hasAppJoin ? "a.identifier" : "NULL"
        let join = schema.hasAppJoin ? "LEFT JOIN app a ON a.app_id = r.app_id" : ""
        let sql = """
            SELECT r.rec_id, \(appSelect), \(schema.dateColumn), r.data FROM record r \(join) \
            WHERE r.rec_id > ?1 OR \(schema.dateColumn) > ?2 ORDER BY r.rec_id
            """
        var rows: [RawStoreRow] = []
        try conn.run(sql, [afterRec], [afterDate]) { st in
            let app: String? = sqlite3_column_type(st, 1) == SQLITE_NULL ? nil : text(st, 1)
            let date: Double? = sqlite3_column_type(st, 2) == SQLITE_NULL ? nil : sqlite3_column_double(st, 2)
            let n = Int(sqlite3_column_bytes(st, 3))
            var bytes: [UInt8] = []
            if n > 0, let p = sqlite3_column_blob(st, 3) {
                bytes = Array(UnsafeRawBufferPointer(start: p, count: n))
            }
            rows.append(RawStoreRow(recId: sqlite3_column_int64(st, 0), appIdentifier: app, date: date, data: bytes))
        }
        return rows
    }
}

private func text(_ st: OpaquePointer, _ i: Int32) -> String {
    guard let c = sqlite3_column_text(st, i) else { return "" }
    return String(cString: c)
}

func mapSQLiteError(_ rc: Int32) -> StoreError {
    switch rc {
    case SQLITE_BUSY, SQLITE_LOCKED: return .locked
    case SQLITE_PERM, SQLITE_AUTH, SQLITE_CANTOPEN: return .noAccess
    case SQLITE_CORRUPT, SQLITE_NOTADB: return .corrupt
    default: return .other("sqlite \(rc)")
    }
}

struct StoreSchema {
    var dateColumn: String
    var hasAppJoin: Bool
}

private final class SQLiteConn {
    var handle: OpaquePointer?

    init(path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { throw StoreError.missing }
        var h: OpaquePointer?
        let rc = sqlite3_open_v2(path, &h, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let opened = h else {
            sqlite3_close(h)
            throw mapSQLiteError(rc)
        }
        handle = opened
        sqlite3_busy_timeout(opened, 250)
    }

    deinit { sqlite3_close(handle) }

    /// Runs one statement. `ints` bind first, then `doubles`, numbered from 1.
    func run(_ sql: String, _ ints: [Int64], _ doubles: [Double], _ each: (OpaquePointer) -> Void) throws {
        var st: OpaquePointer?
        let prep = sqlite3_prepare_v2(handle, sql, -1, &st, nil)
        guard prep == SQLITE_OK, let stmt = st else {
            sqlite3_finalize(st)
            throw mapSQLiteError(prep)
        }
        defer { sqlite3_finalize(stmt) }
        var idx: Int32 = 1
        for v in ints { sqlite3_bind_int64(stmt, idx, v); idx += 1 }
        for v in doubles { sqlite3_bind_double(stmt, idx, v); idx += 1 }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { each(stmt) } else if rc == SQLITE_DONE { return } else { throw mapSQLiteError(rc) }
        }
    }

    func columns(of table: String) throws -> Set<String> {
        var cols: Set<String> = []
        // The table name is a fixed literal chosen by this file, never input.
        try run("PRAGMA table_info(\(table))", [], []) { cols.insert(text($0, 1)) }
        return cols
    }

    func schema() throws -> StoreSchema {
        let rec = try columns(of: "record")
        guard !rec.isEmpty else { throw StoreError.schema("no record table") }
        guard rec.contains("rec_id") else { throw StoreError.schema("record.rec_id") }
        guard rec.contains("data") else { throw StoreError.schema("record.data") }
        let date = rec.contains("delivered_date") ? "r.delivered_date" : (rec.contains("request_date") ? "r.request_date" : "NULL")
        var join = false
        if rec.contains("app_id") {
            let app = try columns(of: "app")
            join = app.contains("app_id") && app.contains("identifier")
        }
        return StoreSchema(dateColumn: date, hasAppJoin: join)
    }
}
