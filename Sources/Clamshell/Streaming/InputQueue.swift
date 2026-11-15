import Foundation
import CoreGraphics

// One ordered path for every injected event (mouse, scroll, key, text). Events
// are enqueued in arrival order and posted from a single process-wide serial
// queue, so a modifier and a click sent together keep their order, a click
// after a long text lands after all of it, and two sessions never post at
// once. Per-session state lives in each InputQueue instance.
//
// Rules:
//  - The backlog is bounded (events and text bytes). Over the bound new events
//    are dropped, except releases (mouse up, key up), which are always taken.
//  - `releaseAll` (end of session) abandons everything still waiting, then
//    posts an up for exactly what this queue has POSTED as down and not yet
//    as up, and afterwards posts nothing more. A down that was posted is
//    always released; one that was not posted is simply dropped.
//  - The pacing sleep follows keyboard work only.

final class InputQueue {
    static let maxBacklogEvents = 4096
    static let maxBacklogTextBytes = 64 * 1024

    /// Shared by every InputQueue in the process.
    private static let serial = DispatchQueue(label: "clamshell.input")

    private let sink: (InputEvent) -> Void
    private let cursor: () -> CGPoint
    private let delayMicros: UInt32
    private let onFirstDrop: () -> Void

    // Guarded by `lock`.
    private let lock = NSLock()
    private var pendingEvents = 0
    private var pendingTextBytes = 0
    private var closed = false
    private var loggedDrop = false

    // Posting side: touched only on `serial`.
    private var postedButtons: [Int: Int] = [:] // button -> click count of its down
    private var postedButtonOrder: [Int] = []
    private var postedKeys: [UInt16] = []

    init(delayMicros: UInt32 = 1000,
         cursor: @escaping () -> CGPoint = { .zero },
         onFirstDrop: @escaping () -> Void = {},
         sink: @escaping (InputEvent) -> Void) {
        self.sink = sink
        self.cursor = cursor
        self.delayMicros = delayMicros
        self.onFirstDrop = onFirstDrop
    }

    /// True while events are waiting to be posted.
    var isBacklogged: Bool {
        lock.lock(); defer { lock.unlock() }
        return pendingEvents > 0
    }

    /// Whether a non-release event (carrying `textBytes` of text) would be
    /// accepted. Ask BEFORE running the event through InputCore, so a dropped
    /// down never becomes "held" there. Reports the first drop once.
    func hasRoom(textBytes: Int = 0) -> Bool {
        lock.lock()
        let ok = !closed && pendingEvents < Self.maxBacklogEvents
            && pendingTextBytes + textBytes <= Self.maxBacklogTextBytes
        var first = false
        if !ok && !closed && !loggedDrop { loggedDrop = true; first = true }
        lock.unlock()
        if first { onFirstDrop() }
        return ok
    }

    /// Enqueues events in arrival order. Returns false when they were dropped.
    /// Releases (mouse up, key up) are always accepted while the queue is open.
    @discardableResult
    func enqueue(_ events: [InputEvent], textBytes: Int = 0) -> Bool {
        guard !events.isEmpty else { return true }
        let releaseOnly = events.allSatisfy(Self.isRelease)
        lock.lock()
        if closed { lock.unlock(); return false }
        // A text batch is checked on its bytes and on whether the backlog is
        // already full, not on its own event count: a valid 16 KB INPUT_TEXT
        // can expand to more events than the bound and must still go through.
        let overBound = textBytes > 0
            ? pendingEvents >= Self.maxBacklogEvents
            : pendingEvents + events.count > Self.maxBacklogEvents
        if !releaseOnly,
           overBound || pendingTextBytes + textBytes > Self.maxBacklogTextBytes {
            let first = !loggedDrop
            loggedDrop = true
            lock.unlock()
            if first { onFirstDrop() }
            return false
        }
        pendingEvents += events.count
        pendingTextBytes += textBytes
        lock.unlock()

        Self.serial.async { [self] in
            for e in events {
                lock.lock(); let stop = closed; lock.unlock()
                if !stop { post(e) }
                lock.lock(); pendingEvents -= 1; lock.unlock()
            }
            lock.lock(); pendingTextBytes -= textBytes; lock.unlock()
        }
        return true
    }

    /// End of session: abandon what is waiting, release what was posted, and
    /// post nothing more.
    func releaseAll() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        lock.unlock()
        Self.serial.async { [self] in
            let here = cursor()
            for b in postedButtonOrder.reversed() {
                sink(.mouse(.up, button: b, point: here, clickCount: postedButtons[b] ?? 1, delta: nil))
            }
            for k in postedKeys.reversed() {
                sink(.key(code: k, down: false, flags: 0))
            }
            postedButtons = [:]
            postedButtonOrder = []
            postedKeys = []
        }
    }

    /// Blocks until everything queued so far (by anyone) has run (tests).
    static func drain() { serial.sync {} }

    private static func isRelease(_ e: InputEvent) -> Bool {
        switch e {
        case .mouse(let action, _, _, _, _): return action == .up
        case .key(_, let down, _): return !down
        default: return false
        }
    }

    // On `serial`.
    private func post(_ e: InputEvent) {
        switch e {
        case .mouse(.down, let b, _, let count, _):
            if postedButtons[b] == nil { postedButtonOrder.append(b) }
            postedButtons[b] = count
        case .mouse(.up, let b, _, _, _):
            postedButtons[b] = nil
            postedButtonOrder.removeAll { $0 == b }
        case .key(let code, true, _):
            if !postedKeys.contains(code) { postedKeys.append(code) }
        case .key(let code, false, _):
            postedKeys.removeAll { $0 == code }
        default: break
        }
        sink(e)
        switch e {
        case .key, .text: if delayMicros > 0 { usleep(delayMicros) }
        default: break
        }
    }
}
