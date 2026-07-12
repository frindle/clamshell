import AppKit
import CoreGraphics

/// Orchestrates the collapse/restore sequence:
///
/// Collapse (remote session begins):
///   1. Snapshot window layout across all physical displays.
///   2. Create the virtual display at the configured preset.
///   3. Mirror every physical display onto the virtual one — public API, and
///      macOS consolidates all windows onto the single logical display.
///
/// Restore (session ends / user back at desk):
///   1. Un-mirror the physical displays.
///   2. Destroy the virtual display.
///   3. Put every window back on its original monitor.
final class CollapseCoordinator {
    enum State { case idle, collapsed }

    private(set) var state: State = .idle
    private let virtualDisplay = VirtualDisplayController()
    private let layout = WindowLayoutStore()
    let comfort = SessionComfort()

    /// Physical display IDs that were mirrored, for exact un-mirroring.
    private var mirroredDisplays: [CGDirectDisplayID] = []

    /// Grace period before restoring after a disconnect, so a dropped
    /// connection that reconnects doesn't thrash displays.
    var restoreDelay: TimeInterval = 10
    private var pendingRestore: DispatchWorkItem?

    var preset: DisplayPreset = .iPadAir13

    var onStateChange: ((State) -> Void)?

    // MARK: - Public entry points

    func remoteSessionChanged(connected: Bool) {
        if connected {
            pendingRestore?.cancel()
            pendingRestore = nil
            collapse()
        } else {
            scheduleRestore()
        }
    }

    func collapse() {
        guard state == .idle else { return }
        clog("collapsing to \(preset.name)")

        layout.snapshot()

        guard let virtualID = virtualDisplay.create(preset: preset) else {
            clog("collapse aborted: virtual display creation failed")
            return
        }

        // Give WindowServer a beat to finish attaching the new display
        // before reconfiguring mirroring.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.mirrorPhysicalDisplays(onto: virtualID)
            self.comfort.sessionDidStart()
            self.state = .collapsed
            self.onStateChange?(.collapsed)
        }
    }

    func restore() {
        pendingRestore?.cancel()
        pendingRestore = nil
        guard state == .collapsed else { return }
        clog("restoring physical displays")

        comfort.sessionDidEnd()
        unmirrorPhysicalDisplays()
        virtualDisplay.destroy()

        // Window restore waits for the display topology to settle; the
        // WindowServer moves windows around for a moment after un-mirroring.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.layout.restore()
        }
        state = .idle
        onStateChange?(.idle)
    }

    private func scheduleRestore() {
        guard state == .collapsed else { return }
        clog("disconnect — restoring in \(Int(restoreDelay))s unless reconnected")
        let work = DispatchWorkItem { [weak self] in self?.restore() }
        pendingRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay, execute: work)
    }

    // MARK: - Mirroring

    private func activePhysicalDisplays(excluding virtualID: CGDirectDisplayID) -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetActiveDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).filter { $0 != virtualID }
    }

    private func mirrorPhysicalDisplays(onto virtualID: CGDirectDisplayID) {
        let physical = activePhysicalDisplays(excluding: virtualID)
        guard !physical.isEmpty else { return }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else {
            clog("CGBeginDisplayConfiguration failed")
            return
        }
        for id in physical {
            CGConfigureDisplayMirrorOfDisplay(cfg, id, virtualID)
        }
        let err = CGCompleteDisplayConfiguration(cfg, .permanently)
        if err == .success {
            mirroredDisplays = physical
            clog("mirrored \(physical.count) physical display(s) onto virtual \(virtualID)")
        } else {
            clog("mirroring failed: \(err.rawValue)")
        }
    }

    private func unmirrorPhysicalDisplays() {
        guard !mirroredDisplays.isEmpty else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else { return }
        for id in mirroredDisplays {
            CGConfigureDisplayMirrorOfDisplay(cfg, id, kCGNullDirectDisplay)
        }
        let err = CGCompleteDisplayConfiguration(cfg, .permanently)
        clog("un-mirrored \(mirroredDisplays.count) display(s): \(err == .success ? "ok" : "error \(err.rawValue)")")
        mirroredDisplays = []
    }
}
