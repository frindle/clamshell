/// Memory pressure as macOS reports it. Only green is eligible to receive work.
public enum MemoryPressure: Int, Equatable, Comparable {
    case green = 0, yellow = 1, red = 2
    public static func < (a: MemoryPressure, b: MemoryPressure) -> Bool { a.rawValue < b.rawValue }
}

/// One reading from a Mac's node agent (read-only system figures; never anything from Darkbloom itself).
public struct HostSample: Equatable {
    public var name: String
    public var totalMB: Int
    /// Memory that could be handed to a new app now (free plus easily reclaimed), in MB.
    public var freeMB: Int
    public var swapUsedMB: Int
    public var pressure: MemoryPressure
    public init(name: String, totalMB: Int, freeMB: Int, swapUsedMB: Int = 0, pressure: MemoryPressure = .green) {
        self.name = name; self.totalMB = totalMB; self.freeMB = freeMB; self.swapUsedMB = swapUsedMB; self.pressure = pressure
    }
}

/// Things that force an app to stay on the Mac Penn is at (plan 3.2).
public enum Need: String, Equatable, CaseIterable {
    case camera, usbkey, drm
}

/// Where an app runs, in the unified rules (plan 3.2 and 9.2).
public enum Placement: Equatable {
    /// Always the Mac Penn is at.
    case local
    /// Always this Mac (its data lives there).
    case home(String)
    /// The Mac with the most headroom. With `avoidSeat`, any other eligible Mac is preferred over the one Penn is at.
    case anywhere(avoidSeat: Bool)
}

public struct AppRule: Equatable {
    public var placement: Placement?
    public var needs: Set<Need>
    public init(placement: Placement? = nil, needs: Set<Need> = []) { self.placement = placement; self.needs = needs }
}

public struct PlacementConfig: Equatable {
    /// Applies to apps with no rule. Built in: `local`, so only apps named in the file are ever moved off the Mac Penn is at.
    public var defaultPlacement: Placement = .local
    /// Kept free on top of Darkbloom's footprint (plan 3.2: "plus 8 GB").
    public var reserveBufferMB: Int = 8 * 1024
    /// A Mac with at least this much swap in use counts as short of memory for move offers.
    public var swapThresholdMB: Int = 4 * 1024
    /// Measured Darkbloom footprint per Mac (experiment E2). A Mac with no entry is unmeasured and receives nothing
    /// (plan 2.7: measured, never assumed). Write 0 for a Mac where Darkbloom is known not to be installed.
    public var darkbloomFootprintMB: [String: Int] = [:]
    public var apps: [String: AppRule] = [:]
    public init() {}

    public func isMeasured(_ mac: String) -> Bool { darkbloomFootprintMB[mac] != nil }

    /// Buffer plus Darkbloom's footprint; nil when the footprint is not measured.
    public func reserveMB(on mac: String) -> Int? { darkbloomFootprintMB[mac].map { reserveBufferMB + $0 } }

    /// Free memory after the reserve. May be negative. nil when the Mac's Darkbloom footprint is not measured.
    public func headroomMB(_ s: HostSample) -> Int? { reserveMB(on: s.name).map { s.freeMB - $0 } }

    public func resolve(_ app: String) -> (placement: Placement, needs: Set<Need>) {
        let rule = apps[app]
        let needs = rule?.needs ?? []
        // Any hardware need forces local, whatever else the rule says.
        if !needs.isEmpty { return (.local, needs) }
        return (rule?.placement ?? defaultPlacement, needs)
    }
}
