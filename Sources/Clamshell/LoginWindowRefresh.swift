import Foundation

// Keeping the root-owned copy of the app current after an update.
extension LoginWindowInstall {
    enum Refresh: Equatable {
        case upToDate
        case refreshed(from: String, to: String)
        case skipped(String)
    }

    /// Runs as root from the sync daemon (at boot, when the app changes, and
    /// on a timer). When the user's app is a different version from the
    /// root-owned copy, replaces the copy, but only if the user's app is
    /// signed by the same identity as the copy: a program that can write to
    /// the Applications folder must not thereby get code run as root. Ad-hoc
    /// builds have no identity to compare, so they are never copied this way
    /// and `status` says the copy is outdated instead.
    ///
    /// The pieces that touch the disk are passed in so the decision is tested.
    static func refreshAppCopy(
        layout: Layout, config: Config,
        versionOf: (String) -> String? = { LoginWindowInstall.version(ofApp: $0) },
        sameIdentity: (String, String) -> Bool = { CodeIdentity.sameIdentity(current: $0, candidate: $1) },
        replace: ((_ source: String, _ copy: URL) throws -> Void)? = nil
    ) -> Refresh {
        let source = config.appPath ?? defaultAppPath
        guard let theirs = versionOf(source) else { return .skipped("the app at \(source) cannot be read") }
        guard let ours = versionOf(layout.appCopy.path) else { return .skipped("there is no root-owned copy to refresh") }
        if theirs == ours { return .upToDate }
        guard sameIdentity(layout.appCopy.path, source) else {
            return .skipped("the app at \(source) (\(theirs)) is not signed by the same identity as the copy (\(ours))")
        }
        do {
            if let replace {
                try replace(source, layout.appCopy)
            } else {
                try replaceCopy(from: source, layout: layout, to: layout.appCopy)
            }
        } catch {
            return .skipped("could not replace the copy: \(error)")
        }
        return .refreshed(from: ours, to: theirs)
    }

    /// Copies the app into a staging folder only root can enter (0700) and
    /// makes it root-owned there. ditto run as root keeps the source's owner,
    /// so a copy staged where the user can reach it would be theirs to open
    /// for writing until the chown, and a descriptor opened then outlives the
    /// chown and the signature check.
    static func stageRootCopy(of source: String, root: URL) throws -> URL {
        let fm = FileManager.default
        let area = root.appendingPathComponent(".staging", isDirectory: true)
        try? fm.removeItem(at: area)
        try fm.createDirectory(at: area, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        let staged = area.appendingPathComponent("Clamshell.app", isDirectory: true)
        try runProcess("/usr/bin/ditto", [source, staged.path])
        try runProcess("/usr/sbin/chown", ["-R", "root:wheel", staged.path])
        try runProcess("/bin/chmod", ["-R", "go-w", staged.path])
        return staged
    }

    /// Copies the app next to the live copy, checks the copy, then swaps by
    /// rename so there is never a moment with no copy.
    static func replaceCopy(from source: String, layout: Layout, to copy: URL) throws {
        let fm = FileManager.default
        let old = layout.root.appendingPathComponent("Clamshell.app.old", isDirectory: true)
        try? fm.removeItem(at: old)
        let staged = try stageRootCopy(of: source, root: layout.root)
        defer { try? fm.removeItem(at: staged.deletingLastPathComponent()) }
        guard CodeIdentity.sameIdentity(current: copy.path, candidate: staged.path) else {
            throw InstallError("the copied app failed its signature check")
        }
        try fm.moveItem(at: copy, to: old)
        do {
            try fm.moveItem(at: staged, to: copy)
        } catch {
            try? fm.moveItem(at: old, to: copy)
            throw error
        }
        try? fm.removeItem(at: old)
    }

    @discardableResult
    static func runProcess(_ path: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw InstallError("\((path as NSString).lastPathComponent) failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return text
    }
}
