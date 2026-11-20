import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import SystemConfiguration
import ScreenCaptureKit

/// Read-only probe: can this process capture the screen and move the pointer
/// at the login window / lock screen, and does a Shift keystroke arrive? Runs
/// once, writes counts and brightness spread only (never pixels) to /var/tmp/clamshell-probe, and always returns 0 so a
/// launchd job is never throttled. Failures are recorded in the JSON.
enum LoginWindowProbe {
    static let dir = "/var/tmp/clamshell-probe"
    static let maxLogLines = 2000

    private final class CaptureBox: @unchecked Sendable {
        var image: CGImage?
        var api = ""
        var error: String?
    }

    static func run(label: String) -> Int32 {
        var out: [String: Any] = [:]
        let ts = ISO8601DateFormatter().string(from: Date())
        out["ts"] = ts
        out["label"] = label
        out["version"] = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
        out["uid"] = Int(getuid())
        out["euid"] = Int(geteuid())
        out["user"] = NSUserName()
        out["xpc_service_name"] = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] ?? NSNull()

        // Console user.
        var cuid: uid_t = 0
        var cgid: gid_t = 0
        if let name = SCDynamicStoreCopyConsoleUser(nil, &cuid, &cgid) as String? {
            out["console_user"] = name
            out["console_uid"] = Int(cuid)
        } else {
            out["console_user"] = NSNull()
            out["console_uid"] = NSNull()
        }

        // CG session dictionary (selected scalar keys only).
        if let dict = CGSessionCopyCurrentDictionary() as? [String: Any] {
            var sub: [String: Any] = [:]
            for key in ["kCGSSessionOnConsoleKey", "CGSSessionScreenIsLocked",
                        "kCGSessionLoginDoneKey", "kCGSSessionUserIDKey"] {
                if let v = dict[key] {
                    if let b = v as? Bool, CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID() {
                        sub[key] = b
                    } else if let n = v as? Int {
                        sub[key] = n
                    }
                }
            }
            out["cg_session"] = sub
        } else {
            out["cg_session"] = NSNull()
        }

        let sr = CGPreflightScreenCaptureAccess()
        let ax = AXIsProcessTrusted()
        let post = CGPreflightPostEventAccess()
        let listen = CGPreflightListenEventAccess()
        out["screen_recording"] = sr
        out["accessibility"] = ax
        out["post_event"] = post
        out["listen_event"] = listen

        // TCC rows for this bundle id; readable only as root or with Full
        // Disk Access. Never fails the probe.
        let tcc = tccRows()
        out["tcc"] = tcc ?? "unreadable"

        // Capture with the cursor shown, nudge the pointer, capture again.
        // Records size, brightness spread and a diff count; never pixels.
        let before = capture()
        let ptr = pointerTest()
        let after = ptr.moved ? capture() : before
        ptr.restore()
        var summary = ProbeMath.Summary()
        if let img = before.image {
            out["capture_ok"] = true
            out["width"] = img.width
            out["height"] = img.height
            if let px = rgba(img), let st = ProbeMath.lumaStats(rgba: px.data, pixelCount: px.width * px.height) {
                out["luma_mean"] = (st.mean * 100).rounded() / 100
                out["luma_stddev"] = (st.stddev * 100).rounded() / 100
                summary.lumaStddev = st.stddev
                if let img2 = after.image, ptr.moved, let px2 = rgba(img2),
                   px2.width == px.width, px2.height == px.height,
                   let d = ProbeMath.gridDiff(px.data, px2.data, width: px.width, height: px.height) {
                    out["frame_changed"] = d
                    summary.frameChanged = d
                } else {
                    out["frame_changed"] = NSNull()
                }
            } else {
                out["luma_mean"] = NSNull()
                out["luma_stddev"] = NSNull()
                out["frame_changed"] = NSNull()
            }
            out["capture_error"] = NSNull()
        } else {
            out["capture_ok"] = false
            out["width"] = NSNull()
            out["height"] = NSNull()
            out["luma_mean"] = NSNull()
            out["luma_stddev"] = NSNull()
            out["frame_changed"] = NSNull()
            out["capture_error"] = before.error ?? "unknown"
        }
        out["capture_api"] = before.api.isEmpty ? NSNull() : before.api
        if before.image != nil, let e = before.error { out["capture_note"] = e }

        out["pointer_before"] = ptr.before ?? NSNull()
        out["pointer_after"] = ptr.after ?? NSNull()
        out["pointer_moved"] = ptr.moved
        if let e = ptr.error { out["pointer_error"] = e }

        // Keystroke: Shift down, read the modifier state back, Shift up.
        let key = keyTest()
        out["key_posted"] = key.posted
        out["key_seen"] = key.seen
        if let e = key.error { out["key_error"] = e }

        summary.ts = ts
        summary.label = label
        summary.uid = "\(getuid())"
        summary.consoleUser = (out["console_user"] as? String) ?? "-"
        if let cg = out["cg_session"] as? [String: Any], let l = cg["CGSSessionScreenIsLocked"] { summary.locked = "\(l)" }
        summary.captureOK = before.image != nil
        summary.pointerMoved = ptr.moved
        summary.keyPosted = key.posted
        summary.keySeen = key.seen
        summary.screenRecording = sr
        summary.accessibility = ax
        summary.postEvent = post
        summary.listenEvent = listen
        summary.tcc = tcc.map { $0.isEmpty ? "none" : $0.joined(separator: ",") } ?? "unreadable"

        writeOutputs(out, summary: summary)
        return 0
    }

    // MARK: capture

    private static func capture() -> CaptureBox {
        let box = CaptureBox()
        if #available(macOS 14.0, *) {
            let sema = DispatchSemaphore(value: 0)
            Task {
                do {
                    let content = try await SCShareableContent.current
                    let mainID = CGMainDisplayID()
                    guard let display = content.displays.first(where: { $0.displayID == mainID })
                            ?? content.displays.first else {
                        throw NSError(domain: "probe", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "no SCDisplay"])
                    }
                    let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                    let cfg = SCStreamConfiguration()
                    let w = 640
                    let h = max(1, Int((Double(display.height) / Double(max(display.width, 1)) * Double(w)).rounded()))
                    cfg.width = w
                    cfg.height = h
                    cfg.showsCursor = true
                    let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                    box.image = img
                    box.api = "sck"
                } catch {
                    box.error = "sck: \(error.localizedDescription)"
                }
                sema.signal()
            }
            if sema.wait(timeout: .now() + 10) == .timedOut {
                box.error = "sck: timeout"
            }
            if box.image != nil { return box }
        }
        // Fallback: CoreGraphics (macOS 13, or ScreenCaptureKit failed).
        let prior = box.error
        if let img = CGDisplayCreateImage(CGMainDisplayID()) {
            box.image = img
            box.api = "cg"
            box.error = prior   // keep SCK failure note, if any
        } else {
            box.error = [prior, "cg: CGDisplayCreateImage returned nil"].compactMap { $0 }.joined(separator: "; ")
            if box.api.isEmpty { box.api = "cg" }
        }
        return box
    }

    /// Renders the image into an RGBA8 buffer for the pure statistics.
    private static func rgba(_ img: CGImage) -> (data: [UInt8], width: Int, height: Int)? {
        let w = img.width, h = img.height
        guard w > 0, h > 0 else { return nil }
        let bytesPerRow = w * 4
        var buf = [UInt8](repeating: 0, count: bytesPerRow * h)
        let cs = CGColorSpaceCreateDeviceRGB()
        let ok: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (buf, w, h) : nil
    }

    // MARK: pointer

    /// Moves the pointer 24 points right and down (enough to change a coarse
    /// grid cell in a downscaled capture) and reads it back. The pointer stays
    /// moved until `restore()` so the caller can capture a frame in between.
    private struct PointerResult {
        var before: [Int]?
        var after: [Int]?
        var moved: Bool
        var error: String?
        var start: CGPoint?
        func restore() {
            guard let start else { return }
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                    mouseCursorPosition: start, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }

    private static func pointerTest() -> PointerResult {
        guard let start = CGEvent(source: nil)?.location else {
            return PointerResult(before: nil, after: nil, moved: false, error: "cannot read pointer location", start: nil)
        }
        let before = [Int(start.x.rounded()), Int(start.y.rounded())]
        let target = CGPoint(x: start.x + 24, y: start.y + 24)
        guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                 mouseCursorPosition: target, mouseButton: .left) else {
            return PointerResult(before: before, after: nil, moved: false, error: "cannot create mouse event", start: start)
        }
        move.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.2)
        guard let end = CGEvent(source: nil)?.location else {
            return PointerResult(before: before, after: nil, moved: false, error: "cannot read pointer after move", start: start)
        }
        let after = [Int(end.x.rounded()), Int(end.y.rounded())]
        return PointerResult(before: before, after: after, moved: abs(end.x - start.x) >= 0.5, error: nil, start: start)
    }

    // MARK: keystroke

    /// Posts Shift down, polls the session modifier state for it, then always
    /// posts Shift up. Shift only: never a character key, never Return.
    private static func keyTest() -> (posted: Bool, seen: Bool, error: String?) {
        let shift: CGKeyCode = 56
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: shift, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: shift, keyDown: false) else {
            return (false, false, "cannot create key event")
        }
        down.flags = .maskShift
        up.flags = []
        down.post(tap: .cghidEventTap)
        var seen = false
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.05)
            if CGEventSource.flagsState(.combinedSessionState).contains(.maskShift) { seen = true; break }
        }
        up.post(tap: .cghidEventTap)
        return (true, seen, nil)
    }

    // MARK: TCC

    /// Reads this bundle id's rows from the system TCC database with sqlite3.
    /// nil when the database cannot be read (no root / Full Disk Access).
    private static func tccRows() -> [String]? {
        let id = Bundle.main.bundleIdentifier ?? "com.frindle.clamshell"
        guard id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = ["-readonly", "/Library/Application Support/com.apple.TCC/TCC.db",
                       "select service, auth_value from access where client='\(id)';"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate(); return nil }
        guard p.terminationStatus == 0 else { return nil }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        // A readable database with no rows for us is a real answer: empty list.
        return ProbeMath.parseTCCRows(text) ?? []
    }

    // MARK: output

    private static func writeOutputs(_ out: [String: Any], summary: ProbeMath.Summary) {
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: dir) {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o777])
            }
            // umask may have trimmed the mode on creation.
            try? fm.setAttributes([.posixPermissions: 0o777], ofItemAtPath: dir)
        } catch {
            FileHandle.standardError.write(Data("probe: mkdir failed: \(error)\n".utf8))
            return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: out,
                                                  options: [.prettyPrinted, .sortedKeys])
            let tmp = "\(dir)/.latest.\(getpid()).tmp"
            let final = "\(dir)/latest.json"
            try data.write(to: URL(fileURLWithPath: tmp))
            chmod(tmp, 0o644)
            if rename(tmp, final) != 0 {
                FileHandle.standardError.write(Data("probe: rename failed errno=\(errno)\n".utf8))
                unlink(tmp)
            }
        } catch {
            FileHandle.standardError.write(Data("probe: write json failed: \(error)\n".utf8))
        }

        appendLog(ProbeMath.summaryLine(summary) + "\n")
    }

    private static func appendLog(_ line: String) {
        let path = "\(dir)/probe.log"
        let fm = FileManager.default
        var text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        text += line
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if lines.count > maxLogLines { lines.removeFirst(lines.count - maxLogLines) }
        let joined = lines.joined(separator: "\n") + "\n"
        let tmp = "\(dir)/.probe.\(getpid()).tmp"
        if fm.createFile(atPath: tmp, contents: Data(joined.utf8), attributes: [.posixPermissions: 0o666]) {
            chmod(tmp, 0o666)
            if rename(tmp, path) != 0 { unlink(tmp) }
        }
    }
}
