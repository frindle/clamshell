/// Message type bytes. 0x40-0x4C are the v2 proposal, adopted; 0x60-0x74 are new in v3.
/// 0x01-0x5B are v1 and are not repeated here.
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
    case appLaunch = 0x60
    case appList = 0x61
    case windowAdded = 0x62
    case windowMoved = 0x63
    case windowResized = 0x64
    case windowTitle = 0x65
    case windowResizeRequest = 0x66
    case childWindow = 0x67
    case menuTree = 0x68
    case menuInvoke = 0x69
    case cursorShape = 0x6A
    case pasteboardOffer = 0x6B
    case pasteboardFetch = 0x6C
    case filePush = 0x6D
    case filePull = 0x6E
    case audioFrame = 0x6F
    case badge = 0x70
    case notify = 0x71
    case appListRequest = 0x72
    case pasteboardData = 0x73
    case appLaunchResult = 0x74
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

public enum FilePushKind: UInt8, Equatable {
    /// `path` is on shared storage; the receiver uses it directly.
    case sharedPath = 0
    /// `path` is the name the file will have in the host inbox; bytes follow as v1 FILE_OFFER/DATA/END.
    case inboxCopy = 1
}
