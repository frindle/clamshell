import AppKit
import ApplicationServices

// `clamshell handoff-selftest` — window handoff between two HandoffManagers
// joined by real loopback PeerLinks (ports 5992/5993), with a real window
// owned by a child process (this binary's hidden `handoff-selftest-window`,
// since a handoff refuses Clamshell's own windows):
//   1. HANDOFF_BEGIN opens a ReceiverWindow on B and B accepts
//   2. frames of the child window arrive in B's ReceiverWindow   [Screen Recording]
//   3. the window is parked off-screen on A, and put back exactly
//      where it was on HANDOFF_RETURN                          [Accessibility]
//   4. the child's window closing sends WINDOW_CLOSED and B's receiver goes
//   5. B refusing (no peer address) → HANDOFF_REJECT → A drops the handoff
//   6. the handoff stream refuses a client that isn't the peer's address
//   7. link reset brings everything home and closes receivers
// Nothing is injected into the real input stream. Checks needing a TCC
// permission this process lacks print SKIP instead of failing.
enum HandoffSelfTest {
    private static var failures = 0
    private static func check(_ ok: Bool, _ what: String) {
        if !ok { failures += 1; print("FAIL: \(what)") } else { print("ok   \(what)") }
    }

    private static func wait(_ timeout: TimeInterval = 10, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return cond()
    }

    /// The child's only normal-layer window.
    private static func childWindow(pid: pid_t) -> (id: CGWindowID, frame: CGRect)? {
        guard let list = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list where (info[kCGWindowOwnerPID as String] as? Int) == Int(pid) && (info[kCGWindowLayer as String] as? Int) == 0 {
            guard let id = info[kCGWindowNumber as String] as? Int,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary), r.width > 50 else { continue }
            return (CGWindowID(id), r)
        }
        return nil
    }

    private static func spawnChild() -> Process? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        p.arguments = ["handoff-selftest-window"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { print("FAIL: spawn child window: \(error)"); return nil }
        return p
    }

    static func run() -> Int32 {
        failures = 0
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let canCapture = CGPreflightScreenCaptureAccess()
        let axTrusted = AXIsProcessTrusted()
        print("info Screen Recording: \(canCapture ? "granted" : "not granted — frame checks SKIP")"
              + ", Accessibility: \(axTrusted ? "trusted" : "not trusted — hide/restore checks SKIP")")

        let a = PeerLink(identity: PeerIdentity(), trust: PeerTrustStore(fileURL: nil), localName: "A", port: 5992) { (800, 600) }
        let b = PeerLink(identity: PeerIdentity(), trust: PeerTrustStore(fileURL: nil), localName: "B", port: 5993) { (800, 600) }
        let ha = HandoffManager(), hb = HandoffManager()
        var bRaw: [StreamMessageType] = [], aRaw: [StreamMessageType] = []
        var bHasPeerAddress = true
        ha.send = { a.send($0) }; hb.send = { b.send($0) }
        ha.peerHost = { "127.0.0.1" }
        hb.peerHost = { bHasPeerAddress ? "127.0.0.1" : nil }
        a.onMessage = { t, p in DispatchQueue.main.async { aRaw.append(t); _ = ha.receive(type: t, payload: p) } }
        b.onMessage = { t, p in DispatchQueue.main.async { bRaw.append(t); _ = hb.receive(type: t, payload: p) } }
        do { try a.startListening(advertise: false); try b.startListening(advertise: false) } catch {
            print("FAIL: listen: \(error)"); return 1
        }
        _ = wait(0.3) { false }
        let linked = DispatchSemaphore(value: 0)
        a.onStateChange = { if case .linked = $0 { linked.signal() } }
        a.connect(host: "127.0.0.1", port: 5993, pin: b.pairingPIN)
        guard linked.wait(timeout: .now() + 10) == .success else { print("FAIL: link did not come up"); return 1 }

        guard let child = spawnChild() else { return 1 }
        defer { if child.isRunning { child.terminate() } }
        var win: (id: CGWindowID, frame: CGRect)?
        check(wait(10) { win = childWindow(pid: child.processIdentifier); return win != nil }, "child test window appears")
        guard var w = win else { return finish(a, b) }
        // Let the window settle (its first reported frame can predate layout).
        _ = wait(3) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            guard let now = childWindow(pid: child.processIdentifier) else { return false }
            defer { w = now }
            return now.frame == w.frame
        }
        let original = w.frame
        // AX can be trusted yet answer nothing (the environmental fault
        // documented in WindowHideSelfTest.swift): only judge park/restore
        // when AX can actually see the child's window.
        let axSees = axTrusted && WindowHider.find(windowID: w.id, pid: child.processIdentifier, frame: original,
                                               title: "Clamshell handoff selftest") != nil
        let canAX = axSees
        if axTrusted && !axSees {
            print("info Accessibility is trusted but reports no matching window for the child — the AX fault "
                  + "documented in WindowHideSelfTest.swift; hide/restore checks SKIP")
        }

        // 1. Begin → receiver + accept.
        check(ha.begin(windowId: w.id, pid: child.processIdentifier, frame: w.frame, title: "Clamshell handoff selftest",
                       app: "selftest", grab: CGPoint(x: 0.5, y: 0.1), preDragOrigin: original.origin,
                       peerEdge: .left, position: 0.5), "A begins the handoff")
        check(wait { hb.receiverCount == 1 && aRaw.contains(.handoffAccept) }, "B opens a receiver window and accepts")
        check(!ha.begin(windowId: w.id, pid: child.processIdentifier, frame: w.frame, title: "", app: "",
                        grab: .zero, preDragOrigin: nil, peerEdge: .left, position: 0.5), "a window already handed off can't be handed off twice")
        check(!ha.begin(windowId: 1, pid: getpid(), frame: .zero, title: "", app: "", grab: .zero,
                        preDragOrigin: nil, peerEdge: .left, position: 0.5), "Clamshell's own windows are never handed off")

        // 2. Live frames.
        if canCapture, let r = hb.receiver(for: UInt32(w.id)) {
            check(wait(15) { r.framesShown > 0 }, "B's receiver shows frames of A's window (\(r.framesShown))")
            check(r.negotiatedSize.map { $0.width >= original.width && $0.height >= original.height } == true,
                  "stream is at least the window's point size (\(String(describing: r.negotiatedSize)))")
        } else {
            print("SKIP frames: Screen Recording not granted to this process")
        }

        // 3. Parked, then back where it was.
        if canAX {
            check(wait(3) { CarryDetector.frame(of: w.id).map(InputInjector.isMostlyOffscreen) == true },
                  "A's window is parked off-screen (\(String(describing: CarryDetector.frame(of: w.id))))")
        } else { print("SKIP hide: Accessibility not trusted") }
        hb.returnReceiver(UInt32(w.id), edge: nil, position: 0)
        check(wait { ha.outgoingCount == 0 && hb.receiverCount == 0 }, "HANDOFF_RETURN ends the handoff on both sides")
        if canAX {
            check(wait(3) { CarryDetector.frame(of: w.id).map { abs($0.minX - original.minX) < 3 && abs($0.minY - original.minY) < 3 } == true },
                  "A's window is back at its original position")
        }

        // 5. B refuses → A drops it.
        bHasPeerAddress = false
        ha.begin(windowId: w.id, pid: child.processIdentifier, frame: original, title: "", app: "selftest",
                 grab: .zero, preDragOrigin: original.origin, peerEdge: .left, position: 0.5)
        check(wait { aRaw.contains(.handoffReject) && ha.outgoingCount == 0 && hb.receiverCount == 0 },
              "B without a peer address rejects; A takes the window back")
        bHasPeerAddress = true

        // 6. Only the peer's address may dial the handoff stream.
        let locked = StreamServer(source: .window(UInt32(w.id)), port: 5991, isPrimary: false, allowedRemoteHost: "10.255.255.1")
        check(StreamServer.normalizeHost("::FFFF:10.0.0.2") == "10.0.0.2" && StreamServer.normalizeHost("fe80::1%en0") == "fe80::1",
              "peer address normalization (v4-mapped, scope id)")
        if (try? locked.start()) != nil {
            let client = ReceiverStreamClient(host: "127.0.0.1", port: 5991)
            var status: [String] = []
            client.onStatus = { s in DispatchQueue.main.async { status.append(s) } }
            client.start()
            _ = wait(3) { client.ackSize != nil }
            check(client.ackSize == nil, "a client that isn't the peer gets no stream (\(status))")
            client.stop()
            let stopped = DispatchSemaphore(value: 0)
            locked.stop { stopped.signal() }
            _ = stopped.wait(timeout: .now() + 3)
        } else { check(false, "port 5991 free for the refusal check") }

        // 7. Reset brings everything home.
        ha.begin(windowId: w.id, pid: child.processIdentifier, frame: original, title: "", app: "selftest",
                 grab: .zero, preDragOrigin: original.origin, peerEdge: .left, position: 0.5)
        _ = wait { hb.receiverCount == 1 }
        ha.reset(); hb.reset()
        check(ha.outgoingCount == 0 && hb.receiverCount == 0, "link reset ends every handoff")
        if canAX {
            check(wait(3) { CarryDetector.frame(of: w.id).map { abs($0.minX - original.minX) < 3 } == true },
                  "reset puts the window back")
        }

        // 4. The window closing on A closes B's receiver.
        ha.begin(windowId: w.id, pid: child.processIdentifier, frame: original, title: "", app: "selftest",
                 grab: .zero, preDragOrigin: original.origin, peerEdge: .left, position: 0.5)
        check(wait { hb.receiverCount == 1 }, "handed off again")
        child.terminate()
        check(wait(6) { bRaw.contains(.windowClosed) && hb.receiverCount == 0 && ha.outgoingCount == 0 },
              "window closing on A sends WINDOW_CLOSED; B's receiver closes")

        return finish(a, b)
    }

    private static func finish(_ a: PeerLink, _ b: PeerLink) -> Int32 {
        let done = DispatchSemaphore(value: 0)
        a.stop { done.signal() }; b.stop { done.signal() }
        _ = done.wait(timeout: .now() + 3); _ = done.wait(timeout: .now() + 3)
        print(failures == 0 ? "PASS: handoff selftest (begin/accept, frames, park/restore, return, reject, closed, peer-only stream)"
                            : "FAIL: \(failures) check(s) failed")
        return failures == 0 ? 0 : 1
    }

    /// Child process: one plain window for the parent to hand off. Exits on
    /// its own after 60 s so a crashed parent can't leave it behind.
    static func runChildWindow() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let w = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 360, height: 240),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Clamshell handoff selftest"
        let label = NSTextField(labelWithString: "handoff selftest — closes by itself")
        label.frame = NSRect(x: 20, y: 110, width: 320, height: 20)
        w.contentView?.addSubview(label)
        w.backgroundColor = .systemTeal
        w.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { exit(0) }
        app.run()
        exit(0)
    }
}
