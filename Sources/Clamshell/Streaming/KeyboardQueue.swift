import Foundation

// Serial queue for every injected keyboard event, so typed text and INPUT_KEY
// events reach the host in the order they arrived. The sink does the actual
// posting; tests pass a recording sink and a zero delay.
//
// Rules:
//  - A text job may be abandoned (by `releaseAll`) only between units of work:
//    one text chunk, or one Return/Tab press pair. Never between a down and
//    its up.
//  - Queued key events are never abandoned.
//  - `releaseAll` enqueues the held keys' ups after everything already queued.
//    Nothing here holds the owner weakly, so the release still runs after the
//    owner has been dropped.

final class KeyboardQueue {
    static let maxBacklogBytes = 64 * 1024

    enum TextResult: Equatable {
        case accepted
        /// Dropped because too much text is waiting. `first` is true for the
        /// first drop of this queue's life (log it once).
        case dropped(first: Bool)
    }

    private let queue: DispatchQueue
    private let sink: (InputEvent) -> Void
    private let delayMicros: UInt32
    private let lock = NSLock()
    private var generation = 0
    private var pendingTextBytes = 0
    private var loggedDrop = false

    init(label: String = "clamshell.input.keyboard", delayMicros: UInt32 = 1000, sink: @escaping (InputEvent) -> Void) {
        queue = DispatchQueue(label: label)
        self.sink = sink
        self.delayMicros = delayMicros
    }

    /// INPUT_KEY events: always posted, in order.
    func enqueueKey(_ events: [InputEvent]) {
        guard !events.isEmpty else { return }
        queue.async { [sink, delayMicros] in
            for e in events { sink(e) }
            if delayMicros > 0 { usleep(delayMicros) }
        }
    }

    /// INPUT_TEXT events (from `InputCore.text`). `byteCount` is the payload size
    /// used for the backlog bound.
    func enqueueText(_ events: [InputEvent], byteCount: Int) -> TextResult {
        guard !events.isEmpty else { return .accepted }
        lock.lock()
        if pendingTextBytes + byteCount > Self.maxBacklogBytes {
            let first = !loggedDrop
            loggedDrop = true
            lock.unlock()
            return .dropped(first: first)
        }
        pendingTextBytes += byteCount
        let gen = generation
        lock.unlock()

        let units = Self.units(events)
        queue.async { [self] in
            for unit in units {
                lock.lock(); let current = generation; lock.unlock()
                if current != gen { break } // released: abandon the rest
                for e in unit { sink(e) }
                if delayMicros > 0 { usleep(delayMicros) }
            }
            lock.lock(); pendingTextBytes -= byteCount; lock.unlock()
        }
        return .accepted
    }

    /// Abandons text not yet started and enqueues `ups` (the held keys' release
    /// events) behind whatever is already queued.
    func releaseAll(_ ups: [InputEvent]) {
        lock.lock(); generation += 1; lock.unlock()
        guard !ups.isEmpty else { return }
        queue.async { [sink] in
            for e in ups { sink(e) }
        }
    }

    /// Blocks until everything queued so far has run (tests).
    func drain() { queue.sync {} }

    /// Splits text events into indivisible units: a chunk, or a key down+up pair.
    private static func units(_ events: [InputEvent]) -> [[InputEvent]] {
        var out: [[InputEvent]] = []
        var i = 0
        while i < events.count {
            if case .key(_, true, _) = events[i], i + 1 < events.count, case .key(_, false, _) = events[i + 1] {
                out.append([events[i], events[i + 1]])
                i += 2
            } else {
                out.append([events[i]])
                i += 1
            }
        }
        return out
    }
}
