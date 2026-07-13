import Foundation
import CoreGraphics
import CGVirtualDisplayShim

/// A resolution the virtual display can take, expressed in points.
/// The virtual display is created HiDPI (2x), so pixels = points * 2.
struct DisplayPreset: Equatable {
    let name: String
    let pointsWide: UInt32
    let pointsHigh: UInt32

    var pixelsWide: UInt32 { pointsWide * 2 }
    var pixelsHigh: UInt32 { pointsHigh * 2 }

    /// iPad Air 13" is 1366x1024 points (4:3). Rendering the virtual display
    /// at exactly that shape means the Screen Sharing client fills the iPad
    /// edge-to-edge with no letterboxing.
    static let iPadAir13 = DisplayPreset(name: "iPad Air 13\"", pointsWide: 1366, pointsHigh: 1024)
    static let iPadPro11 = DisplayPreset(name: "iPad Pro 11\"", pointsWide: 1194, pointsHigh: 834)
    static let iPadMini = DisplayPreset(name: "iPad mini", pointsWide: 1133, pointsHigh: 744)
    static let hd1080 = DisplayPreset(name: "1080p (16:9)", pointsWide: 1920, pointsHigh: 1080)
    static let all: [DisplayPreset] = [.iPadAir13, .iPadPro11, .iPadMini, .hd1080]
}

/// Which of the (at most two) virtual displays a call refers to. Single-display
/// mode only ever uses `.a`; dual display mode adds `.b`.
enum VirtualSlot: String {
    case a = "A"
    case b = "B"
}

/// Owns the lifecycle of the private-API virtual displays (up to two). Each
/// display exists exactly as long as its CGVirtualDisplay instance is retained.
final class VirtualDisplayController {
    private var displays: [VirtualSlot: CGVirtualDisplay] = [:]

    /// Per-slot timers that re-assert the HiDPI mode for a few seconds after
    /// creation (macOS may async-restore a stale saved mode).
    private var hiDPITimers: [VirtualSlot: Timer] = [:]

    var displayID: CGDirectDisplayID? { displayID(for: .a) }

    func displayID(for slot: VirtualSlot) -> CGDirectDisplayID? {
        displays[slot].map { CGDirectDisplayID($0.displayID) }
    }

    var isActive: Bool { !displays.isEmpty }

    /// Creates a virtual display in the given slot. Returns its display ID,
    /// or nil on failure.
    @discardableResult
    func create(preset: DisplayPreset, slot: VirtualSlot = .a) -> CGDirectDisplayID? {
        if displays[slot] != nil { return displayID(for: slot) }

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.name = slot == .a ? "Clamshell" : "Clamshell B"
        descriptor.queue = DispatchQueue.main
        descriptor.maxPixelsWide = preset.pixelsWide
        descriptor.maxPixelsHigh = preset.pixelsHigh
        // Physical size drives the default UI scale; 100 DPI-ish keeps text
        // sized sensibly. (25.4 mm per inch / 200 px per inch at 2x.)
        descriptor.sizeInMillimeters = CGSize(
            width: Double(preset.pixelsWide) * 25.4 / 200.0,
            height: Double(preset.pixelsHigh) * 25.4 / 200.0
        )
        descriptor.productID = 0xC1A5
        descriptor.vendorID = 0x5AE1
        descriptor.serialNum = slot == .a ? 1 : 2 // must differ or WindowServer treats them as one device

        // Observe unexpected system-side termination (WindowServer reclaiming
        // the display) so `displays`/`isActive` never report a dead ID. Our
        // own destroy() empties `displays` first, so the guard makes that
        // path a no-op here.
        descriptor.terminationHandler = { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, self.displays[slot] != nil else { return }
                clog("virtual display \(slot.rawValue) terminated unexpectedly by the system")
                self.displays[slot] = nil
                self.hiDPITimers[slot]?.invalidate()
                self.hiDPITimers[slot] = nil
            }
        }

        // Descriptor limits and the display mode are both in pixels
        // (maxPixelsWide == mode width == preset.pixelsWide) — verified
        // consistent; points only appear via DisplayPreset's 2x mapping.
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [
            CGVirtualDisplayMode(width: preset.pixelsWide, height: preset.pixelsHigh, refreshRate: 60),
        ]

        // Creation can fail transiently if a display with the same vendor/
        // product/serial is still registered (quick relaunch after a crash);
        // retry briefly. Blocking is fine — collapse() calls this
        // synchronously on the main queue and expects a result.
        var newDisplay: CGVirtualDisplay?
        for attempt in 1...8 {
            let candidate = CGVirtualDisplay(descriptor: descriptor)
            if candidate.apply(settings) {
                newDisplay = candidate
                break
            }
            clog("applySettings failed for virtual display \(slot.rawValue) (attempt \(attempt)/8)")
            if attempt < 8 { Thread.sleep(forTimeInterval: 0.25) }
        }
        guard let newDisplay else {
            clog("virtual display \(slot.rawValue) creation gave up after 8 attempts")
            return nil
        }

        displays[slot] = newDisplay
        let id = CGDirectDisplayID(newDisplay.displayID)
        clog("virtual display \(slot.rawValue) created: id=\(id) \(preset.name) (\(preset.pointsWide)x\(preset.pointsHigh) @2x)")
        startHiDPIEnforcement(id: id, preset: preset, slot: slot)
        return id
    }

    /// Destroys all virtual displays.
    func destroy() {
        for (slot, d) in displays {
            clog("destroying virtual display \(slot.rawValue) id=\(d.displayID)")
        }
        for timer in hiDPITimers.values { timer.invalidate() }
        hiDPITimers = [:]
        displays = [:] // releasing the instances removes the displays
    }

    // MARK: - HiDPI mode enforcement

    /// Applying settings with hiDPI=1 doesn't guarantee macOS runs the
    /// display at 2x — it may pick the 1x mode or async-restore a stale
    /// saved mode a few seconds later. Assert the mode now, then re-check
    /// every second for 6s (enforce, don't just set once), per slot.
    private func startHiDPIEnforcement(id: CGDirectDisplayID, preset: DisplayPreset, slot: VirtualSlot) {
        assertHiDPIMode(id: id, preset: preset, slot: slot)
        hiDPITimers[slot]?.invalidate()
        var ticks = 0
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self, self.displays[slot] != nil else { t.invalidate(); return }
            self.assertHiDPIMode(id: id, preset: preset, slot: slot)
            ticks += 1
            if ticks >= 6 {
                t.invalidate()
                self.hiDPITimers[slot] = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hiDPITimers[slot] = timer
    }

    private func assertHiDPIMode(id: CGDirectDisplayID, preset: DisplayPreset, slot: VirtualSlot) {
        // In the HiDPI mode, pixel size is the preset's pixel size and point
        // size (mode width/height) is half of it.
        if let current = CGDisplayCopyDisplayMode(id),
           current.pixelWidth == Int(preset.pixelsWide),
           current.pixelHeight == Int(preset.pixelsHigh),
           current.width == Int(preset.pointsWide) {
            return // already in the intended HiDPI mode
        }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue!] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode],
              let target = modes.first(where: {
                  $0.pixelWidth == Int(preset.pixelsWide)
                      && $0.pixelHeight == Int(preset.pixelsHigh)
                      && $0.width == Int(preset.pointsWide)
                      && $0.height == Int(preset.pointsHigh)
              }) else {
            clog("no HiDPI mode \(preset.pointsWide)x\(preset.pointsHigh)@2x found on virtual display \(slot.rawValue)")
            return
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else {
            clog("CGBeginDisplayConfiguration failed (HiDPI enforcement \(slot.rawValue))")
            return
        }
        CGConfigureDisplayWithDisplayMode(cfg, id, target, nil)
        let err = CGCompleteDisplayConfiguration(cfg, .permanently)
        clog("re-asserted HiDPI mode on virtual display \(slot.rawValue): \(err == .success ? "ok" : "error \(err.rawValue)")")
    }
}
