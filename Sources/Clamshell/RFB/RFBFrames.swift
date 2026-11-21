import Foundation

/// Where the pixels come from. The real one captures the screen; tests and
/// the self-test serve a synthetic image.
protocol RFBFrameSource: AnyObject {
    /// Starts capture if needed and waits for a first frame. false: no screen.
    func acquireFrames() -> Bool
    func releaseFrames()
    /// Size in pixels of the frames `withLatestFrame` gives.
    var size: (width: Int, height: Int) { get }
    /// Runs `body` on the newest frame. false when there is none yet.
    @discardableResult
    func withLatestFrame(_ body: (RFBFrameView) -> Void) -> Bool
}

/// A fixed in-memory image, for tests and the self-test.
final class RFBStaticFrameSource: RFBFrameSource {
    private let lock = NSLock()
    private var pixels: [UInt8]
    private(set) var width: Int
    private(set) var height: Int
    private(set) var acquired = 0

    init(width: Int, height: Int, fill: (Int, Int) -> (UInt8, UInt8, UInt8)) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let c = fill(x, y)
            let o = (y * width + x) * 4
            pixels[o] = c.2; pixels[o + 1] = c.1; pixels[o + 2] = c.0
        } }
    }

    func set(x: Int, y: Int, _ c: (UInt8, UInt8, UInt8)) {
        lock.lock(); defer { lock.unlock() }
        let o = (y * width + x) * 4
        pixels[o] = c.2; pixels[o + 1] = c.1; pixels[o + 2] = c.0
    }

    /// Replace the whole image at a new size (a display mode change).
    func replace(width: Int, height: Int, fill: (Int, Int) -> (UInt8, UInt8, UInt8)) {
        let next = RFBStaticFrameSource(width: width, height: height, fill: fill)
        lock.lock(); defer { lock.unlock() }
        self.width = width; self.height = height; pixels = next.pixels
    }

    func acquireFrames() -> Bool { lock.lock(); acquired += 1; lock.unlock(); return true }
    func releaseFrames() { lock.lock(); acquired -= 1; lock.unlock() }
    var size: (width: Int, height: Int) { lock.lock(); defer { lock.unlock() }; return (width, height) }

    func withLatestFrame(_ body: (RFBFrameView) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        pixels.withUnsafeBufferPointer { p in
            body(RFBFrameView(base: p.baseAddress!, bytesPerRow: width * 4, width: width, height: height))
        }
        return true
    }
}

/// Remembers what one client has been sent, so only changed 64x64 tiles go
/// out again. Tiles are compared against a private copy of the pixels.
final class RFBFramebufferTracker {
    static let tile = 64

    struct Rect: Equatable { var x: Int, y: Int, w: Int, h: Int }

    private(set) var width: Int
    private(set) var height: Int
    private var snapshot: [UInt8]
    private var valid: [Bool]
    private var columns: Int
    private var rows: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        columns = (width + Self.tile - 1) / Self.tile
        rows = (height + Self.tile - 1) / Self.tile
        snapshot = [UInt8](repeating: 0, count: width * height * 4)
        valid = [Bool](repeating: false, count: columns * rows)
    }

    func reset(width: Int, height: Int) {
        self.width = width
        self.height = height
        columns = (width + Self.tile - 1) / Self.tile
        rows = (height + Self.tile - 1) / Self.tile
        snapshot = [UInt8](repeating: 0, count: width * height * 4)
        valid = [Bool](repeating: false, count: columns * rows)
    }

    func invalidate(_ region: Rect) {
        for r in 0..<rows { for c in 0..<columns {
            let t = tileRect(c, r)
            if intersects(t, region) { valid[r * columns + c] = false }
        } }
    }

    private func tileRect(_ c: Int, _ r: Int) -> Rect {
        Rect(x: c * Self.tile, y: r * Self.tile,
             w: min(Self.tile, width - c * Self.tile), h: min(Self.tile, height - r * Self.tile))
    }

    private func intersects(_ a: Rect, _ b: Rect) -> Bool {
        a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
    }

    private func differs(_ frame: RFBFrameView, _ t: Rect) -> Bool {
        snapshot.withUnsafeBufferPointer { snap in
            for row in t.y..<(t.y + t.h) {
                let a = frame.base + row * frame.bytesPerRow + t.x * 4
                let b = snap.baseAddress! + (row * width + t.x) * 4
                if memcmp(a, b, t.w * 4) != 0 { return true }
            }
            return false
        }
    }

    /// The rectangles to send for a request over `region`: changed tiles in
    /// each tile row, joined left to right, clipped to the region.
    func changes(in frame: RFBFrameView, region: Rect) -> [Rect] {
        guard frame.width == width, frame.height == height else { return [] }
        var out: [Rect] = []
        for r in 0..<rows {
            var runStart: Int?
            func close(_ end: Int) {
                guard let s = runStart else { return }
                let first = tileRect(s, r), last = tileRect(end - 1, r)
                let x0 = max(first.x, region.x), x1 = min(last.x + last.w, region.x + region.w)
                let y0 = max(first.y, region.y), y1 = min(first.y + first.h, region.y + region.h)
                if x1 > x0 && y1 > y0 { out.append(Rect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)) }
                runStart = nil
            }
            for c in 0..<columns {
                let t = tileRect(c, r)
                let dirty = intersects(t, region) && (!valid[r * columns + c] || differs(frame, t))
                if dirty { if runStart == nil { runStart = c } } else { close(c) }
            }
            close(columns)
        }
        return out
    }

    /// Records that `rect` was sent: copies its pixels, and marks the tiles it
    /// covers entirely as up to date.
    func commit(_ rect: Rect, frame: RFBFrameView) {
        snapshot.withUnsafeMutableBufferPointer { snap in
            for row in rect.y..<(rect.y + rect.h) {
                memcpy(snap.baseAddress! + (row * width + rect.x) * 4,
                       frame.base + row * frame.bytesPerRow + rect.x * 4, rect.w * 4)
            }
        }
        for r in 0..<rows { for c in 0..<columns {
            let t = tileRect(c, r)
            if t.x >= rect.x && t.y >= rect.y && t.x + t.w <= rect.x + rect.w && t.y + t.h <= rect.y + rect.h {
                valid[r * columns + c] = true
            }
        } }
    }
}
