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
    case "test-detect":
        let trigger = ConnectionMonitor.detectActiveSession()
        print("Remote session: \(trigger.map { "ACTIVE via \($0.rawValue)" } ?? "none")")
        exit(0)
    default:
        print("Unknown command: \(args[1])")
        print("Usage: clamshell [test-virtual-display | test-detect]")
        exit(64)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
