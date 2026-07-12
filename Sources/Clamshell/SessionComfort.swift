import Foundation
import IOKit.pwr_mgt

/// Quality-of-life behaviors that apply only while collapsed.
final class SessionComfort {
    private var sleepAssertion: IOPMAssertionID = 0
    private var hasAssertion = false

    /// Mute the Mac's physical speakers while remote (so a desk speaker
    /// doesn't play the session's audio to an empty room). Off by default —
    /// harmless, but surprising if you don't know it's there.
    var muteWhileCollapsed = UserDefaults.standard.bool(forKey: "muteWhileCollapsed")

    func sessionDidStart() {
        // Keep the display awake for the duration of the remote session;
        // an idle-slept display stalls some VNC clients on reconnect.
        if !hasAssertion {
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Clamshell remote session active" as CFString,
                &sleepAssertion
            )
            hasAssertion = result == kIOReturnSuccess
            clog("display-sleep assertion: \(hasAssertion ? "on" : "FAILED")")
        }
        if muteWhileCollapsed {
            setMuted(true)
        }
    }

    func sessionDidEnd() {
        if hasAssertion {
            IOPMAssertionRelease(sleepAssertion)
            hasAssertion = false
            clog("display-sleep assertion released")
        }
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
