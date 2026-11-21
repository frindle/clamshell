import Foundation

// Small decisions that keep a launch (and an update) from getting stuck. No
// keychain, processes or files here, so they are unit-tested directly.

/// When Clamshell may ask the keychain for the device protection key with the
/// system allowed to show its "allow access" dialog. Launch never does; this
/// is only for a background retry.
enum IntegrityKeyPolicy {
    /// Ask only when the key could not be read quietly, the screen is
    /// unlocked (somebody can answer the dialog) and no ask is already open.
    static func shouldAsk(keyUnreadable: Bool, screenLocked: Bool, askInFlight: Bool) -> Bool {
        keyUnreadable && !screenLocked && !askInFlight
    }
}

/// Runs a keychain read that is not allowed to show anything, but never makes
/// the caller wait longer than `timeout`. The legacy file keychain can still
/// raise its dialog for a quiet read; the read then sits there until someone
/// answers. While one is stuck, later reads fail at once instead of piling up.
final class BoundedRead {
    struct TimedOut: Error, CustomStringConvertible {
        let waited: Bool
        var description: String {
            waited ? "the keychain did not answer in time (it may be waiting for the user)"
                   : "an earlier keychain read is still waiting"
        }
    }

    private final class Box { var result: Result<Data?, Error>? }

    private let lock = NSLock()
    private var inFlight = false
    private let queue = DispatchQueue(label: "clamshell.bounded-keychain-read", qos: .utility, attributes: .concurrent)

    func run(timeout: TimeInterval, _ body: @escaping () throws -> Data?) throws -> Data? {
        lock.lock()
        if inFlight { lock.unlock(); throw TimedOut(waited: false) }
        inFlight = true
        lock.unlock()

        let done = DispatchSemaphore(value: 0)
        let box = Box()
        queue.async { [self] in
            let result: Result<Data?, Error>
            do { result = .success(try body()) } catch { result = .failure(error) }
            lock.lock()
            inFlight = false
            box.result = result
            lock.unlock()
            done.signal()
        }
        // On a timeout the read keeps going and its late answer is dropped.
        guard done.wait(timeout: .now() + timeout) == .success else { throw TimedOut(waited: true) }
        lock.lock()
        let finished = box.result
        lock.unlock()
        return try finished!.get()
    }
}

extension SafeUpdate {
    /// "v0.9.20" and "0.9.20" are the same version.
    static func bareVersion(_ v: String) -> String { v.hasPrefix("v") ? String(v.dropFirst()) : v }

    /// True when an automatic install should not take `tag`: the last update
    /// record says that version was installed and then rolled back, so
    /// installing it again would loop. Choosing it from the menu still works.
    static func shouldSkipAutoInstall(tag: String, lastRecord: Record?) -> Bool {
        guard let r = lastRecord, r.result == "rolled-back" else { return false }
        return bareVersion(r.to) == bareVersion(tag)
    }
}

/// Ending the other Clamshell processes before a rollback relaunch.
enum RollbackRestart {
    enum Step: Equatable {
        case done
        case wait
        case kill([Int32])
    }

    /// After SIGTERM: done when none is left, keep waiting until `grace`
    /// seconds passed, then SIGKILL what remains.
    static func nextStep(alive: [Int32], elapsed: TimeInterval, grace: TimeInterval = 5) -> Step {
        if alive.isEmpty { return .done }
        return elapsed < grace ? .wait : .kill(alive)
    }

    /// The relaunch counts only when something is running from the installed
    /// path and none of it is a process that was there before.
    static func relaunched(before: [Int32], now: [Int32]) -> Bool {
        !now.isEmpty && Set(now).isDisjoint(with: before)
    }
}
