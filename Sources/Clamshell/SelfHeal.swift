import AppKit
import CoreGraphics

/// Confirms (or rules out) that a virtual-display creation failure is the
/// known orphaned-virtual-display signature: a display from a *prior*
/// Clamshell instance that macOS never actually tore down at the WindowServer
/// level, even though that instance released its CGVirtualDisplay reference.
///
/// A fresh attempt to create a display with the same fixed vendor/product/
/// serial (see VirtualDisplayController.vendorID/productID/serialNum) then
/// fails every time, because WindowServer still considers that identity
/// registered.
///
/// `CGDisplayVendorNumber`/`CGDisplayModelNumber`/`CGDisplaySerialNumber` are
/// public CoreGraphics (Quartz Display Services) calls — not the private
/// CGVirtualDisplay API this file otherwise steers clear of — and they DO
/// see virtual displays: they just read back the descriptor fields
/// createOnce() set at creation time. `CGGetOnlineDisplayList` (not
/// `CGGetActiveDisplayList`) is used deliberately: a phantom display can be
/// online-but-inactive, and CollapseCoordinator.recoverOrphanedMirrors()
/// already established the online list is the right ground truth for
/// orphan detection elsewhere in this codebase.
enum PhantomDisplayDetector {
    /// Scans the live (online) display list for one whose vendor/product/
    /// serial match the identity a slot is about to try to claim. Always
    /// logs which way the check came out — this is the evidence trail that
    /// makes the self-relaunch decision below auditable after the fact.
    static func matchingDisplayPresent(vendorID: UInt32, productID: UInt32, serialNum: UInt32,
                                        slot: VirtualSlot) -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            clog("phantom check (slot \(slot.rawValue)): no online displays reported — cannot be a registered phantom")
            return false
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else {
            clog("phantom check (slot \(slot.rawValue)): CGGetOnlineDisplayList (second call) failed — treating as not found")
            return false
        }
        for id in ids.prefix(Int(count)) {
            let v = CGDisplayVendorNumber(id)
            let p = CGDisplayModelNumber(id)
            let s = CGDisplaySerialNumber(id)
            if v == vendorID, p == productID, s == serialNum {
                clog("phantom check (slot \(slot.rawValue)): FOUND — display id=\(id) advertises vendor=\(v) product=\(p) serial=\(s), matching this slot's identity. Still registered at WindowServer despite our side having released it.")
                return true
            }
        }
        clog("phantom check (slot \(slot.rawValue)): none of \(count) online display(s) match vendor=\(vendorID) product=\(productID) serial=\(serialNum) — creation failure has some other cause")
        return false
    }
}

/// Last-resort self-heal: relaunch the whole app when virtual-display
/// creation has exhausted its retries against a *confirmed* phantom, since
/// the only thing that's ever been observed to actually clear one (two
/// independent live checks) is the owning process fully exiting.
///
/// Split into a pure, injectable guard decision (`shouldAttemptRelaunch`,
/// unit-testable) and the actual spawn+terminate side effect
/// (`performRelaunch`, NOT unit-testable — it really does launch a process
/// and call NSApp.terminate). `attemptSelfRelaunch` is what production code
/// calls; it's the guard followed by the real action.
enum SelfRelaunchGuard {
    static let lastRelaunchKey = "selfHealLastRelaunchAt"

    /// Rare-but-real event, not a tight loop: a stuck phantom from a prior
    /// instance is something that, per tonight's live evidence, can persist
    /// for 90+ minutes and then hold indefinitely. 10 minutes is long enough
    /// that if something pathological makes every fresh instance immediately
    /// re-hit the same phantom (e.g. WindowServer never releasing it even
    /// across a real relaunch), the guard trips almost immediately after the
    /// first attempt instead of letting the app relaunch-loop — while being
    /// short enough that a second, genuinely separate occurrence hours later
    /// isn't blocked by a stale guard.
    static let cooldown: TimeInterval = 600

    /// Pure(ish) guard decision: is a relaunch allowed right now? If yes,
    /// records the attempt timestamp (so a second call right after, even
    /// before the spawn completes, is correctly blocked) and returns true.
    /// `defaults`/`now` are injectable so the crash-loop guard itself is
    /// testable without touching real UserDefaults or real time.
    static func shouldAttemptRelaunch(defaults: UserDefaults = .standard, now: Date = Date()) -> Bool {
        if let last = defaults.object(forKey: lastRelaunchKey) as? Date {
            let elapsed = now.timeIntervalSince(last)
            if elapsed < cooldown {
                clog("self-relaunch BLOCKED by crash-loop guard: last relaunch was \(Int(elapsed))s ago (cooldown \(Int(cooldown))s)")
                return false
            }
        }
        defaults.set(now, forKey: lastRelaunchKey)
        return true
    }

    /// Spawns a fresh instance of this same app bundle, then terminates the
    /// current process — in that order, so there's never a gap with no
    /// running instance and no menu-bar icon. UserDefaults (nativeStreaming,
    /// webAccess, etc.) persists across this automatically; no in-flight
    /// collapse/stream state is preserved on purpose — the viewer's existing
    /// forever-retry-with-backoff reconnect is what's meant to pick things
    /// back up once the fresh instance is healthy.
    static func performRelaunch(reason: String) {
        let bundleURL = Bundle.main.bundleURL
        clog("self-relaunch TRIGGERED: \(reason) — spawning fresh instance at \(bundleURL.path)")
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { app, error in
            DispatchQueue.main.async {
                if let error {
                    clog("self-relaunch FAILED: openApplication error: \(error.localizedDescription) — NOT terminating this process (would leave no running instance and no menu-bar icon)")
                    return
                }
                let pidString = app.map { String($0.processIdentifier) } ?? "?"
                clog("self-relaunch: fresh instance launched (pid \(pidString)) — terminating this process now")
                NSApp.terminate(nil)
            }
        }
    }

    /// Guard check + real action, for production call sites.
    @discardableResult
    static func attemptSelfRelaunch(reason: String, defaults: UserDefaults = .standard, now: Date = Date()) -> Bool {
        guard shouldAttemptRelaunch(defaults: defaults, now: now) else { return false }
        performRelaunch(reason: reason)
        return true
    }
}
