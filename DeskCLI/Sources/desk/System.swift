#if os(macOS)
import Foundation
import AppKit
import Darwin
import DeskCLICore
import DeskPlacer
import DeskProtocol

// Real implementations of the ports. Nothing here asks for a permission, signals Darkbloom, or runs `memory_pressure`.

final class StdOutput: Output {
    func line(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
    func errorLine(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
}

struct SystemClock: Clock {
    func now() -> Double { Date().timeIntervalSince1970 }
    /// Runs the run loop while waiting, so the list of running apps stays current.
    func sleep(_ seconds: Double) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }
}

struct SystemFiles: TextFiles {
    func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
}

struct SystemHost: HostInfo {
    func thisMacName() -> String {
        var buf = [CChar](repeating: 0, count: 256)
        guard gethostname(&buf, buf.count) == 0 else { return "this-mac" }
        let full = String(cString: buf)
        return full.split(separator: ".").first.map(String.init) ?? full
    }
    func environment(_ key: String) -> String? { ProcessInfo.processInfo.environment[key] }
    func homeDirectory() -> String { NSHomeDirectory() }
}

private func sysctlValue<T>(_ name: String, _ zero: T) -> T? {
    var v = zero
    var size = MemoryLayout<T>.size
    return sysctlbyname(name, &v, &size, nil, 0) == 0 ? v : nil
}

/// Read-only: two sysctl numbers, the swap figure and the host statistics call.
struct SystemMemory: MemorySource {
    func read() throws -> MemoryReading {
        guard let total: UInt64 = sysctlValue("hw.memsize", UInt64(0)) else { throw DeskError("could not read hw.memsize") }
        let page = getpagesize()
        guard let level: Int32 = sysctlValue("kern.memorystatus_level", Int32(0)) else { throw DeskError("could not read kern.memorystatus_level") }
        let vmLevel: Int32? = sysctlValue("kern.memorystatus_vm_pressure_level", Int32(0))

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 else { throw DeskError("could not read vm.swapusage") }

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { throw DeskError("could not read host statistics") }
        let freePages = UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.purgeable_count)
        let mb: (UInt64) -> Int = { Int($0 / 1_048_576) }
        return MemoryReading(totalMB: mb(total), freeMB: mb(freePages * UInt64(page)), swapUsedMB: mb(swap.xsu_used),
                             levelPercent: Int(level), vmPressureLevel: vmLevel.map { Int($0) }, apps: SystemMemory.apps())
    }

    /// Footprint per regular app: the app's process plus its child processes. Darkbloom is skipped before any
    /// process is looked at.
    static func apps() -> [AppInfo] {
        var children: [Int32: [Int32]] = [:]
        let n = proc_listallpids(nil, 0)
        if n > 0 {
            var pids = [Int32](repeating: 0, count: Int(n) + 64)
            let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
            for pid in pids.prefix(max(Int(got), 0)) where pid > 0 {
                var info = proc_bsdinfo()
                if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 {
                    children[Int32(info.pbi_ppid), default: []].append(pid)
                }
            }
        }
        func footprintBytes(_ pid: Int32) -> UInt64 {
            var info = rusage_info_v4()
            let r = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            return r == 0 ? info.ri_phys_footprint : 0
        }
        var result: [AppInfo] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier else { continue }
            let name = app.localizedName ?? id
            let lower = (id + " " + name).lowercased()
            if lower.contains("darkbloom") { continue }
            var total: UInt64 = 0
            var stack = [app.processIdentifier]
            var seen = Set<Int32>()
            while let pid = stack.popLast() {
                guard seen.insert(pid).inserted else { continue }
                total += footprintBytes(pid)
                stack.append(contentsOf: children[pid] ?? [])
            }
            let mb = UInt32(min(total / 1_048_576, UInt64(UInt32.max)))
            result.append(AppInfo(appId: UInt32(truncatingIfNeeded: app.processIdentifier), bundleId: id, name: name,
                                  pid: app.processIdentifier, windowCount: 0, residentMB: mb, running: true))
        }
        return result
    }
}

struct SystemApps: LocalApps {
    func isRunning(bundleId: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).contains { !$0.isTerminated }
    }
    func requestQuit(bundleId: String) throws {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        if apps.isEmpty { throw DeskError("\(bundleId) is not running") }
        // terminate() asks the app to quit, as Cmd-Q does. It never forces.
        for a in apps where !a.terminate() { throw DeskError("\(bundleId) did not accept the quit request") }
    }
    // Reading window titles and edited markers needs the accessibility or screen recording grant, which this
    // command never asks for. The Desk client supplies these later.
    func windowTitles(bundleId: String) -> [String]? { nil }
    func editedWindows(bundleId: String) -> [String]? { nil }
}

struct SystemLauncher: LocalLauncher {
    func launch(_ target: LaunchTarget, with bundleId: String?) throws {
        var args: [String] = []
        switch target {
        case .app(let id): args = ["-b", id]
        case .file(let f):
            guard let id = bundleId else { throw DeskError("no app chosen for \(f)") }
            args = ["-b", id, f]
        case .url(let u):
            guard let id = bundleId else { throw DeskError("no app chosen for \(u)") }
            args = ["-b", id, u]
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw DeskError("open exited with status \(p.terminationStatus)") }
    }
}

/// Reads and writes `NSQuitAlwaysKeepsWindows` for one app. Setting it for the app only leaves the global setting alone.
struct SystemDefaults: AppDefaults {
    func keepsWindows(bundleId: String) -> Bool? {
        let key = "NSQuitAlwaysKeepsWindows" as CFString
        if let v = CFPreferencesCopyAppValue(key, bundleId as CFString) as? Bool { return v }
        if let v = CFPreferencesCopyAppValue(key, kCFPreferencesAnyApplication) as? Bool { return v }
        return nil
    }
    func setKeepsWindows(bundleId: String, _ value: Bool) throws {
        CFPreferencesSetAppValue("NSQuitAlwaysKeepsWindows" as CFString, (value ? kCFBooleanTrue : kCFBooleanFalse), bundleId as CFString)
        guard CFPreferencesAppSynchronize(bundleId as CFString) else { throw DeskError("could not save the setting for \(bundleId)") }
    }
}

/// Seeing a call needs the microphone or camera state, which is not public without a permission. Not checked yet.
struct SystemProbe: BlockerProbe {
    var seesCallsAndTransfers: Bool { false }
    func blockers(bundleId: String) -> [Blocker] { [] }
}

/// Which app opens a link or file is the Desk client's job once it is the default handler. Until then say so.
struct SystemHandlers: HandlerLookup {
    func appFor(url: String) -> String? { ProcessInfo.processInfo.environment["DESK_BROWSER"] }
    func appFor(file: String) -> String? { nil }
}

enum SystemPorts {
    static func make() -> Ports {
        Ports(out: StdOutput(), clock: SystemClock(), files: SystemFiles(), host: SystemHost(), memory: SystemMemory(),
              peers: NoPeers(), apps: SystemApps(), launcher: SystemLauncher(), remote: NoRemoteLauncher(),
              defaults: SystemDefaults(), probe: SystemProbe(), handlers: SystemHandlers())
    }
}
#endif
