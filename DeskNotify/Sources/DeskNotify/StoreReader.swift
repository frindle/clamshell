/// Finds new rows in the notification store.
/// Fails closed: on any error it returns nothing, logs, and waits longer before the next try.
/// Logs hold metadata only, never notification text.
public final class NotificationStoreReader {
    private let store: NotificationStore
    private let storage: CursorStorage
    private let log: LogSink
    public private(set) var cursor: StoreCursor?
    /// Earliest time the next poll may touch the store.
    public private(set) var nextAttempt: Double = 0
    public private(set) var failures = 0
    private var lastFailureLabel: String?
    private var seenOrder: [String] = []
    private var seen: Set<String> = []
    private let maxSeen = 1024

    public init(store: NotificationStore, storage: CursorStorage, log: @escaping LogSink = { _ in }) {
        self.store = store; self.storage = storage; self.log = log
        if let t = storage.load() { cursor = StoreCursor.decode(t) }
    }

    /// Call on a timer (0.2 s to 1 s). `now` is any steady clock in seconds.
    public func poll(now: Double) -> [NotificationRecord] {
        guard now >= nextAttempt else { return [] }
        do {
            let ident = try store.identity()
            guard var c = cursor else {
                // First run: start at the head. History is not replayed.
                let h = try store.head()
                cursor = StoreCursor(lastRec: h.maxRec, lastDate: h.maxDate, identity: ident)
                persist()
                log("store: first run, starting after row \(h.maxRec)")
                succeeded()
                return []
            }
            let rows: [RawStoreRow]
            if c.identity != ident {
                // The file was replaced. Row ids start over, so only the date decides what is new.
                let h = try store.head()
                rows = try store.fetch(afterRec: Int64.max, afterDate: c.lastDate)
                c.lastRec = h.maxRec
                c.identity = ident
                log("store: file replaced, now at row \(h.maxRec)")
            } else {
                rows = try store.fetch(afterRec: c.lastRec, afterDate: c.lastDate)
            }
            var out: [NotificationRecord] = []
            var undecodable = 0
            for row in rows {
                c.lastRec = max(c.lastRec, row.recId)
                if let d = row.date, d > c.lastDate { c.lastDate = d }
                guard remember("\(row.recId)@\(row.date ?? 0)") else { continue }
                if let rec = RecordDecoder.decode(row) { out.append(rec) } else { undecodable += 1 }
            }
            if undecodable > 0 { log("store: skipped \(undecodable) row(s) with an unreadable payload") }
            if c != cursor { cursor = c; persist() }
            succeeded()
            return out
        } catch let e as StoreError {
            failed(e.label, now: now)
        } catch {
            failed("other", now: now)
        }
        return []
    }

    private func remember(_ key: String) -> Bool {
        guard seen.insert(key).inserted else { return false }
        seenOrder.append(key)
        if seenOrder.count > maxSeen { seen.remove(seenOrder.removeFirst()) }
        return true
    }

    private func persist() { if let c = cursor { storage.save(c.encoded()) } }

    private func succeeded() {
        if failures > 0 { log("store: readable again after \(failures) failed poll(s)") }
        failures = 0; lastFailureLabel = nil; nextAttempt = 0
    }

    private func failed(_ label: String, now: Double) {
        failures += 1
        // 1, 2, 4 ... 60 seconds.
        let delay = min(60.0, Double(1 << min(failures - 1, 6)))
        nextAttempt = now + delay
        if label != lastFailureLabel || failures % 20 == 0 {
            log("store: read failed (\(label)), failure \(failures), retry in \(Int(delay)) s")
        }
        lastFailureLabel = label
    }
}
