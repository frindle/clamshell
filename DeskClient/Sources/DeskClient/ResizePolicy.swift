/// How a local resize reaches the host. The user drags the edge of the native window. The operator sends the
/// new size and keeps showing the last frame, stretched to fit, until the host answers with WINDOW_RESIZED.
/// A resize request is advisory: the host may answer with another size (a minimum, a maximum), and then the
/// operator adopts the host's size.

public struct ResizeConfig: Equatable {
    /// Least time between two requests for one window. A drag makes many sizes; the newest one is sent last.
    public var minInterval: Double
    /// How long the operator waits for the host before it gives up and shows the host's size again.
    public var timeout: Double
    /// Sizes within this many points count as equal.
    public var tolerance: Double
    public var minSize: DeskSize
    public var maxSize: DeskSize

    public init(minInterval: Double = 0.04, timeout: Double = 1.5, tolerance: Double = 1,
                minSize: DeskSize = DeskSize(width: 32, height: 32),
                maxSize: DeskSize = DeskSize(width: 100_000, height: 100_000)) {
        self.minInterval = minInterval; self.timeout = timeout; self.tolerance = tolerance
        self.minSize = minSize; self.maxSize = maxSize
    }
}

/// Per-window resize bookkeeping.
public struct ResizeState: Equatable {
    /// The size the user wants. Not nil while the host has not caught up, which is when the last frame is stretched.
    public var target: DeskSize?
    /// The newest size sent to the host.
    public var lastSent: DeskSize?
    public var lastSentAt: Double = -1_000_000
    /// Recent sizes sent, oldest first. A host answer that matches one of them is an old answer, not the final one.
    public var sent: [DeskSize] = []
    public var deadline: Double?
    public init() {}

    /// True while the last frame must be stretched to the window's size.
    public var isStretching: Bool { target != nil }
}

public enum ResizeAction: Equatable {
    /// Send WINDOW_RESIZE_REQUEST for this size now.
    case send(DeskSize)
    /// Call `ResizePolicy.flushDue` after this many seconds.
    case sendLater(after: Double)
    case none
}

public enum HostResizeAnswer: Equatable {
    /// The host reached the size the user wants. Stop stretching.
    case caughtUp
    /// An answer to an earlier request. Keep stretching.
    case stillStretching
    /// The host's size is the one to show: nothing was pending, or the host chose another size.
    case adopted
}

public enum ResizePolicy {
    public static let maxRemembered = 8

    public static func clamp(_ s: DeskSize, _ config: ResizeConfig) -> DeskSize {
        DeskSize(width: min(max(s.width, config.minSize.width), config.maxSize.width),
                 height: min(max(s.height, config.minSize.height), config.maxSize.height))
    }

    /// The user changed the window to `size`. `hostSize` is the host window's current size.
    public static func userResized(_ state: inout ResizeState, to size: DeskSize, hostSize: DeskSize,
                                   now: Double, config: ResizeConfig) -> ResizeAction {
        let s = clamp(size, config)
        if state.target == nil && s.isClose(to: hostSize, tolerance: config.tolerance) { return .none }
        if let t = state.target, t.isClose(to: s, tolerance: config.tolerance) { return .none }
        state.target = s
        state.deadline = now + config.timeout
        let waited = now - state.lastSentAt
        if waited >= config.minInterval {
            record(&state, s, now: now)
            return .send(s)
        }
        return .sendLater(after: config.minInterval - waited)
    }

    /// The `sendLater` time has come. Returns the size to send, if one is still owed.
    public static func flushDue(_ state: inout ResizeState, now: Double, config: ResizeConfig) -> DeskSize? {
        guard let t = state.target else { return nil }
        if let last = state.lastSent, last.isClose(to: t, tolerance: config.tolerance) { return nil }
        guard now - state.lastSentAt >= config.minInterval else { return nil }
        record(&state, t, now: now)
        return t
    }

    /// The host sent WINDOW_RESIZED for `hostSize`.
    public static func hostResized(_ state: inout ResizeState, to hostSize: DeskSize, config: ResizeConfig) -> HostResizeAnswer {
        guard let t = state.target else { return .adopted }
        if hostSize.isClose(to: t, tolerance: config.tolerance) {
            clear(&state)
            return .caughtUp
        }
        if state.sent.contains(where: { hostSize.isClose(to: $0, tolerance: config.tolerance) }) {
            return .stillStretching
        }
        clear(&state)
        return .adopted
    }

    /// True once the host has been silent past the deadline. Clears the state; the window shows the host's size again.
    public static func expired(_ state: inout ResizeState, now: Double) -> Bool {
        guard state.target != nil, let d = state.deadline, now >= d else { return false }
        clear(&state)
        return true
    }

    /// When the window next has work (a send owed, or the deadline), or nil.
    public static func nextWake(_ state: ResizeState, config: ResizeConfig) -> Double? {
        guard let t = state.target else { return nil }
        var wakes: [Double] = []
        if let d = state.deadline { wakes.append(d) }
        let owed: Bool
        if let last = state.lastSent { owed = !last.isClose(to: t, tolerance: config.tolerance) } else { owed = true }
        if owed { wakes.append(state.lastSentAt + config.minInterval) }
        return wakes.min()
    }

    public static func clear(_ state: inout ResizeState) {
        state.target = nil
        state.deadline = nil
        state.sent.removeAll()
    }

    private static func record(_ state: inout ResizeState, _ s: DeskSize, now: Double) {
        state.lastSent = s
        state.lastSentAt = now
        state.sent.append(s)
        if state.sent.count > maxRemembered { state.sent.removeFirst(state.sent.count - maxRemembered) }
    }
}
