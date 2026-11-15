import Foundation

// Pure mapping from a hardware pointer to protocol values. Foundation only:
// compiled into the host and the iOS app so it can be tested in CI.

enum PointerButtons {
    /// INPUT_MOUSE_BUTTON number for a UIKit `UIEvent.buttonMask` raw value:
    /// bit 0 primary, bit 1 secondary, bits 2...4 middle, back, forward.
    /// Secondary wins, then primary. Middle, back and forward are reported
    /// only when `extraButtons` is set (the host advertises it); otherwise
    /// they behave as before (left).
    static func button(forMask mask: Int, extraButtons: Bool) -> UInt8 {
        if mask & 0b10 != 0 { return 1 }
        if mask & 0b1 != 0 { return 0 }
        guard extraButtons else { return 0 }
        for bit in 2...4 where mask & (1 << bit) != 0 { return UInt8(bit) }
        return 0
    }

    /// A captured-pointer movement from GCMouse (y grows upward there) as
    /// INPUT_MOUSE_RELATIVE deltas (y grows downward). nil for no movement or
    /// a non-finite value.
    static func relativeDelta(dx: Float, dy: Float) -> (dx: Float, dy: Float)? {
        guard dx.isFinite, dy.isFinite, dx != 0 || dy != 0 else { return nil }
        return (dx, -dy)
    }
}
