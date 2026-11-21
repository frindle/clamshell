/// Plain geometry in points. The package has no CoreGraphics, so it has its own small types.
/// Unless a comment says otherwise, y grows downward (the host's convention).
public struct DeskPoint: Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct DeskSize: Equatable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }

    /// True when both sides differ by no more than `tolerance`.
    public func isClose(to other: DeskSize, tolerance: Double) -> Bool {
        abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}

public struct DeskRect: Equatable {
    public var origin: DeskPoint
    public var size: DeskSize
    public init(origin: DeskPoint, size: DeskSize) { self.origin = origin; self.size = size }
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.origin = DeskPoint(x: x, y: y)
        self.size = DeskSize(width: width, height: height)
    }
    public var minX: Double { origin.x }
    public var minY: Double { origin.y }
    public var maxX: Double { origin.x + size.width }
    public var maxY: Double { origin.y + size.height }

    /// The same rectangle with y measured upward from the bottom of a space `height` tall.
    /// AppKit screen coordinates need this; the model does not.
    public func flipped(inHeight height: Double) -> DeskRect {
        DeskRect(x: origin.x, y: height - origin.y - size.height, width: size.width, height: size.height)
    }
}
