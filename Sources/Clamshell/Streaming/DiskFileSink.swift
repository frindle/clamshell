import Foundation
import CoreServices
import Darwin

// Storage for received files on the Mac host (PROTOCOL.md "File transfer",
// receiver rules). One destination folder; each file is written under a
// temporary name and claimed under its final name only when complete, in one
// step that cannot replace an existing file. The received name is never used
// as a path: only the output of `FileTransfer.storedName(for:)` is joined to
// the folder, and the result is checked to be a direct child of it. Nothing
// here opens or runs a received file.

final class DiskFileSink: FileTransferStore {
    static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Clamshell", isDirectory: true)
    }

    /// Free space kept back from every offer.
    static let defaultReserveBytes: UInt64 = 1 << 30
    /// How many numbered names (`name 2`, `name 3`, ...) are tried.
    static let maxNameAttempts = 10_000

    private struct Part {
        var fd: Int32
        let tempURL: URL
        let storedName: String
        /// The size the sender declared; counted against free space until the
        /// transfer ends, because the bytes have not all arrived yet.
        let declaredSize: UInt64
    }

    // Process-wide, because every connection has its own sink on the same
    // folder: the temporary files that are open now (a sweep must never touch
    // them), the folders already swept for leftovers, and, per folder, the
    // declared bytes of every transfer open in any sink, so the free-space
    // reserve holds for the whole Mac and not per connection.
    private static let shared = NSLock()
    private static var openTemps = Set<String>()
    private static var sweptFolders = Set<String>()
    private static var openBytes: [String: UInt64] = [:]

    /// Declared bytes of the transfers currently open in every sink on this
    /// receive folder (for tests; zero when nothing is open).
    static func openTotal(inFolder folder: URL) -> UInt64 {
        shared.lock(); defer { shared.unlock() }
        return openBytes[folder.standardizedFileURL.path] ?? 0
    }

    private let folder: URL
    private let reserveBytes: UInt64
    private let freeSpace: (URL) -> UInt64?
    private var parts: [UInt32: Part] = [:]
    /// The final URL of the most recently finished file (for the UI and tests).
    private(set) var lastStoredURL: URL?

    init(folder: URL = DiskFileSink.defaultFolder,
         reserveBytes: UInt64 = DiskFileSink.defaultReserveBytes,
         freeSpace: ((URL) -> UInt64?)? = nil) {
        self.folder = folder.standardizedFileURL
        self.reserveBytes = reserveBytes
        self.freeSpace = freeSpace ?? DiskFileSink.systemFreeSpace
    }

    deinit {
        for id in Array(parts.keys) { discard(id: id) }
    }

    // MARK: FileTransferStore

    /// Whether `size` fits next to the reserve and to the declared sizes of
    /// every transfer open in any sink on this folder. A quick first check;
    /// `begin` repeats it and takes the room in one step.
    func hasRoom(forBytes size: UInt64) -> Bool {
        Self.shared.lock(); defer { Self.shared.unlock() }
        return roomLocked(forBytes: size)
    }

    /// The caller holds `shared`.
    private func roomLocked(forBytes size: UInt64) -> Bool {
        guard let free = freeSpace(nearestExistingAncestor(of: folder)) else { return false }
        // The reserve is kept back after every open transfer (in any sink on
        // this folder) has also taken its declared size, so offers that each
        // fit alone are not all accepted when they do not fit together.
        var needed = reserveBytes
        for declared in [size, Self.openBytes[folder.path] ?? 0] {
            let (sum, overflow) = needed.addingReportingOverflow(declared)
            if overflow { return false }
            needed = sum
        }
        return free >= needed
    }

    func begin(id: UInt32, storedName: String, size: UInt64) -> Bool {
        guard parts[id] == nil, ensureFolder() else { return false }
        sweepOnce()
        // Names come from storedName(for:), but check again: this is the last
        // line between a remote sender and the file system.
        guard childURL(storedName) != nil else { return false }
        let tempName = ".clamshell-\(UUID().uuidString).part"
        guard let tempURL = childURL(tempName) else { return false }
        // The room check, the declared size and the temp name are taken in one
        // lock hold: two offers at the same moment cannot both pass, and
        // another server's sweep sees the name before the file exists.
        Self.shared.lock()
        guard roomLocked(forBytes: size) else { Self.shared.unlock(); return false }
        Self.openBytes[folder.path, default: 0] += size
        Self.openTemps.insert(tempURL.path)
        Self.shared.unlock()
        let fd = open(tempURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            forget(tempURL: tempURL, declaredSize: size)
            return false
        }
        parts[id] = Part(fd: fd, tempURL: tempURL, storedName: storedName, declaredSize: size)
        return true
    }

    func write(id: UInt32, bytes: Data) -> Bool {
        guard let part = parts[id] else { return false }
        return bytes.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(part.fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
    }

    func finish(id: UInt32) -> Bool {
        guard let part = parts.removeValue(forKey: id) else { return false }
        let closed = close(part.fd) == 0
        defer { forget(part) }
        guard closed, let finalURL = claim(part) else {
            _ = unlink(part.tempURL.path)
            return false
        }
        if !markDownloaded(finalURL) {
            // Never leave an unmarked received file behind.
            _ = unlink(finalURL.path)
            return false
        }
        lastStoredURL = finalURL
        return true
    }

    func discard(id: UInt32) {
        guard let part = parts.removeValue(forKey: id) else { return }
        _ = close(part.fd)
        _ = unlink(part.tempURL.path)
        forget(part)
    }

    // MARK: leftovers

    /// Called once per transfer, right after it left `parts` (finish, discard,
    /// deinit), so its size is taken from the folder's total exactly once.
    private func forget(_ part: Part) {
        forget(tempURL: part.tempURL, declaredSize: part.declaredSize)
    }

    private func forget(tempURL: URL, declaredSize: UInt64) {
        Self.shared.lock()
        Self.openTemps.remove(tempURL.path)
        let left = (Self.openBytes[folder.path] ?? 0) &- declaredSize
        if left == 0 { Self.openBytes[folder.path] = nil } else { Self.openBytes[folder.path] = left }
        Self.shared.unlock()
    }

    /// Before the first transfer into this folder in this process.
    private func sweepOnce() {
        Self.shared.lock()
        let first = Self.sweptFolders.insert(folder.path).inserted
        Self.shared.unlock()
        if first { _ = removeLeftovers() }
    }

    /// Remove the `.clamshell-*.part` files an earlier run left behind (a crash
    /// or power loss in the middle of a transfer). Only regular files, directly
    /// in the folder, that match that name and are not open in this process:
    /// links, directories and everything else are left alone. Returns how many
    /// were removed.
    @discardableResult
    func removeLeftovers() -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return 0 }
        var removed = 0
        for name in names where name.hasPrefix(".clamshell-") && name.hasSuffix(".part") {
            guard let url = childURL(name) else { continue }
            Self.shared.lock()
            let isOpen = Self.openTemps.contains(url.path)
            Self.shared.unlock()
            if isOpen { continue }
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            if unlink(url.path) == 0 { removed += 1 }
        }
        return removed
    }

    // MARK: pieces

    /// A direct child of the folder with this exact name, or nil.
    private func childURL(_ name: String) -> URL? {
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\0"),
              name.utf8.count <= 255 else { return nil }
        let url = folder.appendingPathComponent(name, isDirectory: false)
        guard url.lastPathComponent == name,
              url.deletingLastPathComponent().standardizedFileURL.path == folder.path else { return nil }
        return url
    }

    private func ensureFolder() -> Bool {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir) { return isDir.boolValue }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    /// Rename the temporary file to the first free name, never replacing.
    private func claim(_ part: Part) -> URL? {
        for n in 1...Self.maxNameAttempts {
            guard let target = childURL(FileTransfer.numberedName(part.storedName, n)) else { return nil }
            if renamex_np(part.tempURL.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
            if errno != EEXIST { return nil }
        }
        return nil
    }

    private func markDownloaded(_ url: URL) -> Bool {
        var target = url
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
            kLSQuarantineAgentNameKey as String: "Clamshell",
        ]
        do {
            try target.setResourceValues(values)
            return true
        } catch {
            return false
        }
    }

    private func nearestExistingAncestor(of url: URL) -> URL {
        var current = url
        while !FileManager.default.fileExists(atPath: current.path), current.path != "/" {
            current = current.deletingLastPathComponent()
        }
        return current
    }

    private static func systemFreeSpace(_ url: URL) -> UInt64? {
        var s = statfs()
        guard statfs(url.path, &s) == 0 else { return nil }
        return UInt64(s.f_bavail) * UInt64(s.f_bsize)
    }
}
