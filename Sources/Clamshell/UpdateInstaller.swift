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
    /// How the app starts the new build after the swap.
    enum Mode {
        /// Menu bar app: start the new copy, then quit.
        case app
        /// `clamshell update` over SSH: restart in place, then report.
        case cli
    }

    static func install(version: String? = nil, mode: Mode = .app,
                        completion: @escaping (String) -> Void, success: ((String) -> Void)? = nil) {
        let fail: (String) -> Void = { msg in
            clog("update failed: \(msg)")
            DispatchQueue.main.async { completion(msg) }
        }
        guard canInstall else { return fail("not running from an .app bundle") }

        guard let api = SafeUpdate.releaseAPIURL(version: version) else {
            return fail("\(version ?? "") is not a version number")
        }
        URLSession.shared.dataTask(with: api) { data, response, _ in
            // A rate-limited or failed API call returns JSON too; say which.
            if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                return fail("release lookup returned HTTP \(status)")
            }
            guard let data, let dmgURL = dmgAssetURL(fromReleaseJSON: data) else {
                return fail("could not resolve latest DMG asset")
            }
            clog("update: downloading \(dmgURL.absoluteString)")
            URLSession.shared.downloadTask(with: dmgURL) { tmpFile, response, error in
                guard let tmpFile, error == nil else {
                    return fail("download failed: \(error.map(String.init(describing:)) ?? "?")")
                }
                // Without this an error page would be saved and fail later as
                // an unmountable DMG.
                if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                    return fail("download returned HTTP \(status)")
                }
                do {
                    try performSwap(dmgAt: tmpFile, mode: mode, success: success)
                } catch {
                    return fail(String(describing: error))
                }
            }.resume()
        }.resume()
    }

    /// The first `.dmg` asset of a GitHub release, https only.
    static func dmgAssetURL(fromReleaseJSON data: Data) -> URL? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [[String: Any]],
              let string = assets.compactMap({ $0["browser_download_url"] as? String })
                  .first(where: { $0.hasSuffix(".dmg") }),
              let url = URL(string: string), url.scheme == "https" else { return nil }
        return url
    }

    /// Old bundles a previous update moved aside (the running app can't
    /// delete itself). Called at launch.
    /// The kept previous version (in the state folder) is not touched.
    static func removeOldCopies() {
        let tmp = NSTemporaryDirectory()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tmp)) ?? []
        for name in names where SafeUpdate.isStaleCopy(name: name) && name.hasPrefix("clamshell-old-") {
            try? FileManager.default.removeItem(atPath: tmp + name)
        }
        // A staged copy left by an update that was interrupted before the swap.
        let parent = (Bundle.main.bundlePath as NSString).deletingLastPathComponent
        guard canInstall else { return }
        let staged = (try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? []
        for name in staged where SafeUpdate.isStaleCopy(name: name) && name.hasPrefix(stagingPrefix) {
            try? FileManager.default.removeItem(atPath: parent + "/" + name)
        }
    }

    private static let stagingPrefix = ".Clamshell-update-"

    /// Full check of a bundle before it is trusted: the signature verifies,
    /// and it is the same signing identity as the running app.
    private static func verified(_ app: String) -> Bool {
        shell("/usr/bin/codesign", ["--verify", "--deep", "--strict", app]) == 0
            && CodeIdentity.sameIdentity(current: Bundle.main.bundlePath, candidate: app)
    }

    private struct UpdateError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    private static func performSwap(dmgAt dmg: URL, mode: Mode, success: ((String) -> Void)?) throws {
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
        // The name alone isn't proof: any certificate can be called that.
        // Require the update to satisfy this app's designated requirement,
        // which pins the certificate itself and is what the privacy grants
        // (Screen Recording, Accessibility) are keyed on.
        guard CodeIdentity.sameIdentity(current: Bundle.main.bundlePath, candidate: newApp) else {
            let want = CodeIdentity.designatedRequirement(at: Bundle.main.bundlePath).map(CodeIdentity.text) ?? "none"
            throw UpdateError("update is not signed by this app's certificate (need: \(want)) — update manually")
        }

        // Copy next to the installed app first and check that copy, so a
        // failed or interrupted copy never touches the working install. The
        // swap itself is then two renames.
        let dest = Bundle.main.bundlePath
        let parent = (dest as NSString).deletingLastPathComponent
        let staging = parent + "/" + stagingPrefix + UUID().uuidString + ".app"
        guard shell("/usr/bin/ditto", [newApp, staging]) == 0 else {
            try? FileManager.default.removeItem(atPath: staging)
            throw UpdateError("copy failed — the installed app was not changed")
        }
        guard verified(staging) else {
            try? FileManager.default.removeItem(atPath: staging)
            throw UpdateError("the copied update failed its signature check — the installed app was not changed")
        }
        // Keep the working version: it moves to a fixed place instead of being
        // deleted, so `clamshell rollback` and the health check can swap it back.
        let fm = FileManager.default
        let stateDir = HostState.directory
        let previous = SafeUpdate.previousBundle(in: stateDir).path
        do {
            try? HostState.prepare(stateDir)
            try fm.createDirectory(atPath: (previous as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            if fm.fileExists(atPath: previous) { try fm.removeItem(atPath: previous) }
            try fm.moveItem(atPath: dest, toPath: previous)
        } catch {
            try? fm.removeItem(atPath: staging)
            throw UpdateError("could not move the installed app aside (\(error.localizedDescription)) — the installed app was not changed")
        }
        do {
            try fm.moveItem(atPath: staging, toPath: dest)
        } catch {
            // Roll back so we don't leave no app at all.
            try? fm.moveItem(atPath: previous, toPath: dest)
            try? fm.removeItem(atPath: staging)
            throw UpdateError("could not move the update into place (\(error.localizedDescription)) — rolled back")
        }
        let from = SafeUpdateOps.currentVersion
        let to = SafeUpdateOps.version(ofApp: dest)
        clog("update installed and verified (\(from) -> \(to)), relaunching")

        // The new build has to prove itself: a watcher from the previous
        // bundle rolls back if it is not serving within the deadline.
        SafeUpdateOps.writeRecord(from: from, to: to, result: "installed", reason: "health check pending")
        SafeUpdateOps.writePending(SafeUpdate.Pending(startedAt: Date(), from: from, to: to,
                                                      oldPID: getpid(), installedApp: dest))
        SafeUpdateOps.startHealthWatcher(installed: dest, previous: previous)

        switch mode {
        case .cli:
            // This process is the old build; restart() replaces it (or ends it
            // when the agent is not loaded) and then reports.
            SafeUpdateOps.restart(appPath: dest, killOthers: true)
            success?(to)
        case .app:
            DispatchQueue.main.async {
                if SafeUpdateOps.agentLoaded {
                    SafeUpdateOps.restart(appPath: dest, killOthers: false)
                } else {
                    let relaunch = Process()
                    relaunch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    relaunch.arguments = ["-n", dest]
                    try? relaunch.run()
                    NSApp.terminate(nil)
                }
            }
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
