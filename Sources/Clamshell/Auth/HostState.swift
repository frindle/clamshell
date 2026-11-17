import Foundation
import CryptoKit

// Where the host keeps what has to outlive a run: its identity key and the
// list of devices (PROTOCOL.md "Device authentication and encrypted session").
// Everything is a small file, mode 0600, in one directory that is 0700.
//
// What this does not defend against: another program running as the same
// user can read and write these files. Keeping the key and an integrity check
// for the device list in the keychain is the planned follow-up.

enum SecureFileError: Error, Equatable {
    case notFound
    case exists
    /// The path holds something this code will not use; the text says what.
    case unsafe(String)
    case io(Int32)
}

/// Small-file I/O that never follows a symbolic link at the final path
/// component and never leaves a half-written file under the real name.
enum SecureFile {
    static func read(_ url: URL, maxBytes: Int) throws -> Data {
        // O_NONBLOCK so a FIFO planted at the path cannot hang the open.
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
        guard st.st_uid == geteuid() else { throw SecureFileError.unsafe("belongs to another user") }
        guard st.st_size <= off_t(maxBytes) else { throw SecureFileError.unsafe("is larger than expected") }
        if st.st_mode & 0o077 != 0 {
            clog("STATE: \(url.lastPathComponent) was readable by other users — tightened to owner-only")
            fchmod(fd, 0o600)
        }
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

    /// Puts `contents` at `url`, replacing what is there in one step.
    static func replace(_ url: URL, contents: Data) throws {
        let temp = try writeTemp(beside: url, contents: contents)
        guard rename(temp.path, url.path) == 0 else {
            let code = errno
            unlink(temp.path)
            throw SecureFileError.io(code)
        }
    }

    /// Puts `contents` at `url` only if nothing has that name. The file shows
    /// up complete or not at all, so another process never reads half of it.
    static func createExclusive(_ url: URL, contents: Data) throws {
        let temp = try writeTemp(beside: url, contents: contents)
        guard renamex_np(temp.path, url.path, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            unlink(temp.path)
            throw code == EEXIST ? SecureFileError.exists : SecureFileError.io(code)
        }
    }

    /// Moves a file this code cannot use out of the way, keeping it for the
    /// user to look at. Returns the new name.
    @discardableResult
    static func moveAside(_ url: URL) throws -> String {
        let aside = url.path + ".unusable-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
        guard rename(url.path, aside) == 0 else { throw SecureFileError.io(errno) }
        return (aside as NSString).lastPathComponent
    }

    static let tempPrefix = ".clamshell-tmp-"

    private static func writeTemp(beside url: URL, contents: Data) throws -> URL {
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(tempPrefix + UUID().uuidString)
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SecureFileError.io(errno) }
        var failure: Int32 = 0
        contents.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                offset += n
            }
        }
        if failure == 0, fsync(fd) != 0 { failure = errno }
        close(fd)
        guard failure == 0 else {
            unlink(temp.path)
            throw SecureFileError.io(failure)
        }
        return temp
    }
}

enum HostState {
    /// `CLAMSHELL_STATE_DIR` if set, else `~/Library/Application Support/Clamshell`.
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["CLAMSHELL_STATE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Clamshell", isDirectory: true)
    }

    /// Makes sure `directory` is a real directory of this user that nobody
    /// else can read, creating it if needed.
    static func prepare(_ directory: URL) throws {
        var st = stat()
        if lstat(directory.path, &st) != 0 {
            guard errno == ENOENT else { throw SecureFileError.io(errno) }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                throw SecureFileError.unsafe("could not be created: \(error.localizedDescription)")
            }
            guard lstat(directory.path, &st) == 0 else { throw SecureFileError.io(errno) }
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw SecureFileError.unsafe("is not a directory") }
        guard st.st_uid == geteuid() else { throw SecureFileError.unsafe("belongs to another user") }
        if st.st_mode & 0o077 != 0 {
            guard chmod(directory.path, 0o700) == 0 else { throw SecureFileError.io(errno) }
            clog("STATE: \(directory.path) was open to other users — tightened to owner-only")
        }
        sweepTemporaryFiles(in: directory)
    }

    /// Temporary files a crashed run left behind, once they are an hour old.
    private static func sweepTemporaryFiles(in directory: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for name in names where name.hasPrefix(SecureFile.tempPrefix) {
            let path = directory.appendingPathComponent(name).path
            guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  modified < cutoff else { continue }
            unlink(path)
        }
    }
}

/// The host's long-term signing key. Clients keep its public half after the
/// first accepted handshake and refuse a host that shows a different one.
struct HostIdentity {
    let publicKey: Data
    let sign: AuthSigner
    /// False when the key could not be read or stored and lasts for this run
    /// only.
    let isPersistent: Bool

    var id: String { DeviceIdentity.id(ofPublicKey: publicKey) }
    var fingerprint: String { DeviceIdentity.fingerprint(ofId: id) }

    static let fileName = "host-identity.key"

    init(key: P256.Signing.PrivateKey, isPersistent: Bool) {
        self.publicKey = key.publicKey.x963Representation
        self.sign = AuthSignature.signer(key)
        self.isPersistent = isPersistent
    }

    /// Reads the key in `directory`, creating it on first use. Never fails: a
    /// directory that cannot be used gives a key for this run only, which
    /// clients that know this host will refuse as a changed identity.
    static func load(in directory: URL) -> HostIdentity {
        do {
            try HostState.prepare(directory)
            return HostIdentity(key: try loadOrCreateKey(in: directory), isPersistent: true)
        } catch {
            clog("HOST IDENTITY: cannot keep a key in \(directory.path) (\(error)) — using one for this run only. Devices that know this Mac will report a changed identity.")
            return HostIdentity(key: P256.Signing.PrivateKey(), isPersistent: false)
        }
    }

    private static func loadOrCreateKey(in directory: URL) throws -> P256.Signing.PrivateKey {
        let url = directory.appendingPathComponent(fileName)
        // More than one pass only when another process creates the file
        // between this one's read and its create.
        for _ in 0 ..< 3 {
            do {
                let raw = try SecureFile.read(url, maxBytes: 64)
                if let key = try? P256.Signing.PrivateKey(rawRepresentation: raw) { return key }
                try replaceUnusable(url, why: "does not hold a valid key")
            } catch SecureFileError.notFound {
                // First use: create it below.
            } catch SecureFileError.unsafe(let why) {
                try replaceUnusable(url, why: why)
            }
            let key = P256.Signing.PrivateKey()
            do {
                try SecureFile.createExclusive(url, contents: key.rawRepresentation)
                let fingerprint = DeviceIdentity.fingerprint(ofPublicKey: key.publicKey.x963Representation)
                clog("HOST IDENTITY: created this Mac's identity key, fingerprint \(fingerprint)")
                return key
            } catch SecureFileError.exists {
                continue
            }
        }
        throw SecureFileError.unsafe("could not settle on an identity key")
    }

    private static func replaceUnusable(_ url: URL, why: String) throws {
        let aside = try SecureFile.moveAside(url)
        clog("HOST IDENTITY: \(url.lastPathComponent) \(why) — kept as \(aside). A NEW identity key will be created; devices that know this Mac will report a changed identity.")
    }
}
