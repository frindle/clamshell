import Foundation

/// Decides when a Screen Sharing (screensharingd) connection that the browser
/// has let go of should be kept open ("parked") and when it should finally be
/// closed.
///
/// macOS locks the screen again when the Screen Sharing viewer that unlocked a
/// locked Mac disconnects. The browser fallback used to drop its VNC session
/// the moment the Mac unlocked, so every remote unlock ended in a re-lock.
/// The bridge now parks the TCP leg instead and closes it only when this
/// policy says so. No sockets here, so it is unit-tested directly.
struct VNCParkPolicy {
    enum CloseReason: Equatable {
        case hostLocked   // the screen locked again
        case noViewers    // nobody is connected any more (after the grace period)
        case maxHold      // held for too long
    }

    /// How long with no viewer connected before a parked connection closes;
    /// long enough that a page reload does not re-lock the Mac.
    var gracePeriod: TimeInterval = 30
    /// Longest a connection may stay parked.
    var maxHold: TimeInterval = 12 * 3600

    private var noViewerSince: TimeInterval?

    /// Park on browser close only if the host is unlocked and the screensharingd
    /// side is still alive. While locked there is nothing to preserve.
    static func shouldPark(hostLocked: Bool, upstreamAlive: Bool) -> Bool {
        !hostLocked && upstreamAlive
    }

    /// Forget the no-viewer clock (call when a connection is parked or all are closed).
    mutating func reset() { noViewerSince = nil }

    /// Why a connection parked at `parkedAt` should close now, or nil to keep it.
    mutating func closeReason(parkedAt: TimeInterval, now: TimeInterval,
                              hostLocked: Bool, viewerConnected: Bool) -> CloseReason? {
        if hostLocked { return .hostLocked }
        if now - parkedAt >= maxHold { return .maxHold }
        if viewerConnected {
            noViewerSince = nil
            return nil
        }
        let since = noViewerSince ?? now
        noViewerSince = since
        return now - since >= gracePeriod ? .noViewers : nil
    }
}
