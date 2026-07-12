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
        NSLog("[clamshell] collapsing to %@", preset.name)

        layout.snapshot()

        guard let virtualID = virtualDisplay.create(preset: preset) else {
            NSLog("[clamshell] collapse aborted: virtual display creation failed")
            return
        }

        // Give WindowServer a beat to finish attaching the new display
        // before reconfiguring mirroring.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.mirrorPhysicalDisplays(onto: virtualID)
            self?.state = .collapsed
            self?.onStateChange?(.collapsed)
        }
    }

    func restore() {
        pendingRestore?.cancel()
        pendingRestore = nil
        guard state == .collapsed else { return }
        NSLog("[clamshell] restoring physical displays")

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
        NSLog("[clamshell] disconnect — restoring in %.0fs unless reconnected", restoreDelay)
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
            NSLog("[clamshell] CGBeginDisplayConfiguration failed")
            return
        }
        for id in physical {
            CGConfigureDisplayMirrorOfDisplay(cfg, id, virtualID)
        }
        let err = CGCompleteDisplayConfiguration(cfg, .permanently)
        if err == .success {
            mirroredDisplays = physical
            NSLog("[clamshell] mirrored %d physical display(s) onto virtual %u", physical.count, virtualID)
        } else {
            NSLog("[clamshell] mirroring failed: %d", err.rawValue)
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
        NSLog("[clamshell] un-mirrored %d display(s): %@",
              mirroredDisplays.count, err == .success ? "ok" : "error \(err.rawValue)")
        mirroredDisplays = []
    }
}
