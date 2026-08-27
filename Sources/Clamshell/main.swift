import AppKit

// CLI smoke tests, usable before the menu bar app is trusted with anything:
//   clamshell test-virtual-display   create the virtual display for 10s, then tear down
//   clamshell test-detect            print current remote-session detection state
//
// SCContentFilter(desktopIndependentWindow:) (window-capture-selftest) hits
// "CGS_REQUIRE_INIT" without an active WindowServer connection, unlike the
// display-based filter other capture paths use -- touching NSApplication.shared
// this early forces that connection before any capture code runs.
_ = NSApplication.shared

let args = CommandLine.arguments
if args.count > 1 {
    switch args[1] {
    case "collapse", "restore":
        // Signal the running menu bar app (e.g. from Sunshine prep-commands
        // for instant, event-driven collapse instead of waiting on the poll).
        // `collapse` accepts optional client pixel dimensions so Sunshine's
        // SUNSHINE_CLIENT_WIDTH/HEIGHT env vars size the virtual display to
        // the connecting device: Clamshell collapse 2266 1488
        var info: [AnyHashable: Any] = [:]
        if args.count >= 4, let w = UInt32(args[2]), let h = UInt32(args[3]), w > 0, h > 0 {
            info["width"] = String(w)
            info["height"] = String(h)
        }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.frindle.clamshell.\(args[1])"),
            object: nil, userInfo: info, deliverImmediately: true
        )
        print("sent \(args[1])\(info.isEmpty ? "" : " \(info["width"]!)x\(info["height"]!)") to running Clamshell")
        exit(0)
    case "test-virtual-display":
        // Optional custom pixel size (e.g. `test-virtual-display 3440 1440`
        // to stand in for a physical ultrawide monitor when no real one is
        // available) — defaults to the iPad Air 13" preset.
        let preset: DisplayPreset
        if args.count >= 4, let w = UInt32(args[2]), let h = UInt32(args[3]) {
            preset = DisplayPreset(name: "custom \(w)x\(h)", pointsWide: w / 2, pointsHigh: h / 2)
        } else {
            preset = .iPadAir13
        }
        let controller = VirtualDisplayController()
        guard let id = controller.create(preset: preset) else {
            print("FAILED: could not create virtual display")
            exit(1)
        }
        print("Virtual display created (id \(id)) — check Displays settings. Tearing down in 10s…")
        Thread.sleep(forTimeInterval: 10)
        controller.destroy()
        print("Done.")
        exit(0)
    case "test-web":
        let server = WebServer()
        server.onSessionChange = { active in print("browser session active: \(active)") }
        server.start()
        guard server.isRunning else { print("FAILED to start web server"); exit(1) }
        print("Serving noVNC on http://localhost:\(server.httpPort) — ctrl-C to stop")
        RunLoop.main.run()
    case "stream":
        // Clamshell stream [basePort] — serve the custom video stream protocol
        // (PROTOCOL.md) for every active display, one server per display at
        // basePort+index. The main display is always index 0 (the base port);
        // it is the "primary" connection that also carries audio + clipboard.
        // Requires Screen Recording permission.
        let basePort = args.count > 2 ? (UInt16(args[2]) ?? streamDefaultPort) : streamDefaultPort
        // StreamFleet follows display topology changes: a client HELLO can
        // trigger a collapse that creates virtual display(s) mid-run, and
        // those must take over the ports (A at base, B at base+1).
        let fleet = StreamFleet(basePort: basePort)
        fleet.rebuild()
        guard fleet.isServing else {
            print("FAILED to start any stream server (ports in use?) — see log")
            exit(1)
        }
        print("Streaming from port \(basePort) (one port per active display, main first) — ctrl-C to stop")
        withExtendedLifetime(fleet) { RunLoop.main.run() }
    case "test-ultrawide-stream":
        // clamshell test-ultrawide-stream <width> <height> [basePort]
        // Combines test-virtual-display + stream, held open (no 10s teardown)
        // so an external client can actually connect — the sandbox test rig
        // for pan+zoom/cursor-follow (README "Manual pan+zoom &
        // cursor-follow auto-pan") when no real ultrawide monitor is on hand.
        guard args.count >= 4, let w = UInt32(args[2]), let h = UInt32(args[3]) else {
            print("Usage: clamshell test-ultrawide-stream <width> <height> [basePort]")
            exit(64)
        }
        let basePort = args.count > 4 ? (UInt16(args[4]) ?? streamDefaultPort) : streamDefaultPort
        let preset = DisplayPreset(name: "custom \(w)x\(h)", pointsWide: w / 2, pointsHigh: h / 2)
        let controller = VirtualDisplayController()
        guard let id = controller.create(preset: preset) else {
            print("FAILED: could not create \(w)x\(h) virtual display")
            exit(1)
        }
        print("Virtual display \(w)x\(h) created (id \(id))")
        let fleet = StreamFleet(basePort: basePort)
        fleet.rebuild()
        guard fleet.isServing else {
            print("FAILED to start any stream server (ports in use?) — see log")
            exit(1)
        }
        print("Streaming \(w)x\(h) from port \(basePort) — ctrl-C to stop")
        withExtendedLifetime((controller, fleet)) { RunLoop.main.run() }
    case "stream-selftest":
        // Hardware encode -> TCP loopback -> hardware decode sanity check.
        exit(StreamSelfTest.run() ? 0 : 1)
    case "reboot-readiness":
        // Print the unattended-reboot pre-flight (autorestart / FileVault /
        // Screen Sharing / login item). Same check as the menu item, usable
        // over SSH before you travel.
        print(RebootReadiness.summary(RebootReadiness.check()))
        exit(0)
    case "test-detect":
        let trigger = ConnectionMonitor.detectActiveSession()
        print("Remote session: \(trigger.map { "ACTIVE via \($0.rawValue)" } ?? "none")")
        exit(0)
    case "window-list":
        // First slice of Window Handoff (PROTOCOL.md "Window Handoff (v2,
        // PROPOSED)") -- enumerate capturable windows before building the
        // capture/stream/receiver pipeline. `clamshell window-list`.
        let sema = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 1
        Task {
            exitCode = await WindowList.run()
            sema.signal()
        }
        sema.wait()
        exit(exitCode)
    case "window-capture-selftest":
        // Second slice: prove single-window capture actually delivers
        // frames, not just enumerates. `clamshell window-capture-selftest
        // [windowId]` -- windowId from a prior `window-list` run, same
        // session (SCWindow IDs aren't stable across app relaunches).
        let windowId = args.count > 2 ? UInt32(args[2]) : nil
        let sema2 = DispatchSemaphore(value: 0)
        var exitCode2: Int32 = 1
        Task {
            exitCode2 = await WindowCaptureSelfTest.run(windowId: windowId)
            sema2.signal()
        }
        sema2.wait()
        exit(exitCode2)
    case "window-hide-selftest":
        // Third slice: prove the actual hiding mechanism -- move a window
        // off-screen via Accessibility (not minimize, which breaks capture)
        // and confirm window-capture-selftest still gets frames while it's
        // off-screen. `clamshell window-hide-selftest [windowId]`.
        let windowId3 = args.count > 2 ? UInt32(args[2]) : nil
        let sema3 = DispatchSemaphore(value: 0)
        var exitCode3: Int32 = 1
        Task {
            exitCode3 = await WindowHideSelfTest.run(windowId: windowId3)
            sema3.signal()
        }
        sema3.wait()
        exit(exitCode3)
    case "stream-window":
        // `clamshell stream-window <windowId> [port]` -- Window Handoff v1
        // (PROTOCOL.md "Window Handoff"): serve ONE window over the exact
        // same protocol as `stream` (HELLO/VIDEO_FRAME/INPUT_*), reusing
        // StreamServer with source: .window(id) instead of .display(id).
        // windowId comes from `window-list`, same session (SCWindow IDs
        // aren't stable across app relaunches). No AX auto-hide/drag-trigger
        // (blocked on this dev Mac, see WindowHideSelfTest.swift) -- explicit
        // selection only, this command IS the selection UI for v1.
        guard args.count > 2, let windowId = UInt32(args[2]) else {
            print("Usage: clamshell stream-window <windowId> [port]")
            print("Run `clamshell window-list` first to find a windowId.")
            exit(64)
        }
        let winPort = args.count > 3 ? (UInt16(args[3]) ?? windowStreamDefaultPort) : windowStreamDefaultPort
        let winServer = StreamServer(source: .window(windowId), port: winPort, isPrimary: false)
        do {
            try winServer.start()
        } catch {
            print("FAILED to start window stream server on port \(winPort): \(error)")
            exit(1)
        }
        print("Streaming window \(windowId) on port \(winPort) — ctrl-C to stop")
        withExtendedLifetime(winServer) { RunLoop.main.run() }
    case "window-at-cursor-selftest":
        // Fourth slice: prove the position->window lookup drag-trigger
        // detection needs (identify the window under the cursor at
        // drag-start) -- a different operation from window-hide-selftest's
        // failed CGWindowID<->AXUIElement matching. Passive: reads the real
        // cursor position, no synthetic input. `clamshell window-at-cursor-selftest`.
        exit(WindowAtCursorSelfTest.run())
    case "confirmation-bridge-selftest":
        exit(ConfirmationBridgeSelfTest.run())
    case "self-heal-guard-selftest":
        // Covers only SelfRelaunchGuard's crash-loop cooldown logic (pure,
        // injectable). Does NOT and cannot cover PhantomDisplayDetector
        // against a real WindowServer phantom, or performRelaunch actually
        // spawning/terminating a process — those need real hardware.
        exit(SelfHealGuardSelfTest.run())
    default:
        print("Unknown command: \(args[1])")
        print("Usage: clamshell [collapse | restore | test-virtual-display | test-web | stream | " +
              "test-ultrawide-stream | stream-selftest | reboot-readiness | test-detect | window-list | " +
              "window-capture-selftest | window-hide-selftest | window-at-cursor-selftest | stream-window | " +
              "self-heal-guard-selftest]")
        exit(64)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
