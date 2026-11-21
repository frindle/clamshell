import DeskPlacer
import DeskProtocol

// Every system action the command line takes sits behind one of these protocols.
// The executable supplies real ones; tests supply fakes.

public protocol Output: AnyObject {
    func line(_ text: String)
    func errorLine(_ text: String)
}

public protocol Clock {
    /// Seconds on a clock shared with host reports.
    func now() -> Double
    func sleep(_ seconds: Double)
}

public protocol TextFiles {
    func read(_ path: String) -> String?
    func exists(_ path: String) -> Bool
}

public protocol HostInfo {
    /// This Mac's name as the rules file knows it.
    func thisMacName() -> String
    func environment(_ key: String) -> String?
    func homeDirectory() -> String
}

/// One read of this Mac's memory. Read-only system figures.
public struct MemoryReading: Equatable {
    public var totalMB: Int
    /// Free plus easily reclaimed memory, in MB.
    public var freeMB: Int
    public var swapUsedMB: Int
    /// `kern.memorystatus_level`: percent of memory the kernel counts as free.
    public var levelPercent: Int
    /// `kern.memorystatus_vm_pressure_level` when the Mac gives it: 1 normal, 2 warning, 4 critical.
    public var vmPressureLevel: Int?
    /// Big apps with their footprint. Never contains Darkbloom.
    public var apps: [AppInfo]
    public init(totalMB: Int, freeMB: Int, swapUsedMB: Int, levelPercent: Int, vmPressureLevel: Int? = nil, apps: [AppInfo] = []) {
        self.totalMB = totalMB; self.freeMB = freeMB; self.swapUsedMB = swapUsedMB
        self.levelPercent = levelPercent; self.vmPressureLevel = vmPressureLevel; self.apps = apps
    }

    public var pressure: MemoryPressure {
        if let v = vmPressureLevel {
            switch v {
            case 1: return .green
            case 2: return .yellow
            default: return .red
            }
        }
        // Fallback when the kernel level is not available: an estimate from the free percentage.
        if levelPercent >= 25 { return .green }
        if levelPercent >= 10 { return .yellow }
        return .red
    }
}

public protocol MemorySource {
    func read() throws -> MemoryReading
}

/// What another Mac's node agent reports. The Desk client supplies these later.
public struct PeerReport: Equatable {
    public var sample: HostSample
    public var apps: [AppInfo]
    public init(sample: HostSample, apps: [AppInfo] = []) { self.sample = sample; self.apps = apps }
}

public protocol PeerSource {
    func reports() throws -> [PeerReport]
}

public enum LaunchTarget: Equatable {
    case app(bundleId: String)
    case file(String)
    case url(String)
}

/// Apps on this Mac.
public protocol LocalApps {
    func isRunning(bundleId: String) -> Bool
    /// Asks the app to quit the polite way. Never forces it.
    func requestQuit(bundleId: String) throws
    /// Titles of the app's open windows; nil when this Mac cannot read them.
    func windowTitles(bundleId: String) -> [String]?
    /// Titles of windows with unsaved changes; nil when this Mac cannot tell.
    func editedWindows(bundleId: String) -> [String]?
}

public protocol LocalLauncher {
    /// Starts or activates on this Mac. `bundleId` is the app that should handle a file or link.
    func launch(_ target: LaunchTarget, with bundleId: String?) throws
}

/// The macOS setting that keeps windows across a quit, per app.
public protocol AppDefaults {
    /// Effective value for the app (its own setting, else the global one); nil when unknown.
    func keepsWindows(bundleId: String) -> Bool?
    func setKeepsWindows(bundleId: String, _ value: Bool) throws
}

public protocol BlockerProbe {
    /// Whether this probe can see calls and transfers at all.
    var seesCallsAndTransfers: Bool { get }
    func blockers(bundleId: String) -> [Blocker]
}

/// Which app handles a link or a file.
public protocol HandlerLookup {
    func appFor(url: String) -> String?
    func appFor(file: String) -> String?
}

/// One thing the mover does. `enableKeepWindows` and `quit` happen here; the rest happen on the target Mac.
public enum RestoreStep: Equatable {
    case enableKeepWindows
    case quit
    case copySavedState
    case copyProfile
    case firefoxResumeOnce
    case start(arguments: [String])
    case closeExtraWindows(keep: [String])
    case hideApp

    public var isLocal: Bool { self == .enableKeepWindows || self == .quit }

    public var label: String {
        switch self {
        case .enableKeepWindows: return "turn on window restore for this app only"
        case .quit: return "quit cleanly and wait"
        case .copySavedState: return "copy the app's saved window state"
        case .copyProfile: return "copy the profile folder"
        case .firefoxResumeOnce: return "set the one-time session restore"
        case .start(let a): return a.isEmpty ? "start on the target" : "start on the target with " + a.joined(separator: " ")
        case .closeExtraWindows: return "close windows that were not open before"
        case .hideApp: return "hide windows that were not open before"
        }
    }
}

/// The Desk client implements this later. Until then the real one refuses with a clear message.
public protocol RemoteLauncher {
    func open(_ target: LaunchTarget, with bundleId: String?, on mac: String) throws
    /// nil when the step can be done on that Mac; otherwise the reason it cannot.
    func canPerform(_ step: RestoreStep, bundleId: String, on mac: String) -> String?
    func perform(_ step: RestoreStep, bundleId: String, on mac: String) throws
}

public struct DeskError: Error, CustomStringConvertible, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public struct NoRemoteLauncher: RemoteLauncher {
    public static let reason = "Opening or moving apps on another Mac needs the Desk client, which is not available yet."
    public init() {}
    public func open(_ target: LaunchTarget, with bundleId: String?, on mac: String) throws { throw DeskError(Self.reason) }
    public func canPerform(_ step: RestoreStep, bundleId: String, on mac: String) -> String? { Self.reason }
    public func perform(_ step: RestoreStep, bundleId: String, on mac: String) throws { throw DeskError(Self.reason) }
}

public struct NoPeers: PeerSource {
    public init() {}
    public func reports() throws -> [PeerReport] { [] }
}

public struct Ports {
    public var out: any Output
    public var clock: any Clock
    public var files: any TextFiles
    public var host: any HostInfo
    public var memory: any MemorySource
    public var peers: any PeerSource
    public var apps: any LocalApps
    public var launcher: any LocalLauncher
    public var remote: any RemoteLauncher
    public var defaults: any AppDefaults
    public var probe: any BlockerProbe
    public var handlers: any HandlerLookup
    public init(out: any Output, clock: any Clock, files: any TextFiles, host: any HostInfo, memory: any MemorySource,
                peers: any PeerSource, apps: any LocalApps, launcher: any LocalLauncher, remote: any RemoteLauncher,
                defaults: any AppDefaults, probe: any BlockerProbe, handlers: any HandlerLookup) {
        self.out = out; self.clock = clock; self.files = files; self.host = host; self.memory = memory
        self.peers = peers; self.apps = apps; self.launcher = launcher; self.remote = remote
        self.defaults = defaults; self.probe = probe; self.handlers = handlers
    }
}
