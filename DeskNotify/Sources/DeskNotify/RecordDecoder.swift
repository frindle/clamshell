import Foundation

/// Turns the `data` blob of a `record` row into text fields.
/// The blob is a property list. The request sits under `req`: `titl`, `subt`, `body`, `thre`.
/// The posting app's bundle id is under `app`. Anything else in the blob is ignored.
public enum RecordDecoder {
    /// nil when the blob is not a property list, has no app, or has no text at all.
    public static func decode(_ row: RawStoreRow) -> NotificationRecord? {
        guard !row.data.isEmpty,
              let obj = try? PropertyListSerialization.propertyList(from: Data(row.data), options: [], format: nil),
              let top = obj as? [String: Any] else { return nil }
        let req = top["req"] as? [String: Any] ?? [:]
        func text(_ key: String) -> String { req[key] as? String ?? "" }
        var bundle = ""
        if let b = top["app"] as? String, !b.isEmpty { bundle = b } else if let b = row.appIdentifier { bundle = b }
        guard !bundle.isEmpty else { return nil }
        let title = text("titl"), sub = text("subt"), body = text("body")
        guard !(title.isEmpty && sub.isEmpty && body.isEmpty) else { return nil }
        return NotificationRecord(recId: row.recId, bundleId: bundle, title: title, subtitle: sub, body: body,
                                  date: row.date, thread: text("thre"))
    }
}
