import Foundation
import AppKit

// Plain-text clipboard sync for the primary connection. macOS has no pasteboard
// change notification, so we poll NSPasteboard.changeCount — the standard
// approach — and push new text to the iPad; inbound text is written back and
// the change count re-baselined so it isn't echoed straight back.
//
// ponytail: 0.5s poll, plain text only. Fine for a remote-desktop clipboard;
// no rich-text / image sync until someone actually needs it.

final class ClipboardBridge {
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: DispatchSourceTimer?

    /// Local pasteboard changed — send this text to the client.
    var onLocalChange: ((String) -> Void)?

    init() { lastChangeCount = pasteboard.changeCount }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }

    private func poll() {
        let c = pasteboard.changeCount
        guard c != lastChangeCount else { return }
        lastChangeCount = c
        if let s = pasteboard.string(forType: .string) { onLocalChange?(s) }
    }

    func receiveFromClient(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastChangeCount = pasteboard.changeCount // don't echo our own write back
    }
}
