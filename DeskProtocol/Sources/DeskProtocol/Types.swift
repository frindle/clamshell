/// Message type bytes. 0x40-0x4C are the v2 proposal, adopted; 0x70-0x85 are new in v3.
/// 0x01-0x5C and 0x60-0x61 are v1 (StreamProtocol.swift) and are not repeated here.
/// Tests compare every value below against the real v1 enum.
public enum DeskType: UInt8 {
    // Window handoff (v2 proposal, adopted)
    case windowListRequest = 0x40
    case windowListResponse = 0x41
    case handoffBegin = 0x42
    case handoffAccept = 0x43
    case handoffReject = 0x44
    case windowStreamStart = 0x45
    case windowStreamFrame = 0x46
    case windowInputMouseMove = 0x47
    case handoffReturn = 0x48
    case windowClosed = 0x49
    case windowInputMouseButton = 0x4A
    case windowInputKey = 0x4B
    case windowInputScroll = 0x4C
    // App host (v3)
    case appLaunch = 0x70
    case appList = 0x71
    case windowAdded = 0x72
    case windowMoved = 0x73
    case windowResized = 0x74
    case windowTitle = 0x75
    case windowResizeRequest = 0x76
    case childWindow = 0x77
    case menuTree = 0x78
    case menuInvoke = 0x79
    case cursorShape = 0x7A
    case pasteboardOffer = 0x7B
    case pasteboardFetch = 0x7C
    case filePush = 0x7D
    case filePull = 0x7E
    case audioFrame = 0x7F
    case badge = 0x80
    case notify = 0x81
    case appListRequest = 0x82
    case pasteboardData = 0x83
    case appLaunchResult = 0x84
    case filePromise = 0x85
}

public enum WindowKind: UInt8, Equatable {
    case main = 0, sheet = 1, popover = 2, menu = 3, tooltip = 4, other = 255
    init(wire: UInt8) { self = WindowKind(rawValue: wire) ?? .other }
}

public enum CursorShape: UInt8, Equatable {
    case arrow = 0, iBeam = 1, pointingHand = 2, crosshair = 3
    case resizeLeftRight = 4, resizeUpDown = 5, openHand = 6, closedHand = 7, notAllowed = 8
    /// Followed by hotspot and PNG bytes.
    case custom = 255
}

/// Window geometry in points on the host's hosted display, plus the backing scale.
public struct Geometry: Equatable {
    public var x: Float, y: Float, width: Float, height: Float, scale: Float
    public init(x: Float, y: Float, width: Float, height: Float, scale: Float) {
        self.x = x; self.y = y; self.width = width; self.height = height; self.scale = scale
    }
}

/// One entry of the v2 WINDOW_LIST_RESPONSE.
public struct WindowInfo: Equatable {
    public var windowId: UInt32
    public var title: String
    public var appName: String
    public var widthPx: UInt32
    public var heightPx: UInt32
    public init(windowId: UInt32, title: String, appName: String, widthPx: UInt32, heightPx: UInt32) {
        self.windowId = windowId; self.title = title; self.appName = appName; self.widthPx = widthPx; self.heightPx = heightPx
    }
}

/// One entry of APP_LIST.
public struct AppInfo: Equatable {
    public var appId: UInt32
    public var bundleId: String
    public var name: String
    public var pid: Int32
    public var windowCount: UInt16
    public var residentMB: UInt32
    public var running: Bool
    public init(appId: UInt32, bundleId: String, name: String, pid: Int32, windowCount: UInt16, residentMB: UInt32, running: Bool) {
        self.appId = appId; self.bundleId = bundleId; self.name = name; self.pid = pid
        self.windowCount = windowCount; self.residentMB = residentMB; self.running = running
    }
}

public struct MenuItem: Equatable {
    public static let noShortcut: UInt16 = 0xFFFF
    public var itemId: UInt32
    public var title: String
    public var enabled: Bool
    public var checked: Bool
    public var separator: Bool
    /// Mac virtual key code, or `noShortcut`.
    public var keyCode: UInt16
    /// CGEventFlags low 32 bits.
    public var modifiers: UInt32
    public var children: [MenuItem]
    public init(itemId: UInt32, title: String, enabled: Bool = true, checked: Bool = false, separator: Bool = false,
                keyCode: UInt16 = MenuItem.noShortcut, modifiers: UInt32 = 0, children: [MenuItem] = []) {
        self.itemId = itemId; self.title = title; self.enabled = enabled; self.checked = checked; self.separator = separator
        self.keyCode = keyCode; self.modifiers = modifiers; self.children = children
    }
}

public struct PasteboardEntry: Equatable {
    public var uti: String
    public var size: UInt64
    public init(uti: String, size: UInt64) { self.uti = uti; self.size = size }
}

public struct FilePromiseEntry: Equatable {
    public var fileId: UInt32
    public var name: String
    public var size: UInt64
    public init(fileId: UInt32, name: String, size: UInt64) { self.fileId = fileId; self.name = name; self.size = size }
}

/// Capability bits (PROTOCOL.md "Capabilities"). Bits 0-8 are v1; the tests check this one against them.
public enum DeskCapability {
    public static let appHost: UInt32 = 1 << 9
}

public enum FileName {
    public static let maxBytes = 255

    /// Characters that never belong in a received name: invisible, bidirectional and line-separator characters, and
    /// look-alikes for dot and slash. The same set the v1 receiver strips ("File transfer" receiver rules).
    static func isForbiddenScalar(_ v: UInt32) -> Bool {
        // Everything the v1 receiver removes or replaces (FileTransferCore.storedName): the whole Unicode format category
        // (tag characters U+E0020..E007F included), the line and paragraph separators and the look-alike set below.
        if let s = Unicode.Scalar(v), s.properties.generalCategory == .format { return true }
        if v == 0x2028 || v == 0x2029 || lookAlikeSeparators.contains(v) { return true }
        if v < 0x20 || v == 0x7F || (v >= 0x80 && v <= 0x9F) { return true }          // C0, DEL, C1 controls
        switch v {
        case 0x00AD, 0x061C, 0x180E, 0x3164, 0xFEFF: return true                        // soft hyphen, Arabic mark, fillers, BOM
        case 0x200B...0x200F, 0x2028...0x202E, 0x2060...0x206F, 0xFFF9...0xFFFB: return true // zero-width, bidi, separators, invisible operators
        case 0xFF0E, 0xFF61, 0x3002, 0x2215, 0x2044, 0xFF0F, 0x29F8, 0xFE52, 0x2024, 0x2CFA: return true // look-alike dots and slashes
        default: return false
        }
    }

    /// Same list as the v1 receiver's `lookAlikeSeparators`; the cross-check test fails if the two drift apart.
    static let lookAlikeSeparators: Set<UInt32> = [
        0xFF0E, 0xFE52, 0xFF61, 0x3002, 0x2024, 0x2215, 0x2044, 0xFF0F, 0x29F8, 0x2571, 0x2216, 0xFF3C, 0xFE68, 0x29F5, 0x2CFA,
    ]

    /// A blank in the v1 sense: a space, any Unicode white space or a space separator (U+00A0, U+3000 and the like).
    static func isBlank(_ u: Unicode.Scalar) -> Bool {
        u == " " || u.properties.isWhitespace || u.properties.generalCategory == .spaceSeparator
    }

    /// A bare file name that is safe to hand to any receiver as is: not empty, at most 255 UTF-8 bytes; no `/`, `\`,
    /// `:` or Windows-reserved `< > " | ? *`; no control, invisible, bidirectional or look-alike characters; does not
    /// start with a dot or any Unicode blank, does not end with a dot or blank; not a Windows device name.
    public static func isSafe(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard !u.isEmpty, u.count <= maxBytes else { return false }
        for v in s.unicodeScalars {
            if isForbiddenScalar(v.value) { return false }
            switch v {
            case "/", "\\", ":", "<", ">", "\"", "|", "?", "*": return false
            default: break
            }
        }
        guard let first = s.unicodeScalars.first, let last = s.unicodeScalars.last else { return false }
        if first == "." || isBlank(first) || last == "." || isBlank(last) { return false }
        let stem = String(s.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first ?? "").uppercased()
        let devices: Set<String> = ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"]
        if devices.contains(stem) { return false }
        if stem.count == 4, stem.hasPrefix("COM") || stem.hasPrefix("LPT"), let d = stem.last, d >= "1" && d <= "9" { return false }
        return true
    }
}
