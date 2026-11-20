/// A decoded protocol message. Unknown type bytes decode to `.unknown` so a newer peer never breaks an older one.
public enum DeskMessage: Equatable {
    // v2 adopted
    case windowListRequest
    case windowListResponse([WindowInfo])
    case handoffBegin(windowId: UInt32, crossX: Float, crossY: Float, title: String, appName: String, widthPx: UInt32, heightPx: UInt32)
    case handoffAccept(windowId: UInt32)
    case handoffReject(windowId: UInt32, reason: String)
    case windowStreamStart(windowId: UInt32)
    case windowStreamFrame(windowId: UInt32, flags: UInt8, ptsMicros: UInt64, nal: [UInt8])
    case windowInputMouseMove(windowId: UInt32, x: Float, y: Float)
    case windowInputMouseButton(windowId: UInt32, button: UInt8, down: Bool, x: Float, y: Float)
    case windowInputKey(windowId: UInt32, macKeyCode: UInt16, down: Bool, cgEventFlags: UInt64)
    case windowInputScroll(windowId: UInt32, dx: Float, dy: Float)
    case handoffReturn(windowId: UInt32)
    case windowClosed(windowId: UInt32)
    // v3
    case appLaunch(requestId: UInt32, bundleId: String, activate: Bool, targets: [String])
    case appLaunchResult(requestId: UInt32, status: UInt8, appId: UInt32)
    case appListRequest
    case appList([AppInfo])
    case windowAdded(windowId: UInt32, appId: UInt32, kind: WindowKind, parentId: UInt32, title: String, geometry: Geometry)
    case windowMoved(windowId: UInt32, x: Float, y: Float)
    case windowResized(windowId: UInt32, width: Float, height: Float, scale: Float)
    case windowTitle(windowId: UInt32, title: String)
    case windowResizeRequest(windowId: UInt32, width: Float, height: Float)
    case childWindow(windowId: UInt32, parentId: UInt32, offsetX: Float, offsetY: Float, kind: WindowKind)
    case menuTree(appId: UInt32, generation: UInt32, items: [MenuItem])
    case menuInvoke(appId: UInt32, generation: UInt32, itemId: UInt32)
    case cursorShape(windowId: UInt32, shape: CursorShape, hotspotX: UInt16, hotspotY: UInt16, png: [UInt8])
    case pasteboardOffer(generation: UInt32, entries: [PasteboardEntry])
    case pasteboardFetch(generation: UInt32, uti: String)
    case pasteboardData(generation: UInt32, uti: String, data: [UInt8])
    case filePush(requestId: UInt32, windowId: UInt32, dropX: Float, dropY: Float, name: String)
    case filePull(requestId: UInt32, fileId: UInt32)
    case filePromise([FilePromiseEntry])
    case audioFrame(appId: UInt32, ptsMicros: UInt64, aac: [UInt8])
    case badge(appId: UInt32, text: String)
    case notify(appId: UInt32, notificationId: String, title: String, subtitle: String, body: String, sound: Bool)
    case unknown(type: UInt8, payload: [UInt8])
}

public enum Limits {
    public static let maxListEntries = 4096
    public static let maxMenuNodes = 4096
    public static let maxMenuDepth = 16
    public static let maxCursorPNG = 64 * 1024
}

extension DeskMessage {
    public var typeByte: UInt8 {
        switch self {
        case .windowListRequest: return DeskType.windowListRequest.rawValue
        case .windowListResponse: return DeskType.windowListResponse.rawValue
        case .handoffBegin: return DeskType.handoffBegin.rawValue
        case .handoffAccept: return DeskType.handoffAccept.rawValue
        case .handoffReject: return DeskType.handoffReject.rawValue
        case .windowStreamStart: return DeskType.windowStreamStart.rawValue
        case .windowStreamFrame: return DeskType.windowStreamFrame.rawValue
        case .windowInputMouseMove: return DeskType.windowInputMouseMove.rawValue
        case .windowInputMouseButton: return DeskType.windowInputMouseButton.rawValue
        case .windowInputKey: return DeskType.windowInputKey.rawValue
        case .windowInputScroll: return DeskType.windowInputScroll.rawValue
        case .handoffReturn: return DeskType.handoffReturn.rawValue
        case .windowClosed: return DeskType.windowClosed.rawValue
        case .appLaunch: return DeskType.appLaunch.rawValue
        case .appLaunchResult: return DeskType.appLaunchResult.rawValue
        case .appListRequest: return DeskType.appListRequest.rawValue
        case .appList: return DeskType.appList.rawValue
        case .windowAdded: return DeskType.windowAdded.rawValue
        case .windowMoved: return DeskType.windowMoved.rawValue
        case .windowResized: return DeskType.windowResized.rawValue
        case .windowTitle: return DeskType.windowTitle.rawValue
        case .windowResizeRequest: return DeskType.windowResizeRequest.rawValue
        case .childWindow: return DeskType.childWindow.rawValue
        case .menuTree: return DeskType.menuTree.rawValue
        case .menuInvoke: return DeskType.menuInvoke.rawValue
        case .cursorShape: return DeskType.cursorShape.rawValue
        case .pasteboardOffer: return DeskType.pasteboardOffer.rawValue
        case .pasteboardFetch: return DeskType.pasteboardFetch.rawValue
        case .pasteboardData: return DeskType.pasteboardData.rawValue
        case .filePush: return DeskType.filePush.rawValue
        case .filePull: return DeskType.filePull.rawValue
        case .filePromise: return DeskType.filePromise.rawValue
        case .audioFrame: return DeskType.audioFrame.rawValue
        case .badge: return DeskType.badge.rawValue
        case .notify: return DeskType.notify.rawValue
        case .unknown(let t, _): return t
        }
    }

    /// The payload bytes only (no framing).
    public func encodePayload() -> [UInt8] {
        var w = ByteWriter()
        switch self {
        case .windowListRequest, .appListRequest: break
        case .windowListResponse(let list):
            let items = list.prefix(Limits.maxListEntries)
            w.u16(UInt16(items.count))
            for i in items { w.u32(i.windowId); w.str8(i.title); w.str8(i.appName); w.u32(i.widthPx); w.u32(i.heightPx) }
        case .handoffBegin(let id, let cx, let cy, let title, let app, let wpx, let hpx):
            w.u32(id); w.f32(cx); w.f32(cy); w.str8(title); w.str8(app); w.u32(wpx); w.u32(hpx)
        case .handoffAccept(let id), .windowStreamStart(let id), .handoffReturn(let id), .windowClosed(let id):
            w.u32(id)
        case .handoffReject(let id, let reason): w.u32(id); w.str8(reason)
        case .windowStreamFrame(let id, let flags, let pts, let nal): w.u32(id); w.u8(flags); w.u64(pts); w.raw(nal)
        case .windowInputMouseMove(let id, let x, let y): w.u32(id); w.f32(x); w.f32(y)
        case .windowInputMouseButton(let id, let b, let down, let x, let y): w.u32(id); w.u8(b); w.bool(down); w.f32(x); w.f32(y)
        case .windowInputKey(let id, let code, let down, let flags): w.u32(id); w.u16(code); w.bool(down); w.u64(flags)
        case .windowInputScroll(let id, let dx, let dy): w.u32(id); w.f32(dx); w.f32(dy)
        case .appLaunch(let req, let bundle, let activate, let targets):
            w.u32(req); w.str16(bundle); w.bool(activate)
            let t = targets.prefix(Limits.maxListEntries)
            w.u16(UInt16(t.count)); for s in t { w.str16(s) }
        case .appLaunchResult(let req, let status, let appId): w.u32(req); w.u8(status); w.u32(appId)
        case .appList(let apps):
            let a = apps.prefix(Limits.maxListEntries)
            w.u16(UInt16(a.count))
            for i in a {
                w.u32(i.appId); w.str16(i.bundleId); w.str16(i.name); w.u32(UInt32(bitPattern: i.pid))
                w.u16(i.windowCount); w.u32(i.residentMB); w.bool(i.running)
            }
        case .windowAdded(let id, let app, let kind, let parent, let title, let g):
            w.u32(id); w.u32(app); w.u8(kind.rawValue); w.u32(parent); w.str16(title)
            w.f32(g.x); w.f32(g.y); w.f32(g.width); w.f32(g.height); w.f32(g.scale)
        case .windowMoved(let id, let x, let y): w.u32(id); w.f32(x); w.f32(y)
        case .windowResized(let id, let wd, let ht, let scale): w.u32(id); w.f32(wd); w.f32(ht); w.f32(scale)
        case .windowTitle(let id, let t): w.u32(id); w.str16(t)
        case .windowResizeRequest(let id, let wd, let ht): w.u32(id); w.f32(wd); w.f32(ht)
        case .childWindow(let id, let parent, let ox, let oy, let kind): w.u32(id); w.u32(parent); w.f32(ox); w.f32(oy); w.u8(kind.rawValue)
        case .menuTree(let app, let gen, let items):
            w.u32(app); w.u32(gen)
            var budget = Limits.maxMenuNodes
            DeskMessage.writeMenu(items, depth: 1, budget: &budget, into: &w)
        case .menuInvoke(let app, let gen, let item): w.u32(app); w.u32(gen); w.u32(item)
        case .cursorShape(let id, let shape, let hx, let hy, let png):
            w.u32(id); w.u8(shape.rawValue)
            if shape == .custom { w.u16(hx); w.u16(hy); w.raw(Array(png.prefix(Limits.maxCursorPNG))) }
        case .pasteboardOffer(let gen, let entries):
            let e = entries.prefix(255)
            w.u32(gen); w.u8(UInt8(e.count)); for x in e { w.str16(x.uti); w.u64(x.size) }
        case .pasteboardFetch(let gen, let uti): w.u32(gen); w.str16(uti)
        case .pasteboardData(let gen, let uti, let data): w.u32(gen); w.str16(uti); w.raw(data)
        case .filePush(let req, let win, let dx, let dy, let name):
            w.u32(req); w.u32(win); w.f32(dx); w.f32(dy); w.str16(name)
        case .filePull(let req, let id): w.u32(req); w.u32(id)
        case .filePromise(let files):
            let f = files.prefix(Limits.maxListEntries)
            w.u16(UInt16(f.count)); for x in f { w.u32(x.fileId); w.str16(x.name); w.u64(x.size) }
        case .audioFrame(let app, let pts, let aac): w.u32(app); w.u64(pts); w.raw(aac)
        case .badge(let app, let text): w.u32(app); w.str16(text)
        case .notify(let app, let nid, let title, let sub, let body, let sound):
            w.u32(app); w.str16(nid); w.str16(title); w.str16(sub); w.str16(body); w.bool(sound)
        case .unknown(_, let payload): w.raw(payload)
        }
        return w.bytes
    }

    /// Type byte, length and payload. Throws for a frame over the size limit or a file name that breaks the rule.
    public func encodeFrame() throws -> [UInt8] {
        switch self {
        case .filePush(_, _, _, _, let name) where !FileName.isSafe(name): throw EncodeError.unsafeFileName(name)
        case .filePromise(let files):
            for f in files.prefix(Limits.maxListEntries) where !FileName.isSafe(f.name) { throw EncodeError.unsafeFileName(f.name) }
        default: break
        }
        return try Framing.encode(type: typeByte, payload: encodePayload())
    }

    private static func writeMenu(_ items: [MenuItem], depth: Int, budget: inout Int, into w: inout ByteWriter) {
        // Encoder side of the limits: drop what would not decode, so we never emit an unreadable tree.
        let usable = depth <= Limits.maxMenuDepth ? Array(items.prefix(max(0, min(budget, 65535)))) : []
        budget -= usable.count
        w.u16(UInt16(usable.count))
        for i in usable {
            w.u32(i.itemId); w.str16(i.title)
            w.u8((i.enabled ? 1 : 0) | (i.checked ? 2 : 0) | (i.separator ? 4 : 0))
            w.u16(i.keyCode); w.u32(i.modifiers)
            writeMenu(i.children, depth: depth + 1, budget: &budget, into: &w)
        }
    }

    // MARK: decoding

    public static func decode(type: UInt8, payload: [UInt8]) throws -> DeskMessage {
        guard let t = DeskType(rawValue: type) else { return .unknown(type: type, payload: payload) }
        var r = ByteReader(payload)
        switch t {
        case .windowListRequest: return .windowListRequest
        case .appListRequest: return .appListRequest
        case .windowListResponse:
            let n = Int(try r.u16()); guard n <= Limits.maxListEntries else { throw DecodeError.tooManyItems }
            var out: [WindowInfo] = []
            for _ in 0..<n { out.append(WindowInfo(windowId: try r.u32(), title: try r.str8(), appName: try r.str8(), widthPx: try r.u32(), heightPx: try r.u32())) }
            return .windowListResponse(out)
        case .handoffBegin:
            return .handoffBegin(windowId: try r.u32(), crossX: try r.f32(), crossY: try r.f32(), title: try r.str8(), appName: try r.str8(), widthPx: try r.u32(), heightPx: try r.u32())
        case .handoffAccept: return .handoffAccept(windowId: try r.u32())
        case .windowStreamStart: return .windowStreamStart(windowId: try r.u32())
        case .handoffReturn: return .handoffReturn(windowId: try r.u32())
        case .windowClosed: return .windowClosed(windowId: try r.u32())
        case .handoffReject: return .handoffReject(windowId: try r.u32(), reason: try r.str8())
        case .windowStreamFrame: return .windowStreamFrame(windowId: try r.u32(), flags: try r.u8(), ptsMicros: try r.u64(), nal: r.rest())
        case .windowInputMouseMove: return .windowInputMouseMove(windowId: try r.u32(), x: try r.f32(), y: try r.f32())
        case .windowInputMouseButton: return .windowInputMouseButton(windowId: try r.u32(), button: try r.u8(), down: try r.bool(), x: try r.f32(), y: try r.f32())
        case .windowInputKey: return .windowInputKey(windowId: try r.u32(), macKeyCode: try r.u16(), down: try r.bool(), cgEventFlags: try r.u64())
        case .windowInputScroll: return .windowInputScroll(windowId: try r.u32(), dx: try r.f32(), dy: try r.f32())
        case .appLaunch:
            let req = try r.u32(), bundle = try r.str16(), activate = try r.bool()
            let n = Int(try r.u16()); guard n <= Limits.maxListEntries else { throw DecodeError.tooManyItems }
            var targets: [String] = []
            for _ in 0..<n { targets.append(try r.str16()) }
            return .appLaunch(requestId: req, bundleId: bundle, activate: activate, targets: targets)
        case .appLaunchResult: return .appLaunchResult(requestId: try r.u32(), status: try r.u8(), appId: try r.u32())
        case .appList:
            let n = Int(try r.u16()); guard n <= Limits.maxListEntries else { throw DecodeError.tooManyItems }
            var out: [AppInfo] = []
            for _ in 0..<n {
                out.append(AppInfo(appId: try r.u32(), bundleId: try r.str16(), name: try r.str16(), pid: Int32(bitPattern: try r.u32()),
                                   windowCount: try r.u16(), residentMB: try r.u32(), running: try r.bool()))
            }
            return .appList(out)
        case .windowAdded:
            let id = try r.u32(), app = try r.u32(), kind = WindowKind(wire: try r.u8()), parent = try r.u32(), title = try r.str16()
            let g = Geometry(x: try r.f32(), y: try r.f32(), width: try r.f32(), height: try r.f32(), scale: try r.f32())
            return .windowAdded(windowId: id, appId: app, kind: kind, parentId: parent, title: title, geometry: g)
        case .windowMoved: return .windowMoved(windowId: try r.u32(), x: try r.f32(), y: try r.f32())
        case .windowResized: return .windowResized(windowId: try r.u32(), width: try r.f32(), height: try r.f32(), scale: try r.f32())
        case .windowTitle: return .windowTitle(windowId: try r.u32(), title: try r.str16())
        case .windowResizeRequest: return .windowResizeRequest(windowId: try r.u32(), width: try r.f32(), height: try r.f32())
        case .childWindow: return .childWindow(windowId: try r.u32(), parentId: try r.u32(), offsetX: try r.f32(), offsetY: try r.f32(), kind: WindowKind(wire: try r.u8()))
        case .menuTree:
            let app = try r.u32(), gen = try r.u32()
            var budget = Limits.maxMenuNodes
            return .menuTree(appId: app, generation: gen, items: try readMenu(&r, depth: 1, budget: &budget))
        case .menuInvoke: return .menuInvoke(appId: try r.u32(), generation: try r.u32(), itemId: try r.u32())
        case .cursorShape:
            let id = try r.u32(), raw = try r.u8()
            guard let shape = CursorShape(rawValue: raw) else { throw DecodeError.badValue("cursor shape \(raw)") }
            if shape == .custom {
                let hx = try r.u16(), hy = try r.u16()
                guard r.remaining <= Limits.maxCursorPNG else { throw DecodeError.badValue("cursor image too large") }
                return .cursorShape(windowId: id, shape: shape, hotspotX: hx, hotspotY: hy, png: r.rest())
            }
            return .cursorShape(windowId: id, shape: shape, hotspotX: 0, hotspotY: 0, png: [])
        case .pasteboardOffer:
            let gen = try r.u32(), n = Int(try r.u8())
            var out: [PasteboardEntry] = []
            for _ in 0..<n { out.append(PasteboardEntry(uti: try r.str16(), size: try r.u64())) }
            return .pasteboardOffer(generation: gen, entries: out)
        case .pasteboardFetch: return .pasteboardFetch(generation: try r.u32(), uti: try r.str16())
        case .pasteboardData: return .pasteboardData(generation: try r.u32(), uti: try r.str16(), data: r.rest())
        case .filePush:
            let req = try r.u32(), win = try r.u32(), dx = try r.f32(), dy = try r.f32(), name = try r.str16()
            guard FileName.isSafe(name) else { throw DecodeError.badValue("unsafe file name") }
            return .filePush(requestId: req, windowId: win, dropX: dx, dropY: dy, name: name)
        case .filePull: return .filePull(requestId: try r.u32(), fileId: try r.u32())
        case .filePromise:
            let n = Int(try r.u16()); guard n <= Limits.maxListEntries else { throw DecodeError.tooManyItems }
            var out: [FilePromiseEntry] = []
            for _ in 0..<n {
                let id = try r.u32(), name = try r.str16(), size = try r.u64()
                guard FileName.isSafe(name) else { throw DecodeError.badValue("unsafe file name") }
                out.append(FilePromiseEntry(fileId: id, name: name, size: size))
            }
            return .filePromise(out)
        case .audioFrame: return .audioFrame(appId: try r.u32(), ptsMicros: try r.u64(), aac: r.rest())
        case .badge: return .badge(appId: try r.u32(), text: try r.str16())
        case .notify:
            return .notify(appId: try r.u32(), notificationId: try r.str16(), title: try r.str16(), subtitle: try r.str16(), body: try r.str16(), sound: try r.bool())
        }
    }

    public static func decode(_ frame: RawFrame) throws -> DeskMessage { try decode(type: frame.type, payload: frame.payload) }

    private static func readMenu(_ r: inout ByteReader, depth: Int, budget: inout Int) throws -> [MenuItem] {
        let n = Int(try r.u16())
        guard n == 0 || depth <= Limits.maxMenuDepth else { throw DecodeError.treeTooDeep }
        guard n <= budget else { throw DecodeError.tooManyItems }
        budget -= n
        var out: [MenuItem] = []
        for _ in 0..<n {
            let id = try r.u32(), title = try r.str16(), flags = try r.u8(), key = try r.u16(), mods = try r.u32()
            let kids = try readMenu(&r, depth: depth + 1, budget: &budget)
            out.append(MenuItem(itemId: id, title: title, enabled: flags & 1 != 0, checked: flags & 2 != 0, separator: flags & 4 != 0,
                                keyCode: key, modifiers: mods, children: kids))
        }
        return out
    }
}
