import Foundation

/// Where the reader stopped. Saved between runs.
public struct StoreCursor: Equatable {
    public var lastRec: Int64
    public var lastDate: Double
    public var identity: String

    public init(lastRec: Int64, lastDate: Double, identity: String) {
        self.lastRec = lastRec; self.lastDate = lastDate; self.identity = identity
    }

    public func encoded() -> String { "v1|\(lastRec)|\(lastDate)|\(identity)" }

    public static func decode(_ s: String) -> StoreCursor? {
        let parts = s.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "v1", let r = Int64(parts[1]), let d = Double(parts[2]), d.isFinite else { return nil }
        return StoreCursor(lastRec: r, lastDate: d, identity: String(parts[3]))
    }
}

public protocol CursorStorage {
    func load() -> String?
    func save(_ text: String)
}

/// Keeps the cursor in one small file. A failed write is ignored; the reader then starts from the head next run.
public struct FileCursorStorage: CursorStorage {
    public let path: String
    public init(path: String) { self.path = path }
    public func load() -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
    public func save(_ text: String) { try? text.write(toFile: path, atomically: true, encoding: .utf8) }
}

public final class MemoryCursorStorage: CursorStorage {
    public private(set) var text: String?
    public init(text: String? = nil) { self.text = text }
    public func load() -> String? { text }
    public func save(_ text: String) { self.text = text }
}
