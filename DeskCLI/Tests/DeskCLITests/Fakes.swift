import XCTest
import DeskPlacer
import DeskProtocol
@testable import DeskCLICore

final class FakeOut: Output {
    var lines: [String] = []
    var errors: [String] = []
    func line(_ text: String) { lines.append(text) }
    func errorLine(_ text: String) { errors.append(text) }
    var text: String { lines.joined(separator: "\n") }
    var errorText: String { errors.joined(separator: "\n") }
}

final class FakeClock: Clock {
    var time: Double
    var slept: Double = 0
    init(_ t: Double = 1000) { time = t }
    func now() -> Double { time }
    func sleep(_ seconds: Double) { time += seconds; slept += seconds }
}

struct FakeFiles: TextFiles {
    var files: [String: String] = [:]
    func read(_ path: String) -> String? { files[path] }
    func exists(_ path: String) -> Bool { files[path] != nil }
}

struct FakeHost: HostInfo {
    var name = "alpha"
    var env: [String: String] = [:]
    func thisMacName() -> String { name }
    func environment(_ key: String) -> String? { env[key] }
    func homeDirectory() -> String { "/home/test" }
}

final class FakeMemory: MemorySource {
    var reading: MemoryReading?
    var error: DeskError?
    var reads = 0
    init(_ r: MemoryReading) { reading = r }
    func read() throws -> MemoryReading {
        reads += 1
        if let e = error { throw e }
        return reading!
    }
}

struct FakePeers: PeerSource {
    var list: [PeerReport] = []
    func reports() throws -> [PeerReport] { list }
}

final class FakeApps: LocalApps {
    var running: Set<String> = []
    var quitRequests: [String] = []
    /// When false, a quit request does nothing (an app stuck on a save dialog).
    var quitWorks = true
    /// Quits only after this many polls.
    var pollsBeforeExit = 0
    var polls = 0
    var titles: [String: [String]] = [:]
    var edited: [String: [String]] = [:]
    var titlesKnown = true
    var editedKnown = true
    func isRunning(bundleId: String) -> Bool {
        if quitRequests.contains(bundleId), quitWorks {
            polls += 1
            if polls > pollsBeforeExit { running.remove(bundleId) }
        }
        return running.contains(bundleId)
    }
    func requestQuit(bundleId: String) throws { quitRequests.append(bundleId) }
    func windowTitles(bundleId: String) -> [String]? { titlesKnown ? (titles[bundleId] ?? []) : nil }
    func editedWindows(bundleId: String) -> [String]? { editedKnown ? (edited[bundleId] ?? []) : nil }
}

final class FakeLauncher: LocalLauncher {
    var launches: [(LaunchTarget, String?)] = []
    func launch(_ target: LaunchTarget, with bundleId: String?) throws { launches.append((target, bundleId)) }
}

final class FakeRemote: RemoteLauncher {
    var opens: [(LaunchTarget, String?, String)] = []
    var performed: [RestoreStep] = []
    var cannot: String?
    var failOn: ((RestoreStep) -> Bool)?
    func open(_ target: LaunchTarget, with bundleId: String?, on mac: String) throws { opens.append((target, bundleId, mac)) }
    func canPerform(_ step: RestoreStep, bundleId: String, on mac: String) -> String? { cannot }
    func perform(_ step: RestoreStep, bundleId: String, on mac: String) throws {
        if let f = failOn, f(step) { throw DeskError("boom") }
        performed.append(step)
    }
}

final class FakeDefaults: AppDefaults {
    var keeps: [String: Bool] = [:]
    var sets: [(String, Bool)] = []
    func keepsWindows(bundleId: String) -> Bool? { keeps[bundleId] }
    func setKeepsWindows(bundleId: String, _ value: Bool) throws { sets.append((bundleId, value)); keeps[bundleId] = value }
}

struct FakeProbe: BlockerProbe {
    var sees = true
    var blocked: [String: [Blocker]] = [:]
    var seesCallsAndTransfers: Bool { sees }
    func blockers(bundleId: String) -> [Blocker] { blocked[bundleId] ?? [] }
}

struct FakeHandlers: HandlerLookup {
    var url: String?
    var file: String?
    func appFor(url: String) -> String? { self.url }
    func appFor(file: String) -> String? { self.file }
}

let rulesText = """
[defaults]
mode = "local"

[mac."alpha"]
darkbloom_footprint_mb = 2000

[mac."beta"]
darkbloom_footprint_mb = 2000

[app."com.tinyspeck.slackmacgap"]
prefer = "auto"

[app."com.anthropic.claudefordesktop"]
prefer = "auto"

[app."com.brave.Browser"]
home = "beta"

[app."org.mozilla.firefox"]
prefer = "auto"

[app."com.hnc.Discord"]
needs = ["camera"]
"""

func appInfo(_ id: String, _ name: String, _ mb: UInt32, running: Bool = true) -> AppInfo {
    AppInfo(appId: 1, bundleId: id, name: name, pid: 1, windowCount: 0, residentMB: mb, running: running)
}

/// Everything a test needs: fakes wired into Ports, with handles to inspect them.
final class Rig {
    let out = FakeOut()
    let clock = FakeClock()
    var files = FakeFiles(files: ["/home/test/.config/desk/placement.toml": rulesText])
    var host = FakeHost()
    var memory: FakeMemory
    var peers = FakePeers()
    let apps = FakeApps()
    let launcher = FakeLauncher()
    let remote = FakeRemote()
    let defaults = FakeDefaults()
    var probe = FakeProbe()
    var handlers = FakeHandlers()

    /// This Mac is `alpha`: 64 GB, 20 GB free, green.
    init(localFreeMB: Int = 20_000, localPressureLevel: Int = 1, swapMB: Int = 0, apps local: [AppInfo] = []) {
        memory = FakeMemory(MemoryReading(totalMB: 65_536, freeMB: localFreeMB, swapUsedMB: swapMB, levelPercent: 40,
                                         vmPressureLevel: localPressureLevel, apps: local))
    }

    /// A report from `beta` taken at the fake clock's time.
    func peer(free: Int = 30_000, pressure: MemoryPressure = .green, swap: Int = 0, age: Double = 0, apps: [AppInfo] = []) {
        peers.list = [PeerReport(sample: HostSample(name: "beta", totalMB: 131_072, freeMB: free, swapUsedMB: swap, pressure: pressure,
                                                     sampledAt: clock.time - age), apps: apps)]
    }

    var ports: Ports {
        Ports(out: out, clock: clock, files: files, host: host, memory: memory, peers: peers, apps: apps, launcher: launcher,
              remote: remote, defaults: defaults, probe: probe, handlers: handlers)
    }

    @discardableResult
    func run(_ args: String...) -> Int32 { Cli.run(args, ports: ports) }
}
