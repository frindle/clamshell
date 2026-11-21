/// Which window ids a side has been told about on this connection. The host uses it to refuse input and stream
/// requests for ids it never announced, and the operator uses it to refuse a repeated WINDOW_ADDED.
/// Ids are not reused: once an id has been added it can never be added again, even after it closed.
public struct WindowRegistry {
    private var added = Set<UInt32>()
    private var open = Set<UInt32>()
    private var listed = Set<UInt32>()
    public init() {}

    /// WINDOW_ADDED. False (and nothing changes) for id 0 or an id that was ever added: a protocol error for the caller to act on.
    public mutating func announce(_ id: UInt32) -> Bool {
        guard id != 0, !added.contains(id) else { return false }
        added.insert(id); open.insert(id)
        return true
    }
    /// WINDOW_LIST_RESPONSE ids; listing the same id again is normal.
    public mutating func listed(_ ids: [UInt32]) { listed.formUnion(ids) }
    /// WINDOW_CLOSED. The id stays used.
    public mutating func close(_ id: UInt32) { open.remove(id); listed.remove(id) }
    /// Whether input, a stream start or a handoff message may refer to this id.
    public func accepts(_ id: UInt32) -> Bool { open.contains(id) || listed.contains(id) }
}
