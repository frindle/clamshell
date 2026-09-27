import AppKit

// `clamshell peer [--edge left|right|top|bottom] [--connect host[:port]]
//                 [--pin 123456] [--port 5910] [--no-advertise] [--send path]`
//
// Runs the shared desk headless (no menu bar item) — the way to try it from
// a dev build without touching an installed Clamshell.app. Prints this
// Mac's pairing PIN, what it discovers and every link state change; ctrl-C
// stops it cleanly (control returns home, handed-off windows come back).
enum PeerCommand {
    static func run(_ args: [String]) -> Never {
        var edge: PeerEdge?
        var connect: (String, UInt16)?
        var pin: String?
        var port = peerLinkDefaultPort
        var advertise = true
        var sendPaths: [URL] = []
        var i = 0
        func value() -> String? { i += 1; return i < args.count ? args[i] : nil }
        while i < args.count {
            switch args[i] {
            case "--edge":
                guard let v = value(), let e = [PeerEdge.left, .right, .top, .bottom].first(where: { $0.name == v }) else { usage() }
                edge = e
            case "--connect":
                guard let v = value() else { usage() }
                connect = parseHostPort(v)
            case "--pin":
                guard let v = value(), v.count == 6, v.allSatisfy(\.isNumber) else { usage() }
                pin = v
            case "--port":
                guard let v = value(), let p = UInt16(v) else { usage() }
                port = p
            case "--send":
                guard let v = value() else { usage() }
                sendPaths.append(URL(fileURLWithPath: (v as NSString).expandingTildeInPath))
            case "--no-advertise":
                advertise = false
            default:
                usage()
            }
            i += 1
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let manager: PeerManager
        do {
            manager = try PeerManager.makeDefault(port: port)
            if let edge { manager.setEdge(edge) }
            PeerFeatures.install(on: manager)
            try manager.start(advertise: advertise)
        } catch {
            print("FAILED to start the peer link on port \(port): \(error)")
            exit(1)
        }
        print("Shared desk: \"\(manager.link.localName)\" id \(manager.identity.id.prefix(12))… on port \(port)")
        print("Peer is off this Mac's \(manager.edgeController.edge.name) edge (--edge to change). Pairing PIN for this Mac: \(manager.link.pairingPIN)")
        print("Ctrl+Opt+Cmd+L takes the mouse back if a peer stops answering. Ctrl-C to quit.")
        if !AXIsProcessTrusted() {
            print("WARNING: Accessibility not granted — this Mac can be controlled but can't control the peer.")
        }
        var lastLine = ""
        var lastPeers: [String] = []
        manager.onChange = {
            let line = manager.statusLine
            if line != lastLine { print("[\(Self.stamp())] \(line)"); lastLine = line }
            let peers = manager.discovered.map { p in
                "\(p.name)\(p.id.flatMap { manager.trust.peer(id: $0) } != nil ? " (paired)" : "")"
            }
            if manager.state.isLinked, !sendPaths.isEmpty {
                print("[\(Self.stamp())] sending \(sendPaths.map(\.lastPathComponent).joined(separator: ", "))")
                manager.files?.send(urls: sendPaths)
                sendPaths = []
            }
            if peers != lastPeers {
                print("[\(Self.stamp())] discovered: \(peers.isEmpty ? "none" : peers.joined(separator: ", "))")
                lastPeers = peers
            }
        }
        if let (host, p) = connect { manager.connect(host: host, port: p, pin: pin) }

        signal(SIGINT, SIG_IGN)
        let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sig.setEventHandler {
            print("\nstopping…")
            manager.stop { DispatchQueue.main.async { exit(0) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
        }
        sig.resume()
        withExtendedLifetime((manager, sig)) { app.run() }
        exit(0)
    }

    /// "host", "host:port", "[v6]", "[v6]:port" or a bare IPv6 address.
    static func parseHostPort(_ v: String) -> (String, UInt16) {
        if v.hasPrefix("["), let close = v.firstIndex(of: "]") {
            let host = String(v[v.index(after: v.startIndex)..<close])
            let rest = v[v.index(after: close)...]
            if rest.hasPrefix(":"), let p = UInt16(rest.dropFirst()) { return (host, p) }
            return (host, peerLinkDefaultPort)
        }
        let parts = v.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, let p = UInt16(parts[1]) { return (String(parts[0]), p) }
        return (v, peerLinkDefaultPort)
    }

    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: Date())
    }

    private static func usage() -> Never {
        print("Usage: clamshell peer [--edge left|right|top|bottom] [--connect host[:port]] [--pin NNNNNN] [--port N] [--no-advertise] [--send path]...")
        exit(64)
    }
}
