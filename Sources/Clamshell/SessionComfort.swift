import Foundation

/// Quality-of-life behaviors that apply only while collapsed.
final class SessionComfort {
    /// Sole owner of every display power assertion (session hold and the
    /// pre-mirror wake), so one call can drop them all.
    private let awake: DisplayAwakeGuard

    init(awake: DisplayAwakeGuard = DisplayAwakeGuard()) {
        self.awake = awake
    }

    /// Mute the Mac's physical speakers while remote (so a desk speaker
    /// doesn't play the session's audio to an empty room). Off by default —
    /// harmless, but surprising if you don't know it's there.
    var muteWhileCollapsed = UserDefaults.standard.bool(forKey: "muteWhileCollapsed")

    /// Whether `sessionDidStart` takes the display-awake hold. Off for
    /// collapses commanded from outside (the streaming host keeps the
    /// display awake itself while it streams).
    var holdDisplayAwake = true

    func sessionDidStart() {
        // Keep the display awake for the duration of the remote session;
        // an idle-slept display stalls some clients on reconnect.
        // Skipped for externally commanded collapses: nothing tells us when
        // such a stream dies, so a hold could outlive it forever.
        if holdDisplayAwake && !awake.isHolding {
            let ok = awake.hold(reason: "Clamshell remote session active")
            clog("display-sleep assertion: \(ok ? "on" : "FAILED")")
        }
        if muteWhileCollapsed {
            setMuted(true)
        }
    }

    /// Wake a sleeping display so its displays show up for mirroring. Dropped
    /// by `displayWakeDone()` or `sessionDidEnd()`.
    func wakeDisplayForCollapse() {
        awake.wake(reason: "Clamshell collapse")
        clog("display wake declared: \(awake.isWakeDeclared ? "ok" : "FAILED")")
    }

    /// Mirroring finished or was given up on; let the display idle normally.
    func displayWakeDone() {
        awake.releaseWake()
    }

    /// Drops every display assertion. Safe at any time, any number of times.
    func releasePowerAssertions() {
        if awake.releaseAll() {
            clog("display power assertions released")
        }
    }

    func sessionDidEnd() {
        releasePowerAssertions()
        if muteWhileCollapsed {
            setMuted(false)
        }
    }

    private func setMuted(_ muted: Bool) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "set volume output muted \(muted)"]
        try? task.run()
        task.waitUntilExit()
        clog("speakers \(muted ? "muted" : "unmuted")")
    }
}
