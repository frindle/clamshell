import DeskProtocol

/// One hosted app. It outlives any one connection: the app keeps running when an operator drops, and a
/// reconnecting operator finds it again. It knows the app's process, its latest windows and which operators
/// are watching which window stream.
public final class AppSession {
    public let appId: UInt32
    public let bundleId: String
    public private(set) var name: String
    /// −1 when the app is not running.
    public private(set) var pid: Int32 = -1
    public internal(set) var residentMB: UInt32 = 0
    /// Latest look at the app's windows, front to back.
    public internal(set) var windows: [HostWindowSnapshot] = []
    private var streamOwners: [UInt32: Set<String>] = [:]

    init(appId: UInt32, bundleId: String, name: String) {
        self.appId = appId; self.bundleId = bundleId; self.name = name
    }

    public var running: Bool { pid >= 0 }
    public var streamingWindowIds: Set<UInt32> { Set(streamOwners.keys) }

    func started(pid: Int32, name: String) {
        if self.pid != pid { windows = []; streamOwners = [:] }
        self.pid = pid
        if !name.isEmpty { self.name = name }
    }

    func exited() { pid = -1; windows = []; residentMB = 0; streamOwners = [:] }

    /// True if this is the first operator on the window, so the stream must be started.
    func addStreamOwner(_ owner: String, window: UInt32) -> Bool {
        var set = streamOwners[window] ?? []
        let first = set.isEmpty
        set.insert(owner)
        streamOwners[window] = set
        return first
    }

    /// True if that was the last operator on the window, so the stream must be stopped.
    func removeStreamOwner(_ owner: String, window: UInt32) -> Bool {
        guard var set = streamOwners[window], set.remove(owner) != nil else { return false }
        if set.isEmpty { streamOwners[window] = nil; return true }
        streamOwners[window] = set
        return false
    }

    func streamOwners(of window: UInt32) -> Set<String> { streamOwners[window] ?? [] }

    /// Windows this operator was streaming.
    func windowsStreamed(by owner: String) -> [UInt32] { streamOwners.filter { $0.value.contains(owner) }.map { $0.key }.sorted() }

    func info(windowCount: Int) -> AppInfo {
        AppInfo(appId: appId, bundleId: bundleId, name: name, pid: pid,
                windowCount: UInt16(clamping: windowCount), residentMB: residentMB, running: running)
    }
}
