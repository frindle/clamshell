/// One delivered notification, decoded from a store row.
public struct NotificationRecord: Equatable {
    public var recId: Int64
    /// Bundle id of the app that posted it.
    public var bundleId: String
    public var title: String
    public var subtitle: String
    public var body: String
    /// Delivery time in seconds since the Cocoa reference date; nil if the store has no date column.
    public var date: Double?
    /// Thread identifier; empty when none.
    public var thread: String

    public init(recId: Int64, bundleId: String, title: String, subtitle: String, body: String, date: Double?, thread: String) {
        self.recId = recId; self.bundleId = bundleId; self.title = title; self.subtitle = subtitle
        self.body = body; self.date = date; self.thread = thread
    }
}

/// A row as the store gives it, before the payload is decoded.
public struct RawStoreRow: Equatable {
    public var recId: Int64
    /// The app's bundle id from the `app` table, if the join was possible.
    public var appIdentifier: String?
    public var date: Double?
    public var data: [UInt8]

    public init(recId: Int64, appIdentifier: String?, date: Double?, data: [UInt8]) {
        self.recId = recId; self.appIdentifier = appIdentifier; self.date = date; self.data = data
    }
}

/// Highest row id and date now in the store.
public struct StoreHead: Equatable {
    public var maxRec: Int64
    public var maxDate: Double
    public init(maxRec: Int64, maxDate: Double) { self.maxRec = maxRec; self.maxDate = maxDate }
}

/// Why a read failed. Every case means: emit nothing, log, retry later.
public enum StoreError: Error, Equatable {
    /// No database file at the path (or the path is hidden from this process).
    case missing
    /// The file is there but this process may not read it (no Full Disk Access).
    case noAccess
    /// Another process holds a lock.
    case locked
    /// The file is not a readable database.
    case corrupt
    /// A table or column the reader needs is not there.
    case schema(String)
    case other(String)

    public var label: String {
        switch self {
        case .missing: return "missing"
        case .noAccess: return "noAccess"
        case .locked: return "locked"
        case .corrupt: return "corrupt"
        case .schema(let s): return "schema(\(s))"
        case .other(let s): return "other(\(s))"
        }
    }
}

/// Read access to the notification store. The SQLite version lives in DeskNotifySQLite.
public protocol NotificationStore {
    /// Changes when the database file is replaced (rotation).
    func identity() throws -> String
    func head() throws -> StoreHead
    /// Rows with `rec_id > afterRec` or `date > afterDate`, ordered by row id.
    func fetch(afterRec: Int64, afterDate: Double) throws -> [RawStoreRow]
}

public typealias LogSink = (String) -> Void
