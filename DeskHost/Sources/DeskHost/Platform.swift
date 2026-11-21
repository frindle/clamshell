import DeskProtocol

// Everything that touches the Mac sits behind these protocols. The pure logic in this package never calls
// the system; the Clamshell app target supplies the real versions and the tests supply fakes.
//
// Threading: the service is not thread safe. The caller runs every call into it, and every callback out of
// these protocols, on one serial queue.

/// One control connection to one operator, already authenticated and encrypted. Bytes go out whole frames at a time.
public protocol ControlConnection: AnyObject {
    func send(_ bytes: [UInt8])
    func close()
}

public enum LaunchOutcome: Equatable {
    /// The app is running now (it was started, or it already was). `name` is its display name.
    case started(pid: Int32, name: String)
    case notInstalled
    case refused
    case failed
}

public protocol AppLauncher: AnyObject {
    /// Starts the app, or finds the running copy, and opens `targets` (URLs or paths) in it.
    /// Never starts a second copy of an app that is running. May call `completion` later, never twice.
    func launch(bundleId: String, activate: Bool, targets: [String], completion: @escaping (LaunchOutcome) -> Void)
}

/// What the system says about one window at one moment.
public struct HostWindowSnapshot: Equatable {
    public var windowId: UInt32
    public var title: String
    /// Accessibility role and subrole, when the accessibility tree lists the window.
    public var role: String?
    public var subrole: String?
    public var level: Int
    /// Points on the hosted display.
    public var x: Float, y: Float, width: Float, height: Float
    public var scale: Float
    /// The window this one belongs to, when the system says so. 0 when it does not.
    public var parentHint: UInt32

    public init(windowId: UInt32, title: String = "", role: String? = "AXWindow", subrole: String? = "AXStandardWindow",
                level: Int = 0, x: Float = 0, y: Float = 0, width: Float = 800, height: Float = 600, scale: Float = 2,
                parentHint: UInt32 = 0) {
        self.windowId = windowId; self.title = title; self.role = role; self.subrole = subrole; self.level = level
        self.x = x; self.y = y; self.width = width; self.height = height; self.scale = scale; self.parentHint = parentHint
    }

    public var kind: WindowKind { WindowClassifier.classify(role: role, subrole: subrole, level: level) }
    public var geometry: Geometry { Geometry(x: x, y: y, width: width, height: height, scale: scale) }
}

public protocol WindowSource: AnyObject {
    /// Windows of one process, front to back. Empty for a process with no windows.
    func windows(pid: Int32) -> [HostWindowSnapshot]
    func isRunning(pid: Int32) -> Bool
    func residentMB(pid: Int32) -> UInt32
}

/// Starts and stops capture and encoding of one window. Frames go to `sink`: keyframe flag, timestamp, NAL data.
public protocol WindowStreamer: AnyObject {
    func startStream(windowId: UInt32, sink: @escaping (_ keyframe: Bool, _ ptsMicros: UInt64, _ nal: [UInt8]) -> Void)
    func stopStream(windowId: UInt32)
    /// The next frame of a running stream must be a keyframe (a second operator joined).
    func requestKeyframe(windowId: UInt32)
}

/// Asks the app to give a window a new size. The app may refuse or round; the source shows what it got.
public protocol WindowResizer: AnyObject {
    func resize(windowId: UInt32, pid: Int32, width: Float, height: Float)
}

public enum HostInputEvent: Equatable {
    case mouseMove(x: Float, y: Float)
    case mouseButton(button: UInt8, down: Bool, x: Float, y: Float)
    case key(macKeyCode: UInt16, down: Bool, flags: UInt64)
    case scroll(dx: Float, dy: Float)

    public var kind: InputEventKind {
        switch self {
        case .mouseMove: return .pointerMove
        case .mouseButton: return .pointerButton
        case .key: return .key
        case .scroll: return .scroll
        }
    }
}

public protocol InputDelivery: AnyObject {
    /// What the host can do for this window right now. Asked for every event, so it must be cheap.
    func capabilities(windowId: UInt32, pid: Int32) -> InputCapabilities
    /// Tries one route. True if the event was delivered.
    func deliver(_ event: HostInputEvent, windowId: UInt32, pid: Int32, route: InputRoute) -> Bool
}

public struct HostDependencies {
    public var launcher: AppLauncher
    public var windows: WindowSource
    public var streamer: WindowStreamer
    public var resizer: WindowResizer
    public var input: InputDelivery
    public init(launcher: AppLauncher, windows: WindowSource, streamer: WindowStreamer, resizer: WindowResizer, input: InputDelivery) {
        self.launcher = launcher; self.windows = windows; self.streamer = streamer; self.resizer = resizer; self.input = input
    }
}

public struct HostConfig {
    public var routePreference: RoutePreference = .auto
    /// Whether this operator may start this app. The default allows any app.
    public var allowLaunch: (String) -> Bool = { _ in true }
    /// A line for the log. Never given a payload or a path.
    public var log: (String) -> Void = { _ in }
    public init() {}
}
