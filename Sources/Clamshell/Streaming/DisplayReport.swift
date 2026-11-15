import Foundation

// What a client tells the host about its display(s), landscape-normalized
// pixels. Each change the host hears about can rebuild its virtual display, so
// the client sends an update only when the new report really differs from what
// the host already has. Foundation only: compiled into the host target and the
// iOS app so tests can cover it.

struct DisplayReport: Equatable {
    var width: UInt32
    var height: UInt32
    var secondDisplay: Bool
    /// 0 x 0 when no second display size is known.
    var secondWidth: UInt32 = 0
    var secondHeight: UInt32 = 0

    /// Size changes at or below this fraction (on both axes) are noise.
    static let tolerance = 0.03

    private static func moved(_ a: UInt32, _ b: UInt32) -> Bool {
        if a == b { return false }
        if a == 0 || b == 0 { return true }
        return abs(Double(a) - Double(b)) / Double(a) > tolerance
    }

    /// True when `now` is worth telling the host about given that it already
    /// has `sent`: the size moved by more than 3% on either axis, or the
    /// second-display flag changed, or (with a second display) its size did.
    /// A report that appears or disappears counts as different.
    static func differs(sent: DisplayReport?, now: DisplayReport?) -> Bool {
        guard let sent, let now else { return (sent == nil) != (now == nil) }
        if sent.secondDisplay != now.secondDisplay { return true }
        if moved(sent.width, now.width) || moved(sent.height, now.height) { return true }
        if now.secondDisplay,
           moved(sent.secondWidth, now.secondWidth) || moved(sent.secondHeight, now.secondHeight) {
            return true
        }
        return false
    }
}
