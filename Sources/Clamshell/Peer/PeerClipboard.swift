import AppKit

// Clipboard sync with a linked peer (PROTOCOL.md "Peer link — clipboard"):
// copy on one machine, paste on the other. Text rides the v1 CLIPBOARD
// message (UTF-8); images ride CLIPBOARD_DATA kind 1 (PNG), the one image
// format both macOS and Windows put on their clipboards natively. Whatever
// was copied last on either side wins. Anything larger than
// PeerLimits.maxClipboardBytes isn't synced (logged).
//
// Same polling approach as the v1 ClipboardBridge (macOS has no pasteboard
// change notification): changeCount checked twice a second on main, and our
// own writes re-baseline it so they aren't echoed back.
//
// Not synced: copied *files* (Finder puts file URLs, not contents, on the
// pasteboard — use drag-and-drop or Send File, which transfer the bytes),
// rich text/HTML (plain text only).

final class PeerClipboard {
    enum Kind: UInt8 { case png = 1 }

    private let pasteboard: NSPasteboard
    private var lastChangeCount: Int
    private var timer: Timer?
    var send: (Data) -> Void = { _ in }

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        lastChangeCount = pasteboard.changeCount
    }

    /// Starts watching; the current contents are NOT pushed (only new copies).
    func start() {
        lastChangeCount = pasteboard.changeCount
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func poll() {
        let c = pasteboard.changeCount
        guard c != lastChangeCount else { return }
        lastChangeCount = c
        if let text = pasteboard.string(forType: .string) {
            let bytes = Data(text.utf8)
            guard bytes.count <= PeerLimits.maxClipboardBytes else {
                clog("PEER: clipboard text too large to sync (\(bytes.count) bytes)"); return
            }
            send(StreamMessage.clipboard(text: text))
        } else if let png = Self.pngData(from: pasteboard) {
            guard png.count <= PeerLimits.maxClipboardBytes else {
                clog("PEER: clipboard image too large to sync (\(png.count) bytes)"); return
            }
            send(StreamMessage.clipboardData(kind: Kind.png.rawValue, bytes: png))
        }
    }

    /// Returns true when the message was a clipboard message.
    func receive(type: StreamMessageType, payload: Data) -> Bool {
        switch type {
        case .clipboard:
            guard payload.count <= PeerLimits.maxClipboardBytes,
                  let text = String(data: payload, encoding: .utf8) else { return true }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        case .clipboardData:
            guard let (kind, bytes) = PeerParse.clipboardData(payload), kind == Kind.png.rawValue,
                  let rep = NSBitmapImageRep(data: bytes) else { return true } // must decode as an image
            // Offer PNG plus TIFF: many Mac apps only paste TIFF.
            pasteboard.clearContents()
            pasteboard.declareTypes([.png, .tiff], owner: nil)
            pasteboard.setData(bytes, forType: .png)
            if let tiff = rep.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
        default:
            return false
        }
        lastChangeCount = pasteboard.changeCount // don't echo our own write back
        return true
    }

    private static func pngData(from pb: NSPasteboard) -> Data? {
        if let png = pb.data(forType: .png) { return png }
        if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .png, properties: [:])
        }
        return nil
    }
}
