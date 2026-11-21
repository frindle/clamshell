import DeskProtocol

public enum ConnectionState: Equatable {
    /// Not started, or stopped by the caller.
    case idle
    case connecting(attempt: Int)
    case ready
    /// The link was lost. The next attempt starts in `retryIn` seconds. Windows are frozen.
    case waiting(attempt: Int, retryIn: Double)
    /// The Mac is asleep. No attempts are made until it wakes.
    case asleep
    /// A permanent failure: retrying would not help (for example, the host cannot host apps).
    case failed(String)
}

public enum WindowChange: Equatable {
    /// The host moved the window. The native window stays where the user put it; this is for children and for
    /// a policy that wants to follow the host.
    case moved
    /// The host sent a size. See `HostResizeAnswer`: adopt the size, or stop stretching, or keep stretching.
    case resized(HostResizeAnswer)
    case retitled
    /// A CHILD_WINDOW arrived: its parent, offset or kind changed.
    case placed
    /// The connection dropped. Keep the native window and its last frame; show that the host is unreachable.
    case frozen
    /// The host announced the window again after a reconnect. Show live frames again.
    case restored
    /// The host did not answer a resize request in time. Show the host's size again.
    case resizeTimedOut
}

/// What the package tells its owner. Every event names the host.
public enum DeskEvent: Equatable {
    case state(hostId: String, ConnectionState)
    case apps(hostId: String, [AppInfo])
    case launchResult(hostId: String, requestId: UInt32, status: UInt8, appId: UInt32)
    case windowOpened(hostId: String, RemoteWindow)
    case windowChanged(hostId: String, RemoteWindow, WindowChange)
    case windowClosed(hostId: String, localId: UInt64)
    /// A message the package does not act on: video, audio, cursor, menu, clipboard, file, badge, notify, handoff.
    /// Video and cursor messages are passed only for windows that are open.
    case message(hostId: String, DeskMessage)
}

public struct DeskConnectionConfig {
    public var backoff = Backoff()
    public var resize = ResizeConfig()
    /// With no bytes from the host for this long, the operator asks for the app list, which the host must answer.
    public var heartbeatInterval: Double = 2
    /// With no bytes at all for this long, the link counts as dead. A silent drop is found within this time.
    public var silenceLimit: Double = 7
    /// A link that stays up this long is healthy: the backoff starts over.
    public var stableAfter: Double = 5
    /// After a reconnect, frozen windows the host has not announced again by now are closed.
    public var restoreGrace: Double = 20
    /// Frozen windows are closed after the host has been unreachable this long.
    public var offlineLimit: Double = 600

    public init() {}
}
