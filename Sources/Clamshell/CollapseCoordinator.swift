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

    /// Dual display mode: create a second virtual display (sized `presetB`)
    /// to the right of the first, as an empty extended desktop. Physical
    /// displays still mirror onto display A exactly as in single mode; B
    /// starts empty like a freshly plugged-in monitor.
    var dualMode = false
    var presetB: DisplayPreset = .hd1080

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
        clog("collapsing to \(preset.name)\(dualMode ? " + \(presetB.name) (dual)" : "")")

        layout.snapshot()

        guard let virtualID = virtualDisplay.create(preset: preset, slot: .a) else {
            clog("collapse aborted: virtual display creation failed")
            return
        }
        var secondID: CGDirectDisplayID?
        if dualMode {
            secondID = virtualDisplay.create(preset: presetB, slot: .b)
            if secondID == nil {
                clog("dual mode: display B creation failed — continuing single-display")
            }
        }

        // Give WindowServer a beat to finish attaching the new display(s)
        // before reconfiguring mirroring.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            if let b = secondID {
                self.positionSideBySide(a: virtualID, b: b)
            }
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

    /// Places virtual display A at the global origin and B immediately to its
    /// right, so the spanning desktop (and the VNC framebuffer that Screen
    /// Sharing serves) has a known, fixed layout: A at x=0, B at x=A.width.
    /// CGConfigureDisplayOrigin works in points (global display space).
    private func positionSideBySide(a: CGDirectDisplayID, b: CGDirectDisplayID) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else {
            clog("CGBeginDisplayConfiguration failed (positioning)")
            return
        }
        CGConfigureDisplayOrigin(cfg, a, 0, 0)
        CGConfigureDisplayOrigin(cfg, b, Int32(preset.pointsWide), 0)
        let err = CGCompleteDisplayConfiguration(cfg, .permanently)
        clog("positioned virtual displays side-by-side (B at x=\(preset.pointsWide)pt): \(err == .success ? "ok" : "error \(err.rawValue)")")
    }

    // MARK: - Mirroring

    private func activePhysicalDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetActiveDisplayList(16, &ids, &count)
        // Exclude every Clamshell virtual display (both slots in dual mode),
        // not just the mirror target — otherwise dual mode would mirror
        // virtual B onto A.
        let virtuals = Set([virtualDisplay.displayID(for: .a), virtualDisplay.displayID(for: .b)].compactMap { $0 })
        return ids.prefix(Int(count)).filter { !virtuals.contains($0) }
    }

    private func mirrorPhysicalDisplays(onto virtualID: CGDirectDisplayID) {
        let physical = activePhysicalDisplays()
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
