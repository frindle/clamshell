import AppKit

// CLI smoke tests, usable before the menu bar app is trusted with anything:
//   clamshell test-virtual-display   create the virtual display for 10s, then tear down
//   clamshell test-detect            print current remote-session detection state
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
        let controller = VirtualDisplayController()
        guard let id = controller.create(preset: .iPadAir13) else {
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
        var list = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &list, &count)
        var ids = Array(list.prefix(Int(count)))
        if ids.isEmpty { ids = [CGMainDisplayID()] }
        if let mainIdx = ids.firstIndex(of: CGMainDisplayID()), mainIdx != 0 { ids.swapAt(0, mainIdx) }
        var servers: [StreamServer] = []
        for (i, id) in ids.enumerated() {
            let server = StreamServer(displayID: id, port: basePort + UInt16(i), isPrimary: i == 0)
            do { try server.start() } catch {
                print("FAILED to start stream server on port \(basePort + UInt16(i)): \(error)")
                exit(1)
            }
            servers.append(server)
        }
        print("Streaming \(ids.count) display(s) on ports \(basePort)–\(basePort + UInt16(ids.count - 1)) — ctrl-C to stop")
        withExtendedLifetime(servers) { RunLoop.main.run() }
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
    default:
        print("Unknown command: \(args[1])")
        print("Usage: clamshell [test-virtual-display | test-detect | reboot-readiness]")
        exit(64)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
