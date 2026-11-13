import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import SystemConfiguration
import ScreenCaptureKit

/// Read-only probe: can this process capture the screen and move the pointer
/// at the login window / lock screen? Runs once, writes counts and brightness
/// only (never pixels) to /var/tmp/clamshell-probe, and always returns 0 so a
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

        out["screen_recording"] = CGPreflightScreenCaptureAccess()
        out["accessibility"] = AXIsProcessTrusted()

        // Capture one frame; record only size and brightness.
        let cap = capture()
        if let img = cap.image {
            out["capture_ok"] = true
            out["width"] = img.width
            out["height"] = img.height
            out["mean_luma"] = meanLuma(img).map { ($0 * 100).rounded() / 100 } ?? NSNull()
            out["capture_error"] = NSNull()
        } else {
            out["capture_ok"] = false
            out["width"] = NSNull()
            out["height"] = NSNull()
            out["mean_luma"] = NSNull()
            out["capture_error"] = cap.error ?? "unknown"
        }
        out["capture_api"] = cap.api.isEmpty ? NSNull() : cap.api
        if cap.image != nil, let e = cap.error { out["capture_note"] = e }

        // Pointer nudge (display coordinates).
        let ptr = pointerTest()
        out["pointer_before"] = ptr.before ?? NSNull()
        out["pointer_after"] = ptr.after ?? NSNull()
        out["pointer_moved"] = ptr.moved
        if let e = ptr.error { out["pointer_error"] = e }

        writeOutputs(out)
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

    private static func meanLuma(_ img: CGImage) -> Double? {
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
        guard ok else { return nil }
        var sum = 0.0
        var i = 0
        let n = w * h
        while i < buf.count {
            sum += 0.2126 * Double(buf[i]) + 0.7152 * Double(buf[i + 1]) + 0.0722 * Double(buf[i + 2])
            i += 4
        }
        return sum / Double(n)
    }

    // MARK: pointer

    private static func pointerTest() -> (before: [Int]?, after: [Int]?, moved: Bool, error: String?) {
        guard let start = CGEvent(source: nil)?.location else {
            return (nil, nil, false, "cannot read pointer location")
        }
        let target = CGPoint(x: start.x + 1, y: start.y + 1)
        guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                 mouseCursorPosition: target, mouseButton: .left) else {
            return ([Int(start.x.rounded()), Int(start.y.rounded())], nil, false, "cannot create mouse event")
        }
        move.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.1)
        let end = CGEvent(source: nil)?.location
        // Put it back.
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: start, mouseButton: .left)?.post(tap: .cghidEventTap)
        let before = [Int(start.x.rounded()), Int(start.y.rounded())]
        guard let end else { return (before, nil, false, "cannot read pointer after move") }
        let after = [Int(end.x.rounded()), Int(end.y.rounded())]
        return (before, after, abs(end.x - start.x) >= 0.5, nil)
    }

    // MARK: output

    private static func writeOutputs(_ out: [String: Any]) {
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

        func s(_ k: String) -> String {
            if let v = out[k], !(v is NSNull) { return "\(v)" }
            return "-"
        }
        var locked = "-"
        if let cg = out["cg_session"] as? [String: Any], let l = cg["CGSSessionScreenIsLocked"] { locked = "\(l)" }
        let line = "\(s("ts")) \(s("label")) \(s("uid")) \(s("console_user")) locked=\(locked) " +
                   "capture_ok=\(s("capture_ok")) luma=\(s("mean_luma")) pointer_moved=\(s("pointer_moved")) " +
                   "sr=\(s("screen_recording")) ax=\(s("accessibility"))\n"
        appendLog(line)
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
