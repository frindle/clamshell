import Foundation

// The list of devices this host knows: trusted, denied, or waiting for the
// user to decide (PROTOCOL.md "Device authentication and encrypted session").
//
// It lives in `devices.json` in the host's state directory. The file is the
// truth: the menu-bar app, `clamshell stream` and `clamshell approve` are
// separate processes, so every change re-reads it under a file lock, writes
// it back in one step, and the others notice by watching the directory.
//
// A device is trusted only by a decision of the user. Nothing in here trusts
// a device because of its name or the address it came from.

enum DeviceState: String, Codable {
    case trusted
    case denied
    case waiting
}

struct DeviceRecord: Codable, Equatable {
    /// Lowercase hex SHA-256 of the device's public key.
    var id: String
    /// The 65-byte public key, lowercase hex.
    var publicKey: String
    /// What the device calls itself. A label, not proof of anything.
    var name: String
    var state: DeviceState
    /// Seconds since 1970.
    var firstSeen: Double
    var lastSeen: Double
    /// Where it last connected from. A hint for the user, nothing more.
    var address: String
    var decidedAt: Double?
    /// "host", "cli", or the id of the trusted device that relayed the decision.
    var decidedBy: String?

    var fingerprint: String { DeviceIdentity.fingerprint(ofId: id) }
    var label: String { name.isEmpty ? "Unnamed device" : name }
}

private struct DeviceFile: Codable {
    var version: Int
    var devices: [DeviceRecord]
}

/// An advisory lock on a file beside the device list, so two processes do not
/// both read, change and write it at once.
private final class FileLock {
    private var fd: Int32

    init(_ url: URL, timeout: TimeInterval = 2) {
        fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { break }
            if Date() > deadline {
                // Whoever holds it could write the file anyway; waiting for
                // ever would only let it stall the host.
                clog("DEVICES: the device list's lock has been held for \(Int(timeout)) s — carrying on without it")
                break
            }
            usleep(10_000)
        }
    }

    func unlock() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { unlock() }
}

final class DeviceTrustStore {
    static let fileName = "devices.json"
    static let lockName = "devices.lock"
    static let maxWaiting = 16
    static let maxNewPerMinute = 10
    /// What one address group may hold of the waiting list, and add in a minute.
    static let maxWaitingPerGroup = 4
    static let maxNewPerMinutePerGroup = 3
    /// A waiting device seen this recently is not replaced by a newcomer.
    static let recentlySeen: TimeInterval = 5 * 60
    static let waitingLifetime: TimeInterval = 24 * 60 * 60
    static let maxFileBytes = 1 << 20
    /// Posted in this process, with the store as object, after the list
    /// changes for any reason, on whatever thread made or noticed the change.
    static let didChange = Notification.Name("com.frindle.clamshell.devices.didChange")
    static let decidedOnHost = "host"
    static let decidedOnCommandLine = "cli"

    enum Answer: Equatable {
        case trusted
        case denied
        case waiting
        /// The waiting list cannot take this device now.
        case busy
    }

    enum Decision: String {
        case approve
        case deny
    }

    enum Match {
        case one(DeviceRecord)
        case none
        case ambiguous([DeviceRecord])
        /// Not a full id or a 16-digit fingerprint.
        case badQuery
    }

    let directory: URL
    /// False when the state directory cannot be used: the list then lives in
    /// memory for this run, and other processes cannot see or change it.
    let canPersist: Bool

    private let now: () -> Date
    private let lock = NSLock()
    private var records: [DeviceRecord] = []
    private var recentAdds: [(time: TimeInterval, group: String?)] = []
    private var watcher: DispatchSourceFileSystemObject?
    private let watchQueue = DispatchQueue(label: "com.frindle.clamshell.devices.watch")
    private var reloadScheduled = false

    private var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    init(directory: URL, watch: Bool = true, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.now = now
        do {
            try HostState.prepare(directory)
            canPersist = true
        } catch {
            canPersist = false
            clog("DEVICES: cannot keep the device list in \(directory.path) (\(error)) — it will last for this run only")
        }
        if canPersist {
            records = readDisk() ?? []
            if watch { startWatching() }
        }
    }

    deinit { watcher?.cancel() }

    // MARK: reading

    /// Every device, without waiting devices whose 24 hours have run out.
    func all() -> [DeviceRecord] {
        lock.lock()
        defer { lock.unlock() }
        let t = now().timeIntervalSince1970
        return records.filter { !Self.isExpired($0, now: t) }
    }

    func record(id: String) -> DeviceRecord? { all().first { $0.id == id } }
    func state(of id: String) -> DeviceState? { record(id: id)?.state }
    func isTrusted(_ id: String) -> Bool { state(of: id) == .trusted }

    /// Oldest first.
    func waiting() -> [DeviceRecord] {
        all().filter { $0.state == .waiting }.sorted { $0.firstSeen < $1.firstSeen }
    }

    /// Finds a device by its full id or its 16-digit fingerprint; dashes,
    /// spaces and case do not matter. More than one hit is never guessed at.
    func resolve(_ query: String) -> Match {
        let q = query.lowercased().filter { $0 != "-" && $0 != " " }
        guard q.count == 16 || q.count == 64,
              q.utf8.allSatisfy({ (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0) }) else {
            return .badQuery
        }
        let hits = all().filter { $0.id.hasPrefix(q) }
        switch hits.count {
        case 0: return .none
        case 1: return .one(hits[0])
        default: return .ambiguous(hits)
        }
    }

    // MARK: a device asking

    /// A device that proved it holds `publicKey` is asking to connect while
    /// approval is on. Unknown devices join the waiting list, within its
    /// limits. `hasOpenConnection` says whether a waiting device still has a
    /// connection open: only one without is ever replaced. It is called with
    /// the store locked, so it must not call the store.
    ///
    /// `group` is the asker's address group (`AddressGroup.of`). With one,
    /// room on the list is shared out by group (`RoomSharing`): a group holds
    /// at most `maxWaitingPerGroup` waiting devices and lists at most
    /// `maxNewPerMinutePerGroup` a minute, and a waiting device seen in the
    /// last `recentlySeen` seconds is never replaced. Without one only the
    /// limits for the whole list apply.
    func ask(publicKey: Data, name: String, address: String, group: String? = nil,
             hasOpenConnection: (String) -> Bool) -> Answer {
        guard DeviceIdentity.isValidPublicKey(publicKey) else { return .denied }
        let id = DeviceIdentity.id(ofPublicKey: publicKey)
        let name = Self.storedName(name)
        let address = AuthWire.cleanName(address)
        return mutate { list, t in
            if let i = list.firstIndex(where: { $0.id == id }) {
                // A known device gets the same answer whether or not the
                // note of this visit could be saved.
                switch list[i].state {
                case .denied:
                    // Nothing is recorded, so a denied device cannot make the
                    // host write to disk by reconnecting.
                    return (.denied, .denied)
                case .trusted:
                    Self.refresh(&list[i], name: name, address: address, now: t,
                                 atMostEvery: 60, soonerIfChanged: true)
                    return (.trusted, .trusted)
                case .waiting:
                    // It keeps the name it was first listed with until it
                    // is approved, so a name cannot be swapped under the
                    // user's eyes while the question is open.
                    Self.refresh(&list[i], name: name, address: address, now: t,
                                 atMostEvery: 10, soonerIfChanged: false, keepName: true)
                    return (.waiting, .waiting)
                }
            }
            self.recentAdds.removeAll { t - $0.time >= 60 || t < $0.time }
            guard self.recentAdds.count < Self.maxNewPerMinute else { return (.busy, .busy) }
            if let group {
                guard self.recentAdds.filter({ $0.group == group }).count < Self.maxNewPerMinutePerGroup else {
                    return (.busy, .busy)
                }
            }
            let waiting = list.filter { $0.state == .waiting }.sorted { $0.firstSeen < $1.firstSeen }
            if let group {
                let entries = waiting.map {
                    RoomSharing.Entry(group: AddressGroup.of($0.address), age: t - $0.lastSeen,
                                      removable: !hasOpenConnection($0.id) && t - $0.lastSeen >= Self.recentlySeen)
                }
                switch RoomSharing.decide(entries: entries, size: Self.maxWaiting,
                                          share: Self.maxWaitingPerGroup, group: group) {
                case .admit: break
                case .replace(let i): list.removeAll { $0.id == waiting[i].id }
                case .turnAway: return (.busy, .busy)
                }
            } else if waiting.count >= Self.maxWaiting {
                guard let stale = waiting.first(where: { !hasOpenConnection($0.id) }) else { return (.busy, .busy) }
                list.removeAll { $0.id == stale.id }
            }
            self.recentAdds.append((t, group))
            list.append(DeviceRecord(id: id, publicKey: Hex.encode(publicKey), name: name, state: .waiting,
                                     firstSeen: t, lastSeen: t, address: address,
                                     decidedAt: nil, decidedBy: nil))
            // A device that could not be listed cannot be approved either.
            return (.waiting, .busy)
        }
    }

    /// For selftests that list more new devices from one address in a minute
    /// than the host allows: forgets the new devices counted so far.
    func forgetRecentAdds() {
        lock.lock()
        recentAdds = []
        lock.unlock()
    }

    /// A device connected to a host that is not asking for approval: keeps a
    /// trusted device's name, address and last-seen time fresh. Adds nothing.
    func noteConnected(id: String, name: String, address: String) {
        let name = Self.storedName(name)
        let address = AuthWire.cleanName(address)
        mutate { list, t in
            guard let i = list.firstIndex(where: { $0.id == id }), list[i].state == .trusted else { return ((), ()) }
            Self.refresh(&list[i], name: name, address: address, now: t,
                         atMostEvery: 60, soonerIfChanged: true)
            return ((), ())
        }
    }

    // MARK: decisions

    /// Approves or denies a device. `by` says where the decision was made.
    /// With `onlyIfWaiting` (a decision relayed by another device) nothing
    /// but a device that is still waiting can be settled. Returns the record
    /// as it now stands, or nil if nothing changed.
    @discardableResult
    func decide(id: String, _ decision: Decision, by: String, onlyIfWaiting: Bool) -> DeviceRecord? {
        mutate { list, t in
            guard let i = list.firstIndex(where: { $0.id == id }) else { return (nil, nil) }
            if onlyIfWaiting && list[i].state != .waiting { return (nil, nil) }
            let target: DeviceState
            switch (decision, list[i].state) {
            case (.approve, .waiting), (.approve, .denied): target = .trusted
            case (.deny, .waiting): target = .denied
            default: return (nil, nil)
            }
            list[i].state = target
            list[i].decidedAt = t
            list[i].decidedBy = by
            return (list[i], nil)
        }
    }

    /// Takes trust away from a device: it becomes denied.
    @discardableResult
    func revoke(id: String, by: String) -> DeviceRecord? {
        mutate { list, t in
            guard let i = list.firstIndex(where: { $0.id == id }), list[i].state == .trusted else { return (nil, nil) }
            list[i].state = .denied
            list[i].decidedAt = t
            list[i].decidedBy = by
            return (list[i], nil)
        }
    }

    /// Removes a device whatever its state, so it may ask again.
    @discardableResult
    func forget(id: String) -> DeviceRecord? {
        mutate { list, _ in
            guard let i = list.firstIndex(where: { $0.id == id }) else { return (nil, nil) }
            return (list.remove(at: i), nil)
        }
    }

    // MARK: the file

    /// Runs `body` on the freshest list under the file lock, saves what it
    /// changed and tells observers. `body` returns its answer, and the answer
    /// to give instead when the change could not be saved; in that case the
    /// list stays as it was on disk.
    @discardableResult
    private func mutate<T>(_ body: (inout [DeviceRecord], TimeInterval) -> (saved: T, unsaved: T)) -> T {
        lock.lock()
        let before = records
        let fileLock = canPersist ? FileLock(directory.appendingPathComponent(Self.lockName)) : nil
        let t = now().timeIntervalSince1970
        // nil: there is a list on disk and it cannot be read right now.
        let disk: [DeviceRecord]? = canPersist ? readDisk() : records
        let start = disk ?? []
        var list = start.filter { !Self.isExpired($0, now: t) }
        let answer = body(&list, t)
        var result = answer.saved
        if canPersist, list != start {
            var saved = false
            if disk == nil {
                clog("DEVICES: the device list cannot be read, so nothing was changed")
            } else {
                do {
                    try write(list)
                    saved = true
                } catch {
                    clog("DEVICES: could not save the device list (\(error)) — nothing was changed")
                }
            }
            if !saved {
                list = start
                result = answer.unsaved
            }
        }
        records = list
        fileLock?.unlock()
        lock.unlock()
        if list != before { NotificationCenter.default.post(name: Self.didChange, object: self) }
        return result
    }

    /// Reads the list again after another process changed it.
    func reload() {
        guard canPersist else { return }
        lock.lock()
        let before = records
        let list = readDisk() ?? []
        records = list
        lock.unlock()
        if list != before { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }

    /// The list on disk. No file means no devices. A file whose contents make
    /// no sense is moved aside for the user to look at and also means no
    /// devices. nil means the file is there but could not be read: callers
    /// then trust nobody and leave the file alone.
    private func readDisk() -> [DeviceRecord]? {
        let url = fileURL
        let data: Data
        do {
            data = try SecureFile.read(url, maxBytes: Self.maxFileBytes)
        } catch SecureFileError.notFound {
            return []
        } catch SecureFileError.unsafe(let why) {
            setAside(url, why: why)
            return []
        } catch {
            clog("DEVICES: cannot read \(Self.fileName) (\(error)) — treating every device as unknown")
            return nil
        }
        guard let file = try? JSONDecoder().decode(DeviceFile.self, from: data), file.version == 1 else {
            setAside(url, why: "is not a version 1 device list")
            return []
        }
        return Self.sanitized(file.devices)
    }

    private func setAside(_ url: URL, why: String) {
        let aside = (try? SecureFile.moveAside(url)) ?? "(could not be moved)"
        clog("DEVICES: \(Self.fileName) \(why) — kept as \(aside). Every device has to be approved again.")
    }

    private func write(_ list: [DeviceRecord]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try SecureFile.replace(fileURL, contents: try encoder.encode(DeviceFile(version: 1, devices: list)))
    }

    /// Keeps only records that hold a real key and whose id is that key's
    /// hash, so an edited file cannot give one device another's id. Names and
    /// addresses are cleaned again for display.
    static func sanitized(_ list: [DeviceRecord]) -> [DeviceRecord] {
        var seen = Set<String>()
        var out: [DeviceRecord] = []
        var dropped = 0
        for var r in list {
            guard let key = Hex.decode(r.publicKey), DeviceIdentity.isValidPublicKey(key),
                  DeviceIdentity.id(ofPublicKey: key) == r.id, !seen.contains(r.id),
                  r.firstSeen.isFinite, r.lastSeen.isFinite else {
                dropped += 1
                continue
            }
            seen.insert(r.id)
            r.publicKey = Hex.encode(key)
            r.name = Self.storedName(r.name)
            r.address = AuthWire.cleanName(r.address)
            if let by = r.decidedBy, by != decidedOnHost, by != decidedOnCommandLine,
               !DeviceIdentity.isWellFormedId(by) {
                r.decidedBy = nil
            }
            if let at = r.decidedAt, !at.isFinite { r.decidedAt = nil }
            out.append(r)
        }
        if dropped > 0 { clog("DEVICES: ignored \(dropped) entr\(dropped == 1 ? "y" : "ies") in \(fileName) that did not hold a valid key and matching id") }
        // More waiting devices than the list allows can only come from an
        // edited file: keep the newest.
        let waiting = out.filter { $0.state == .waiting }.sorted { $0.firstSeen > $1.firstSeen }
        if waiting.count > maxWaiting {
            let extra = Set(waiting.dropFirst(maxWaiting).map(\.id))
            out.removeAll { extra.contains($0.id) }
        }
        return out
    }

    private static func isExpired(_ r: DeviceRecord, now: TimeInterval) -> Bool {
        r.state == .waiting && now - r.firstSeen > waitingLifetime
    }

    /// A name as the host stores and shows it: cleaned the way every name is,
    /// and without the characters that draw nothing.
    static func storedName(_ raw: String) -> String {
        NameSkeleton.visible(AuthWire.cleanName(raw))
    }

    /// Notes a visit by a known device: its name, address and the time. A
    /// visit is written down at most every `atMostEvery` seconds, or at once
    /// when the name or address changed and `soonerIfChanged` allows it. A
    /// waiting device is not allowed that, so it cannot make the host write
    /// to disk as fast as it can reconnect.
    private static func refresh(_ r: inout DeviceRecord, name: String, address: String,
                                now: TimeInterval, atMostEvery: TimeInterval, soonerIfChanged: Bool,
                                keepName: Bool = false) {
        let due = now - r.lastSeen >= atMostEvery || now < r.lastSeen
        let changed = (!keepName && !name.isEmpty && name != r.name) || address != r.address
        guard due || (soonerIfChanged && changed) else { return }
        if !name.isEmpty && !keepName { r.name = name }
        r.address = address
        r.lastSeen = now
    }

    // MARK: noticing other processes

    private func startWatching() {
        let fd = open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                               eventMask: [.write, .delete, .rename],
                                                               queue: watchQueue)
        source.setEventHandler { [weak self] in self?.scheduleReload() }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    /// On `watchQueue`. A save shows up as several directory events; one
    /// reload shortly after covers them.
    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        watchQueue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.reloadScheduled = false
            self.reload()
        }
    }
}
