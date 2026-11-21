import Foundation
import CryptoKit

/// Everything `clamshell loginwindow install | uninstall | status | sync` does.
///
/// The login-window agent runs as root, so it must not run code that a normal
/// user can replace, and it must not read a user's folder. Install therefore:
/// 1. copies the app to a root-owned folder and runs the agent from there;
/// 2. gives the agent a root-owned folder (mode 700) holding a copy of the
///    user's host key and trusted-device list (mode 600), refreshed by a
///    small launchd daemon (`sync`) whenever the user's folder changes;
/// 3. installs two plists copied from the app bundle: the agent (login window
///    session only) and the sync daemon.
/// Nothing here touches SSH, FileVault or any other setting.
enum LoginWindowInstall {
    static let agentLabel = "com.frindle.clamshell.loginwindow-agent"
    static let syncLabel = "com.frindle.clamshell.loginwindow-sync"

    /// The files the agent needs from the user's state folder.
    static let mirroredFiles: [(name: String, maxBytes: Int)] = [
        (HostIdentity.fileName, 64),
        (DeviceTrustStore.fileName, DeviceTrustStore.maxFileBytes),
    ]

    struct Layout: Equatable {
        var root = URL(fileURLWithPath: "/Library/Application Support/Clamshell/LoginWindow", isDirectory: true)
        var agentPlist = URL(fileURLWithPath: "/Library/LaunchAgents/\(LoginWindowInstall.agentLabel).plist")
        var syncPlist = URL(fileURLWithPath: "/Library/LaunchDaemons/\(LoginWindowInstall.syncLabel).plist")

        var appCopy: URL { root.appendingPathComponent("Clamshell.app", isDirectory: true) }
        var binary: URL { appCopy.appendingPathComponent("Contents/MacOS/Clamshell") }
        var stateDirectory: URL { root.appendingPathComponent("state", isDirectory: true) }
        var configFile: URL { root.appendingPathComponent("config.json") }
        /// Who must own the mirror: root, except in tests.
        var mirrorOwner: uid_t = 0
        var log: String { "/var/tmp/clamshell-loginwindow-agent.log" }
    }

    /// Whose state the agent mirrors. Written by install, read by `sync`.
    struct Config: Codable, Equatable {
        var user: String
        var uid: UInt32
        var userStateDirectory: String
        /// Where the user's own app lives, so a root job can notice an update.
        /// Absent in files written by earlier builds.
        var appPath: String?
    }

    // MARK: - plists

    /// Fills the placeholders of a plist template shipped in the app bundle.
    /// Values are XML-escaped; a placeholder left over is an error.
    static func render(template: String, values: [String: String]) throws -> String {
        var out = template
        for (key, value) in values {
            out = out.replacingOccurrences(of: "__\(key)__", with: xmlEscaped(value))
        }
        if let range = out.range(of: "__[A-Z_]+__", options: .regularExpression) {
            throw InstallError("the plist template has an unfilled placeholder: \(out[range])")
        }
        return out
    }

    static func xmlEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func agentValues(_ layout: Layout) -> [String: String] {
        ["APP_BINARY": layout.binary.path, "STATE_DIR": layout.stateDirectory.path, "LOG": layout.log]
    }

    static func syncValues(_ layout: Layout, _ config: Config) -> [String: String] {
        ["APP_BINARY": layout.binary.path, "WATCH_PATH": config.userStateDirectory, "LOG": layout.log,
         "APP_WATCH_PATH": (config.appPath ?? defaultAppPath) + "/Contents/Info.plist"]
    }

    struct InstallError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: - sync

    enum SyncOutcome: Equatable {
        case unchanged
        case updated([String])
    }

    /// Copies the user's host key and device list into `mirror`, owner-only.
    /// Reads refuse symbolic links and anything not a regular file owned by
    /// `userUID`; a missing device list removes the copy (nobody trusted); a
    /// missing or invalid host key is an error and leaves the copy as it was
    /// (the agent must never invent an identity of its own).
    @discardableResult
    static func sync(userDirectory: URL, userUID: uid_t, mirror: URL) throws -> SyncOutcome {
        try HostState.prepare(mirror)
        var updated: [String] = []
        for (name, maxBytes) in mirroredFiles {
            let source = userDirectory.appendingPathComponent(name)
            let target = mirror.appendingPathComponent(name)
            let data: Data
            do {
                data = try readOwned(source, uid: userUID, maxBytes: maxBytes)
            } catch SecureFileError.notFound {
                if name == HostIdentity.fileName {
                    throw InstallError("the user has no \(name) yet; start Clamshell once as that user")
                }
                if unlink(target.path) == 0 { updated.append(name) }
                continue
            } catch {
                throw InstallError("cannot read \(name): \(error)")
            }
            if name == HostIdentity.fileName, (try? P256.Signing.PrivateKey(rawRepresentation: data)) == nil {
                throw InstallError("\(name) does not hold a valid key")
            }
            if let existing = try? SecureFile.read(target, maxBytes: maxBytes), existing == data { continue }
            try SecureFile.replace(target, contents: data)
            updated.append(name)
        }
        return updated.isEmpty ? .unchanged : .updated(updated)
    }

    /// Like `SecureFile.read`, for a file that belongs to another user.
    static func readOwned(_ url: URL, uid: uid_t, maxBytes: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            switch errno {
            case ENOENT: throw SecureFileError.notFound
            case ELOOP: throw SecureFileError.unsafe("is a symbolic link")
            default: throw SecureFileError.io(errno)
            }
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw SecureFileError.io(errno) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw SecureFileError.unsafe("is not a regular file") }
        guard st.st_uid == uid else { throw SecureFileError.unsafe("belongs to another user") }
        guard st.st_size <= off_t(maxBytes) else { throw SecureFileError.unsafe("is larger than expected") }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count <= maxBytes {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw SecureFileError.io(errno)
            }
            if n == 0 { break }
            data.append(contentsOf: buffer[0 ..< n])
        }
        guard data.count <= maxBytes else { throw SecureFileError.unsafe("is larger than expected") }
        return data
    }

    // MARK: - status

    struct Status: Equatable {
        var appCopy = false
        var config: Config?
        var agentPlist = false
        var syncPlist = false
        var mirrorHostKey = false
        /// Nil when the user's folder cannot be read by the caller.
        var mirrorMatchesUser: Bool?
        var syncLoaded: Bool?
        /// Versions of the root-owned copy and of the app the user runs. A
        /// copy older than the installed app serves the login window with old
        /// code after an update.
        var copyVersion: String?
        var installedVersion: String?

        var installed: Bool { appCopy && config != nil && agentPlist && syncPlist }
        var outdated: Bool {
            guard let copyVersion, let installedVersion else { return false }
            return copyVersion != installedVersion
        }
        var healthy: Bool { installed && mirrorHostKey && mirrorMatchesUser != false && !outdated }
    }

    static let defaultAppPath = "/Applications/Clamshell.app"

    static func version(ofApp path: String) -> String? {
        let url = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: url) else { return nil }
        let short = dict["CFBundleShortVersionString"] as? String
        let build = dict["CFBundleVersion"] as? String
        return [short, build].compactMap { $0 }.joined(separator: " ")
    }

    static func status(_ layout: Layout = Layout(), launchdHas: (String) -> Bool? = { _ in nil }) -> Status {
        let fm = FileManager.default
        var s = Status()
        s.appCopy = fm.isExecutableFile(atPath: layout.binary.path)
        s.agentPlist = fm.fileExists(atPath: layout.agentPlist.path)
        s.syncPlist = fm.fileExists(atPath: layout.syncPlist.path)
        s.syncLoaded = launchdHas(syncLabel)
        if let data = try? Data(contentsOf: layout.configFile) {
            s.config = try? JSONDecoder().decode(Config.self, from: data)
        }
        s.mirrorHostKey = fm.fileExists(atPath: layout.stateDirectory.appendingPathComponent(HostIdentity.fileName).path)
        if let config = s.config {
            s.copyVersion = version(ofApp: layout.appCopy.path)
            s.installedVersion = version(ofApp: config.appPath ?? defaultAppPath)
            s.mirrorMatchesUser = mirrorMatches(userDirectory: URL(fileURLWithPath: config.userStateDirectory),
                                                userUID: uid_t(config.uid), mirror: layout.stateDirectory,
                                                mirrorUID: layout.mirrorOwner)
        }
        return s
    }

    /// Whether the mirror holds the same key and list as the user's folder.
    /// Nil when the caller cannot read the mirror (it is root-only).
    static func mirrorMatches(userDirectory: URL, userUID: uid_t, mirror: URL, mirrorUID: uid_t = 0) -> Bool? {
        guard access(mirror.path, R_OK) == 0 else { return nil }
        for (name, maxBytes) in mirroredFiles {
            let theirs = try? readOwned(userDirectory.appendingPathComponent(name), uid: userUID, maxBytes: maxBytes)
            let ours = try? readOwned(mirror.appendingPathComponent(name), uid: mirrorUID, maxBytes: maxBytes)
            if theirs != ours { return false }
        }
        return true
    }
}
