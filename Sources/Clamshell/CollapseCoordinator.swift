import AppKit
import CoreGraphics
import IOKit.pwr_mgt

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
    
    /// Power assertion to wake the display if it's asleep before mirroring
    private var displayWakeAssertion: IOPMAssertionID = 0

    /// Grace period before restoring after a disconnect, so a dropped
    /// connection that reconnects doesn't thrash displays.
    var restoreDelay: TimeInterval = 10
    private var pendingRestore: DispatchWorkItem?

    /// Cooldown after a failed collapse so a client stuck in a fast
    /// reconnect loop (e.g. connection dying immediately after collapse
    /// fails) doesn't re-hammer the private virtual-display API on every
    /// retry — each collapse attempt already burns ~2s across 8 internal
    /// tries, and reconnects can arrive faster than that.
    private var lastCollapseFailureAt: Date?
    private let collapseFailureCooldown: TimeInterval = 5

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
    
    /// Called when collapse() fails after a full attempt (not during cooldown).
    /// The String is a human-readable failure message.
    var onCollapseFailed: ((String) -> Void)?

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
        if let lastFailure = lastCollapseFailureAt {
            let remaining = collapseFailureCooldown - Date().timeIntervalSince(lastFailure)
            guard remaining <= 0 else {
                clog("collapse skipped: cooling down after recent failure (\(String(format: "%.1f", remaining))s left)")
                return
            }
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
                // Release the display wake assertion if it was created
                if self.displayWakeAssertion != 0 {
                    IOPMAssertionRelease(self.displayWakeAssertion)
                    self.displayWakeAssertion = 0
                }
                return
            }
            guard let virtualID else {
                clog("collapse aborted: virtual display creation failed")
                
                // Check if Screen Sharing is disabled and provide a specific message
                let failureMessage: String
                if !ScreenSharingChecker.isScreenSharingEnabled() {
                    failureMessage = "Screen Sharing is disabled. Enable it in System Settings → General → Sharing → Screen Sharing."
                } else {
                    failureMessage = "Virtual display creation failed. Try restarting Clamshell."
                }
                
                // Release the display wake assertion if it was created
                if self.displayWakeAssertion != 0 {
                    IOPMAssertionRelease(self.displayWakeAssertion)
                    self.displayWakeAssertion = 0
                }
                
                self.lastCollapseFailureAt = Date()
                self.state = .idle
                self.onStateChange?(.idle)
                self.onCollapseFailed?(failureMessage)
                return
            }
            
            // Mark the display as created during collapse to prevent rebuilds from tearing down connections
            if let streamFleet = StreamFleet.shared {
                streamFleet.markCollapseCreatedDisplay(virtualID)
            }
            
            if self.dualMode {
                self.virtualDisplay.create(preset: self.presetB, slot: .b) { secondID in
                    if secondID == nil {
                        clog("dual mode: display B creation failed — continuing single-display")
                    } else if let streamFleet = StreamFleet.shared {
                        // Mark the second display as created during collapse too
                        streamFleet.markCollapseCreatedDisplay(secondID!)
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
            // Release the display wake assertion if it was created
            if self.displayWakeAssertion != 0 {
                IOPMAssertionRelease(self.displayWakeAssertion)
                self.displayWakeAssertion = 0
            }
            
            // Clear collapse-created displays after a delay to allow normal rebuilds for external changes
            if let streamFleet = StreamFleet.shared {
                streamFleet.clearCollapseCreatedDisplays()
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
        
        // Release the display wake assertion if it was created (this can happen 
        // when restore is called due to a failed collapse)
        if displayWakeAssertion != 0 {
            IOPMAssertionRelease(displayWakeAssertion)
            displayWakeAssertion = 0
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
            guard let userInfo else { return }
            
            // If a display was removed (sleeping), we should notify any active StreamServers
            if flags.contains(.removeFlag) {
                let coordinator = Unmanaged<CollapseCoordinator>.fromOpaque(userInfo).takeUnretainedValue()
                DispatchQueue.main.async { 
                    coordinator.displayRemoved(displayID)
                }
            } else if flags.contains(.addFlag) {
                // Handle display added event if needed - no action required for our purposes
            }
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

    private func mirrorPhysicalDisplays(onto virtualID: CGDirectDisplayID, attempt: Int = 1) {
        let physical = activePhysicalDisplays()
        guard !physical.isEmpty else {
            // CGGetActiveDisplayList under-reports for the full WindowServer
            // settle window after the virtual display is created -- observed
            // live at ~17s (same window the repeated "no HiDPI mode" retries
            // span) -- not a quick transient blip. A short retry budget gave
            // up before the list ever populated, leaving the virtual display
            // permanently unmirrored, showing as an extra independent screen.
            clog("mirrorPhysicalDisplays: no physical displays found (attempt \(attempt)/20)")
            guard state == .collapsing || state == .collapsed, attempt < 20 else {
                clog("mirrorPhysicalDisplays: giving up after \(attempt) attempts")
                return
            }
            
            // Wake the display if it's asleep before retrying - this fixes Bug 1
            if attempt == 1 {
                let result = IOPMAssertionDeclareUserActivity(
                    "Clamshell collapse" as CFString,
                    kIOPMUserActiveLocal,
                    &displayWakeAssertion
                )
                clog("Display wake assertion declared: \(result == kIOReturnSuccess ? "ok" : "FAILED")")
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.mirrorPhysicalDisplays(onto: virtualID, attempt: attempt + 1)
            }
            return
        }

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

    // MARK: - Crash/force-quit recovery

    /// `mirroredDisplays`/`state` only track what THIS process instance did —
    /// if a previous instance crashed or was force-quit mid-collapse (no
    /// `applicationWillTerminate` ran), its mirror relationship survives at
    /// the OS level with no in-memory record anywhere to undo it. A fresh
    /// launch's `restore()` is then a no-op (`state` starts `.idle`), leaving
    /// real displays permanently mirroring a dead/orphaned virtual display —
    /// confirmed live 2026-08-01: a real MacBook display stayed mirrored onto
    /// an orphaned virtual display through multiple quit+relaunch cycles,
    /// because the in-memory `mirroredDisplays` tracking used by the normal
    /// restore path only ever reflects this process's own actions.
    ///
    /// This scans the LIVE display list — ground truth, independent of any
    /// process's memory — and un-mirrors anything currently mirroring
    /// anything else. Called on every launch, before any collapse of our own
    /// could possibly exist yet, so it can never undo a real one we're
    /// mid-setting-up. Doesn't (can't) destroy the orphaned virtual display
    /// itself — that needs the original `CGVirtualDisplay` object, which is
    /// gone once its owning process exits without calling `destroy()` — but
    /// un-mirroring is what actually matters: it's what makes the real
    /// screens show a real desktop again instead of a dead framebuffer.
    static func recoverOrphanedMirrors() {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)

        let mirrored = ids.prefix(Int(count)).filter { CGDisplayMirrorsDisplay($0) != 0 }
        guard !mirrored.isEmpty else { return }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else {
            clog("recoverOrphanedMirrors: CGBeginDisplayConfiguration failed")
            return
        }
        for id in mirrored {
            CGConfigureDisplayMirrorOfDisplay(cfg, id, kCGNullDirectDisplay)
        }
        let err = CGCompleteDisplayConfiguration(cfg, .permanently)
        clog("recoverOrphanedMirrors: found \(mirrored.count) display(s) stuck mirroring from a prior instance, un-mirrored: \(err == .success ? "ok" : "error \(err.rawValue)")")
    }
}
