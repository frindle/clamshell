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

        let handoff = HandoffManager()
        handoff.send = { [weak m] data in m?.link.send(data) }
        handoff.peerHost = { [weak m] in m?.peerHost }
        // The carrying drag: the peer's injected button while it drives
        // this Mac, else the physical one.
        handoff.isCarryHeld = { [weak m] in
            guard let m else { return false }
            return m.sink.active ? m.sink.carrying : CGEventSource.buttonState(.hidSystemState, button: .left)
        }
        handoff.onChange = { [weak m] in m?.onChange() }
        m.handoff = handoff
        m.edgeController.carryDetector.receiverLookup = { [weak handoff] n in handoff?.sourceWindowId(forWindowNumber: n) }
        m.sink.carryDetector.receiverLookup = { [weak handoff] n in handoff?.sourceWindowId(forWindowNumber: n) }

        m.featureLinked.append { clipboard.start() }
        m.featureUnlinked.append { clipboard.stop(); files.reset(); handoff.reset() }
        m.featureRoutes.append { t, p in clipboard.receive(type: t, payload: p) }
        m.featureRoutes.append { t, p in files.receive(type: t, payload: p) }
        m.featureRoutes.append { t, p in handoff.receive(type: t, payload: p) }

        // Drag-and-drop. Files carried across an edge are sent when the
        // button is released on the other side (this Mac drove the drag), or
        // as soon as the peer's cursor leaves (the peer drove a drag that
        // started here). A window is handed off the moment it crosses; one
        // of our receiver windows crossing goes home.
        func carried(_ carry: Carry, _ detector: CarryDetector, _ peerEdge: PeerEdge, _ fraction: CGFloat) {
            switch carry {
            case .files: break
            case .window(let id, let pid, let frame, let title, let app, let grab):
                handoff.begin(windowId: id, pid: pid, frame: frame, title: title, app: app, grab: grab,
                              preDragOrigin: detector.pressedFrame?.origin, peerEdge: peerEdge, position: fraction)
            case .receiver(let src):
                handoff.returnReceiver(src, edge: peerEdge, position: fraction)
            }
        }
        m.edgeController.onCarryCrossed = { [weak m] carry, edge, fraction in
            guard let m else { return }
            carried(carry, m.edgeController.carryDetector, edge, fraction)
        }
        m.edgeController.onCarryDropped = { carry in
            if case .files(let urls) = carry { files.send(urls: urls) }
        }
        m.onPeerLeftCarrying = { [weak m] carry, edge, fraction in
            guard let m else { return }
            if case .files(let urls) = carry { files.send(urls: urls) }
            carried(carry, m.sink.carryDetector, edge, fraction)
        }
    }

    static func menuItems(for m: PeerManager) -> [NSMenuItem] {
        guard m.state.isLinked else { return [] }
        let send = NSMenuItem(title: "Send Files to \(m.peerName ?? "Peer")…", action: #selector(PeerFeatureActions.sendFiles(_:)), keyEquivalent: "")
        send.target = PeerFeatureActions.shared
        send.representedObject = m
        var items: [NSMenuItem] = [.separator(), send]
        if let h = m.handoff, h.outgoingCount > 0 {
            let back = NSMenuItem(title: "Bring Back Handed-off Windows (\(h.outgoingCount))", action: #selector(PeerFeatureActions.bringBack(_:)), keyEquivalent: "")
            back.target = PeerFeatureActions.shared
            back.representedObject = m
            items.append(back)
        }
        return items
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

    @objc func bringBack(_ sender: NSMenuItem) {
        (sender.representedObject as? PeerManager)?.handoff?.bringBackAll()
    }
}
