import AppKit

/// Downloads the latest release DMG, verifies the signing identity matches
/// the running app, swaps the bundle in place, and relaunches. Only valid
/// when running from a real .app bundle.
enum UpdateInstaller {
    static var canInstall: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    /// Kicks off the install; calls back on the main queue with an error
    /// message, or never returns (relaunch) on success.
    static func install(completion: @escaping (String) -> Void) {
        let fail: (String) -> Void = { msg in
            clog("update failed: \(msg)")
            DispatchQueue.main.async { completion(msg) }
        }
        guard canInstall else { return fail("not running from an .app bundle") }

        let api = URL(string: "https://api.github.com/repos/frindle/clamshell/releases/latest")!
        URLSession.shared.dataTask(with: api) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let assets = json["assets"] as? [[String: Any]],
                  let dmgURLString = assets.compactMap({ $0["browser_download_url"] as? String })
                      .first(where: { $0.hasSuffix(".dmg") }),
                  let dmgURL = URL(string: dmgURLString) else {
                return fail("could not resolve latest DMG asset")
            }
            clog("update: downloading \(dmgURLString)")
            URLSession.shared.downloadTask(with: dmgURL) { tmpFile, _, error in
                guard let tmpFile, error == nil else {
                    return fail("download failed: \(error.map(String.init(describing:)) ?? "?")")
                }
                do {
                    try performSwap(dmgAt: tmpFile)
                } catch {
                    return fail(String(describing: error))
                }
            }.resume()
        }.resume()
    }

    private struct UpdateError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    private static func performSwap(dmgAt dmg: URL) throws {
        let mount = NSTemporaryDirectory() + "clamshell-update-\(UUID().uuidString)"
        guard shell("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mount]) == 0 else {
            throw UpdateError("could not mount update DMG")
        }
        defer { _ = shell("/usr/bin/hdiutil", ["detach", mount, "-force"]) }

        let newApp = mount + "/Clamshell.app"
        guard FileManager.default.fileExists(atPath: newApp) else {
            throw UpdateError("Clamshell.app missing from DMG")
        }

        // The new bundle must pass real signature verification, and both
        // builds must carry the same non-ad-hoc signing identity — otherwise
        // the swap silently invalidates TCC grants (Accessibility) and the
        // "update" leaves the app half-broken. Requiring a real identity
        // also stops an ad-hoc local build from accepting any unsigned DMG.
        guard shell("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp]) == 0 else {
            throw UpdateError("update failed signature verification — update manually")
        }
        guard let currentID = signingAuthority(Bundle.main.bundlePath),
              let newID = signingAuthority(newApp),
              currentID == newID else {
            throw UpdateError("signing identity mismatch or ad-hoc build (running: \(signingAuthority(Bundle.main.bundlePath) ?? "ad-hoc"), update: \(signingAuthority(newApp) ?? "ad-hoc")) — update manually")
        }

        let dest = Bundle.main.bundlePath
        let graveyard = NSTemporaryDirectory() + "clamshell-old-\(UUID().uuidString).app"
        try FileManager.default.moveItem(atPath: dest, toPath: graveyard)
        guard shell("/usr/bin/ditto", [newApp, dest]) == 0 else {
            // Roll back so we don't leave no app at all.
            try? FileManager.default.moveItem(atPath: graveyard, toPath: dest)
            throw UpdateError("copy failed — rolled back")
        }
        clog("update installed, relaunching")

        DispatchQueue.main.async {
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            relaunch.arguments = ["-n", dest]
            try? relaunch.run()
            NSApp.terminate(nil)
        }
    }

    /// First Authority line of the code signature, nil for ad-hoc.
    private static func signingAuthority(_ path: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        // -dvv (not -dv): the Authority= line is only emitted at verbosity 2+.
        // With a self-signed identity, -dv prints no Authority at all, which
        // would make every self-signed build read as ad-hoc and break the
        // update identity match.
        task.arguments = ["-dvv", path]
        let pipe = Pipe()
        task.standardError = pipe // codesign prints to stderr
        task.standardOutput = FileHandle.nullDevice
        try? task.run()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        task.waitUntilExit()
        return out.split(separator: "\n")
            .first { $0.hasPrefix("Authority=") }
            .map { String($0.dropFirst("Authority=".count)) }
    }

    @discardableResult
    private static func shell(_ path: String, _ args: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        // nullDevice, not undrained Pipes — a full pipe buffer deadlocks the child.
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return -1 }
        task.waitUntilExit()
        return task.terminationStatus
    }
}
