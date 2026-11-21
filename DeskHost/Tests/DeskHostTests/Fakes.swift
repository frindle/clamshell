import XCTest
import DeskProtocol
@testable import DeskHost

final class FakeConnection: ControlConnection {
    var sent: [[UInt8]] = []
    private(set) var closed = false
    private var parser = FrameParser()

    func send(_ bytes: [UInt8]) { sent.append(bytes) }
    func close() { closed = true }

    /// Every message sent since the last call, decoded.
    func drain() -> [DeskMessage] {
        var out: [DeskMessage] = []
        for b in sent {
            let frames = try! parser.feed(b)
            for f in frames { out.append(try! DeskMessage.decode(type: f.type, payload: f.payload)) }
        }
        sent = []
        return out
    }
}

final class FakeLauncher: AppLauncher {
    var outcomes: [String: LaunchOutcome] = [:]
    var calls: [(bundleId: String, activate: Bool, targets: [String])] = []
    /// When set, completions wait here until `finish()` is called.
    var holdCompletions = false
    private var held: [() -> Void] = []

    func launch(bundleId: String, activate: Bool, targets: [String], completion: @escaping (LaunchOutcome) -> Void) {
        calls.append((bundleId, activate, targets))
        let outcome = outcomes[bundleId] ?? .notInstalled
        if holdCompletions { held.append { completion(outcome) } } else { completion(outcome) }
    }
    func finish() { let h = held; held = []; for c in h { c() } }
}

final class FakeWindows: WindowSource {
    var byPid: [Int32: [HostWindowSnapshot]] = [:]
    var running: Set<Int32> = []
    func windows(pid: Int32) -> [HostWindowSnapshot] { byPid[pid] ?? [] }
    func isRunning(pid: Int32) -> Bool { running.contains(pid) }
    func residentMB(pid: Int32) -> UInt32 { 100 }
}

final class FakeStreamer: WindowStreamer {
    var started: [UInt32] = []
    var stopped: [UInt32] = []
    var keyframeRequests: [UInt32] = []
    var sinks: [UInt32: (Bool, UInt64, [UInt8]) -> Void] = [:]
    func startStream(windowId: UInt32, sink: @escaping (Bool, UInt64, [UInt8]) -> Void) { started.append(windowId); sinks[windowId] = sink }
    func stopStream(windowId: UInt32) { stopped.append(windowId); sinks[windowId] = nil }
    func requestKeyframe(windowId: UInt32) { keyframeRequests.append(windowId) }
}

final class FakeResizer: WindowResizer {
    var calls: [(UInt32, Int32, Float, Float)] = []
    /// Applies the new size to the fake window list when true.
    var obey = true
    weak var windows: FakeWindows?
    func resize(windowId: UInt32, pid: Int32, width: Float, height: Float) {
        calls.append((windowId, pid, width, height))
        guard obey, var list = windows?.byPid[pid], let i = list.firstIndex(where: { $0.windowId == windowId }) else { return }
        list[i].width = width; list[i].height = height
        windows?.byPid[pid] = list
    }
}

final class FakeInput: InputDelivery {
    var caps = InputCapabilities(frontmostOnHostedDisplay: true, perProcessEventAvailable: true, accessibilityTrusted: true)
    /// Routes that fail when tried.
    var failing: Set<String> = []
    var delivered: [(HostInputEvent, UInt32, InputRoute)] = []
    var attempts: [InputRoute] = []
    func capabilities(windowId: UInt32, pid: Int32) -> InputCapabilities { caps }
    func deliver(_ event: HostInputEvent, windowId: UInt32, pid: Int32, route: InputRoute) -> Bool {
        attempts.append(route)
        if failing.contains("\(route)") { return false }
        delivered.append((event, windowId, route))
        return true
    }
}

/// A host wired to fakes.
final class Rig {
    let launcher = FakeLauncher()
    let windows = FakeWindows()
    let streamer = FakeStreamer()
    let resizer = FakeResizer()
    let input = FakeInput()
    var logs: [String] = []
    let service: AppHostService

    init() {
        resizer.windows = windows
        var config = HostConfig()
        let sink: (String) -> Void = { _ in }
        config.log = sink
        service = AppHostService(dependencies: HostDependencies(launcher: launcher, windows: windows, streamer: streamer, resizer: resizer, input: input), config: config)
        launcher.outcomes["org.example.browser"] = .started(pid: 4242, name: "Browser")
        windows.running = [4242]
    }

    func connect(_ operatorId: String = "op1", caps: UInt32 = DeskCapability.appHost) -> (FakeConnection, OperatorConnection?) {
        let c = FakeConnection()
        return (c, service.accept(operatorId: operatorId, connection: c, peerCapabilities: caps))
    }
}

extension OperatorConnection {
    func say(_ m: DeskMessage) { receive(try! m.encodeFrame()) }
}

func mainWindow(_ id: UInt32, x: Float = 100, y: Float = 100, w: Float = 800, h: Float = 600, title: String = "Main") -> HostWindowSnapshot {
    HostWindowSnapshot(windowId: id, title: title, role: "AXWindow", subrole: "AXStandardWindow", level: 0, x: x, y: y, width: w, height: h)
}
