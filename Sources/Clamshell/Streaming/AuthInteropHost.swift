#if DEBUG
import CoreGraphics
import Foundation

// A real stream listener for the client interop tests
// (tests/test-webclient-auth-interop.js and tests/WindowsViewerInterop), which
// check the web client's auth.js and the Windows client flow against this
// host. Nothing else uses it, and it is compiled into debug builds only.
//
// One listener on this machine's loopback address, not primary, with
// `startsMedia` off so that a HELLO starts no capture and no input injector
// (the server counts the starts, and the gate selftest checks the count stays
// at zero), device approval on, no Bonjour. The device list
// lives in the directory named by CLAMSHELL_STATE_DIR, so the test can run
// `clamshell approve` and `clamshell revoke` against the same directory. The
// host refuses to start without that variable, with a directory that does not
// exist, or with this user's real state directory. It ends by itself after
// `lifetime` seconds.
//
// `clamshell auth-interop-host <port>`.

enum AuthInteropHost {
    /// The longest this process lives, whatever happens to the test that started it.
    static let lifetime: TimeInterval = 120

    static func run(_ args: [String]) -> Int32 {
        guard args.count == 1, let raw = UInt16(args[0]), raw >= 1024 else {
            print("usage: clamshell auth-interop-host <port, 1024 or higher>")
            return 64
        }
        guard let given = ProcessInfo.processInfo.environment["CLAMSHELL_STATE_DIR"], !given.isEmpty else {
            print("refusing to start: CLAMSHELL_STATE_DIR is not set")
            return 64
        }
        let stateDir = URL(fileURLWithPath: given, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: stateDir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            print("refusing to start: CLAMSHELL_STATE_DIR is not an existing directory")
            return 64
        }
        let defaultDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Clamshell", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        if let defaultDir, defaultDir.path == stateDir.path {
            print("refusing to start: CLAMSHELL_STATE_DIR is this user's real state directory")
            return 64
        }

        // Watching is on: `clamshell approve` and `revoke` run as other
        // processes and this one has to notice what they save.
        let auth = HostAuth(directory: stateDir, requireApproval: true, watch: true)
        let server = StreamServer(source: .display(CGMainDisplayID()), port: raw, isPrimary: false,
                                  auth: auth, displayIndex: 0, loopbackOnly: true, startsMedia: false)
        do {
            try server.start()
        } catch {
            print("could not listen on port \(raw): \(error)")
            return 1
        }
        print("auth-interop-host listening on 127.0.0.1:\(raw)")
        fflush(stdout)

        // Block here: the listener runs on its own queue.
        let done = DispatchSemaphore(value: 0)
        var signalSources: [DispatchSourceSignal] = []
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { done.signal() }
            source.resume()
            signalSources.append(source)
        }
        _ = done.wait(timeout: .now() + lifetime)
        withExtendedLifetime(signalSources) {}

        let stopped = DispatchGroup()
        stopped.enter()
        server.stop { stopped.leave() }
        _ = stopped.wait(timeout: .now() + 5)
        return 0
    }
}
#endif
