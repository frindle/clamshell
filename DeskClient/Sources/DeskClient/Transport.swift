/// What the control connection needs from the outside: a link to the host and a clock. Both are protocols so a
/// test can stand in a fake host and a hand-turned clock.

/// Callbacks from one link. The link calls them on the same queue as everything else in the package.
/// After `closed`, the link calls nothing more.
public struct DeskLinkEvents {
    /// The link is up. The device authentication and the SECURE envelope are done, and the host's capability
    /// bits are known. The link must report the host's `appHost` bit (`DeskCapability.appHost`) here.
    public var opened: (_ peerCapabilities: UInt32) -> Void
    /// Bytes from the host, in any chunking. They are v1 frames; the package parses them.
    public var received: ([UInt8]) -> Void
    /// The link ended or never opened. `reason` is for the log, never a secret.
    public var closed: (_ reason: String?) -> Void

    public init(opened: @escaping (UInt32) -> Void, received: @escaping ([UInt8]) -> Void, closed: @escaping (String?) -> Void) {
        self.opened = opened; self.received = received; self.closed = closed
    }
}

public protocol DeskLink: AnyObject {
    /// Sends bytes that are already framed.
    func send(_ bytes: [UInt8])
    func close()
}

public protocol DeskLinkFactory: AnyObject {
    /// Starts a link to the host. May call `events.closed` before it returns, for an attempt that fails at once.
    func connect(hostId: String, events: DeskLinkEvents) -> DeskLink
}

public protocol DeskTimer: AnyObject {
    func cancel()
}

public protocol DeskScheduler: AnyObject {
    /// Seconds on a monotonic clock.
    var now: Double { get }
    func schedule(after seconds: Double, _ work: @escaping () -> Void) -> DeskTimer
}
