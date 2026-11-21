/// Reconnect delays: start small, double, stop at a cap. A drop of 10 seconds is meant to heal by itself, so the
/// cap is low: the wait after the network returns is at most `cap`.
public struct Backoff: Equatable {
    public var initial: Double
    public var factor: Double
    public var cap: Double
    private var current: Double

    public init(initial: Double = 0.5, factor: Double = 2, cap: Double = 4) {
        self.initial = initial; self.factor = factor; self.cap = cap
        self.current = initial
    }

    /// The delay to wait now. The one after it is longer, up to the cap.
    public mutating func next() -> Double {
        let d = min(current, cap)
        current = min(current * factor, cap)
        return d
    }

    public mutating func reset() { current = initial }
}
