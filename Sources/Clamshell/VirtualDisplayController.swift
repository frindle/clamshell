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

        let newDisplay = CGVirtualDisplay(descriptor: descriptor)

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [
            CGVirtualDisplayMode(width: preset.pixelsWide, height: preset.pixelsHigh, refreshRate: 60),
        ]
        guard newDisplay.apply(settings) else {
            clog("applySettings failed for virtual display \(slot.rawValue)")
            return nil
        }
        displays[slot] = newDisplay
        clog("virtual display \(slot.rawValue) created: id=\(newDisplay.displayID) \(preset.name) (\(preset.pointsWide)x\(preset.pointsHigh) @2x)")
        return CGDirectDisplayID(newDisplay.displayID)
    }

    /// Destroys all virtual displays.
    func destroy() {
        for (slot, d) in displays {
            clog("destroying virtual display \(slot.rawValue) id=\(d.displayID)")
        }
        displays = [:] // releasing the instances removes the displays
    }
}
