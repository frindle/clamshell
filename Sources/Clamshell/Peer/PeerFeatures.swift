import AppKit

// Attaches the shared-desk feature modules (clipboard, files, window
// handoff) to a PeerManager and wires the drag-and-drop triggers between
// them. One place, so the menu bar app and `clamshell peer` get exactly the
// same behaviour.
enum PeerFeatures {
    static func install(on m: PeerManager, downloads: URL = FileTransfer.downloadsDirectory,
                        reveal: Bool = true) {
        let clipboard = PeerClipboard()
        clipboard.send = { [weak m] data in m?.link.send(data) }
        m.clipboard = clipboard

        let files = FileTransfer(directory: downloads)
        files.send = { [weak m] data, done in
            guard let m else { done(); return }
            m.link.send(data, completion: done)
        }
        if reveal {
            files.onReceived = { url in
                DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
        m.files = files

        m.featureLinked.append { clipboard.start() }
        m.featureUnlinked.append { clipboard.stop(); files.reset() }
        m.featureRoutes.append { t, p in clipboard.receive(type: t, payload: p) }
        m.featureRoutes.append { t, p in files.receive(type: t, payload: p) }

        // Drag-and-drop: files carried across an edge are sent when the
        // button is released on the other side (this Mac drove the drag),
        // or as soon as the peer's cursor leaves (the peer drove a drag
        // that started here).
        m.edgeController.onCarryDropped = { carry in
            if case .files(let urls) = carry { files.send(urls: urls) }
        }
        m.onPeerLeftCarrying = { carry, _, _ in
            if case .files(let urls) = carry { files.send(urls: urls) }
        }
    }

    static func menuItems(for m: PeerManager) -> [NSMenuItem] {
        guard m.state.isLinked else { return [] }
        let send = NSMenuItem(title: "Send Files to \(m.peerName ?? "Peer")…", action: #selector(PeerFeatureActions.sendFiles(_:)), keyEquivalent: "")
        send.target = PeerFeatureActions.shared
        send.representedObject = m
        return [.separator(), send]
    }
}

final class PeerFeatureActions: NSObject {
    static let shared = PeerFeatureActions()

    @objc func sendFiles(_ sender: NSMenuItem) {
        guard let m = sender.representedObject as? PeerManager else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Files and folders to send (folders go as .zip) — they land in the peer's Downloads."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        m.files?.send(urls: panel.urls)
    }
}
