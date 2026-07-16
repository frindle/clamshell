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
    enum State { case idle, collapsing, collapsed }

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

    /// The deferred window-layout restore is still running; completions
    /// queued via restore() wait for it (e.g. quit must not terminate the
    /// process before windows are back on their monitors).
    private var layoutRestoreInFlight = false
    private var onLayoutRestored: [() -> Void] = []

    var preset: DisplayPreset = .iPadAir13

    /// Dual display mode: create a second virtual display (sized `presetB`)
    /// to the right of the first, as an empty extended desktop. Physical
    /// displays still mirror onto display A exactly as in single mode; B
    /// starts empty like a freshly plugged-in monitor.
    var dualMode = false
    var presetB: DisplayPreset = .hd1080

    var onStateChange: ((State) -> Void)?

    init() {
        // If WindowServer reclaims virtual display A out from under us, the
        // collapse is dead — restore so mirroring/state don't point at a
        // ghost. B dying in dual mode just loses the second screen; the
        // controller's own bookkeeping already handled it.
        virtualDisplay.onUnexpectedTermination = { [weak self] slot in
            guard let self, slot == .a, self.state != .idle else { return }
            clog("virtual display A died — restoring")
            self.restore()
        }
        startDisplayReconfigWatch()
    }

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
        guard state == .idle else {
            // Re-collapse while already collapsed (e.g. a new Sunshine
            // session during the restore grace period): keep the current
            // collapse and make sure no stale restore tears it down.
            pendingRestore?.cancel()
            pendingRestore = nil
            return
        }
        pendingRestore?.cancel()
        pendingRestore = nil
        state = .collapsing // set before any async work so a disconnect in the gap still schedules a restore
        clog("collapsing to \(preset.name)\(dualMode ? " + \(presetB.name) (dual)" : "")")

        layout.snapshot()

        virtualDisplay.create(preset: preset, slot: .a) { [weak self] virtualID in
            guard let self else { return }
            guard self.state == .collapsing else {
                // restore() ran while creation was retrying — clean up.
                self.virtualDisplay.destroy()
                return
            }
            guard let virtualID else {
                clog("collapse aborted: virtual display creation failed")
                self.state = .idle
                self.onStateChange?(.idle)
                return
            }
            if self.dualMode {
                self.virtualDisplay.create(preset: self.presetB, slot: .b) { secondID in
                    if secondID == nil {
                        clog("dual mode: display B creation failed — continuing single-display")
                    }
                    self.finishCollapse(virtualID: virtualID, secondID: secondID)
                }
            } else {
                self.finishCollapse(virtualID: virtualID, secondID: nil)
            }
        }
    }

    /// Give WindowServer a beat to finish attaching the new display(s)
    /// before reconfiguring mirroring.
    private func finishCollapse(virtualID: CGDirectDisplayID, secondID: CGDirectDisplayID?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.state == .collapsing else { return }
            if let b = secondID {
                self.positionSideBySide(a: virtualID, b: b)
            }
            self.mirrorPhysicalDisplays(onto: virtualID)
            self.comfort.sessionDidStart()
            self.state = .collapsed
            self.onStateChange?(.collapsed)
        }
    }

    /// `completion` fires after the deferred window-layout restore has run
    /// (or immediately when there is nothing to restore).
    func restore(completion: (() -> Void)? = nil) {
        pendingRestore?.cancel()
        pendingRestore = nil
        if let completion { onLayoutRestored.append(completion) }
        guard state != .idle else {
            if !layoutRestoreInFlight { flushRestoreCompletions() }
            return
        }
        clog("restoring physical displays")

        comfort.sessionDidEnd()
        unmirrorPhysicalDisplays()
        virtualDisplay.destroy()
        state = .idle
        onStateChange?(.idle)

        // Window restore waits for the display topology to settle; the
        // WindowServer moves windows around for a moment after un-mirroring.
        layoutRestoreInFlight = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            self.layout.restore()
            self.layoutRestoreInFlight = false
            self.flushRestoreCompletions()
        }
    }

    private func flushRestoreCompletions() {
        let callbacks = onLayoutRestored
        onLayoutRestored = []
        for cb in callbacks { cb() }
    }

    private func scheduleRestore() {
        guard state != .idle else { return }
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

    // MARK: - Display topology

    /// Track physical displays disappearing (unplugged mid-session) so
    /// `mirroredDisplays` never holds dead IDs when restore un-mirrors.
    private func startDisplayReconfigWatch() {
        let info = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ displayID, flags, userInfo in
            guard let userInfo, flags.contains(.removeFlag) else { return }
            let coordinator = Unmanaged<CollapseCoordinator>.fromOpaque(userInfo).takeUnretainedValue()
            DispatchQueue.main.async { coordinator.displayRemoved(displayID) }
        }, info)
    }

    private func displayRemoved(_ id: CGDirectDisplayID) {
        if let idx = mirroredDisplays.firstIndex(of: id) {
            mirroredDisplays.remove(at: idx)
            clog("mirrored physical display \(id) was removed; \(mirroredDisplays.count) still mirrored")
        }
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
