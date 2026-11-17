import Foundation
import SystemConfiguration

// What every listener on this host shares when deciding who may connect: the
// host's identity key, the device list, whether approval is on, and the
// limits on connections that have not got in yet. The limits are counted for
// the whole process, because one host runs a listener per display.

final class HostAuth {
    /// The host's real state, in the user's state directory.
    static let shared = HostAuth(directory: HostState.directory)

    static let maxUnansweredConnections = 32
    static let maxWaitingConnections = 8
    /// What one address group may hold of each table (see `RoomSharing`).
    static let maxUnansweredPerGroup = 8
    static let maxWaitingConnectionsPerGroup = 3
    /// `defaults write com.frindle.clamshell requireDeviceApproval -bool false`
    /// turns approval off. Anything but a clear "false" leaves it on.
    static let approvalDefaultsKey = "requireDeviceApproval"
    static let defaultsDomain = "com.frindle.clamshell"
    /// `defaults write com.frindle.clamshell trustedProxies -array 192.0.2.7 198.51.100.0/24`
    /// lists proxies besides this Mac itself whose client-address headers are
    /// believed (see `ClientAddress`). Empty by default.
    static let trustedProxiesDefaultsKey = "trustedProxies"

    /// The proxies to believe, read from the user's preferences each time.
    var trustedProxies: TrustedProxies {
        trustedProxiesOverride ?? Self.storedTrustedProxies()
    }

    /// The setting as the user left it; the web relay reads it without a HostAuth.
    static func storedTrustedProxies() -> TrustedProxies {
        CFPreferencesAppSynchronize(defaultsDomain as CFString)
        return TrustedProxies.fromStored(
            CFPreferencesCopyAppValue(trustedProxiesDefaultsKey as CFString, defaultsDomain as CFString))
    }
    /// For selftests: replaces the setting.
    var trustedProxiesOverride: TrustedProxies?
    /// Posted in this process, with the HostAuth as object, when approval is
    /// switched on or off.
    static let approvalDidChange = Notification.Name("com.frindle.clamshell.approvalDidChange")

    let identity: HostIdentity
    let store: DeviceTrustStore
    /// Where this host's displays can be reached, for HOST_INFO.
    let directory: HostDirectory
    /// What this host calls itself in the challenge. A label only.
    let hostName: String

    /// How long a new connection has to answer the challenge.
    var responseDeadline: TimeInterval = 10
    /// How long one connection waits for the user's decision before it is
    /// told to come back.
    var approvalTimeout: TimeInterval = 600
    /// How often a waiting connection is told that it is still waiting.
    var pendingRepeat: TimeInterval = 20

    /// A connection that was sent the challenge and has not answered yet.
    final class Unanswered {
        fileprivate let close: () -> Void
        fileprivate let group: String
        fileprivate let seq: Int
        fileprivate init(group: String, seq: Int, close: @escaping () -> Void) {
            self.group = group
            self.seq = seq
            self.close = close
        }
    }

    /// A connection that proved its key and is waiting for the user's decision.
    final class Waiting {
        let deviceId: String
        fileprivate let group: String
        fileprivate let seq: Int
        /// Nil for an entry nothing may close to make room.
        fileprivate let close: (() -> Void)?
        fileprivate init(deviceId: String, group: String, seq: Int, close: (() -> Void)?) {
            self.deviceId = deviceId
            self.group = group
            self.seq = seq
            self.close = close
        }
    }

    private let lock = NSLock()
    private var approvalOverride: Bool?
    private var unanswered: [Unanswered] = []
    private var waitingConnections: [Waiting] = []
    private var nextSeq = 0
    private var sessions: [String: Int] = [:]
    private var clearSessions = 0
    private var lastSeenApproval: Bool?
    private var settingTimer: DispatchSourceTimer?
    private let settingPollInterval: TimeInterval
    /// Where the stored value is read from: the user's preferences, or a test.
    private let readStored: () -> Any?

    /// `requireApproval` nil reads the user's setting; selftests pass a value.
    /// `settingPollInterval` is how often a change made from outside is looked
    /// for; `readStored` replaces the read of the user's preferences, for tests.
    init(directory: URL, requireApproval: Bool? = nil, watch: Bool = true,
         settingPollInterval: TimeInterval = 5, readStored: (() -> Any?)? = nil) {
        self.settingPollInterval = settingPollInterval
        self.readStored = readStored ?? Self.storedPreference
        identity = HostIdentity.load(in: directory)
        store = DeviceTrustStore(directory: directory, watch: watch)
        self.directory = HostDirectory(directory: directory)
        approvalOverride = requireApproval
        hostName = Self.computerName()
        // Start from the setting as it is now, so the first change is noticed.
        lastSeenApproval = requireApproval ?? Self.approval(fromStored: self.readStored())
    }

    deinit { settingTimer?.cancel() }

    // MARK: approval on or off

    /// True unless the user turned device approval off.
    var requireApproval: Bool {
        lock.lock()
        let override = approvalOverride
        lock.unlock()
        return override ?? Self.approval(fromStored: readStored())
    }

    /// Saves the user's choice and tells the listeners.
    func setRequireApproval(_ on: Bool) {
        CFPreferencesSetAppValue(Self.approvalDefaultsKey as CFString,
                                 on ? kCFBooleanTrue : kCFBooleanFalse,
                                 Self.defaultsDomain as CFString)
        CFPreferencesAppSynchronize(Self.defaultsDomain as CFString)
        noteApproval()
    }

    /// For selftests: nil goes back to the user's setting.
    func overrideRequireApproval(_ value: Bool?) {
        lock.lock()
        approvalOverride = value
        lock.unlock()
        noteApproval()
    }

    /// Notices the setting being changed from outside this process, for
    /// example with `defaults write`. Safe to call more than once.
    func startWatchingSetting() {
        lock.lock()
        defer { lock.unlock() }
        guard settingTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + settingPollInterval, repeating: settingPollInterval)
        timer.setEventHandler { [weak self] in self?.noteApproval() }
        timer.resume()
        settingTimer = timer
    }

    private func noteApproval() {
        let current = requireApproval
        lock.lock()
        let changed = lastSeenApproval != current
        lastSeenApproval = current
        lock.unlock()
        if changed {
            clog("DEVICES: device approval is now \(current ? "on" : "OFF — any device that reaches this Mac can control it")")
            NotificationCenter.default.post(name: Self.approvalDidChange, object: self)
        }
    }

    private static func storedPreference() -> Any? {
        CFPreferencesAppSynchronize(defaultsDomain as CFString)
        return CFPreferencesCopyAppValue(approvalDefaultsKey as CFString, defaultsDomain as CFString)
    }

    /// Only the boolean false and the integer 0 turn approval off. Anything
    /// else, of any type, and no value at all, leave it on.
    static func approval(fromStored value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return true }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
        if CFNumberIsFloatType(number) { return true }
        return number.int64Value != 0
    }

    // MARK: connections that have not got in yet

    /// Counts a connection that was just sent the challenge. Room is shared
    /// out by address group (`RoomSharing`): a group at its share, or a full
    /// table, costs the oldest connection of the group holding the most. A
    /// real client answers in milliseconds, so a pile of silent connections
    /// cannot keep it out. A connection with no group is counted against the
    /// whole table only.
    /// `close` may be called on any thread; it is called for the connection
    /// that lost its place, which is the new one when it is turned away.
    func addUnanswered(group: String? = nil, close: @escaping () -> Void) -> Unanswered {
        lock.lock()
        nextSeq += 1
        let token = Unanswered(group: group ?? "", seq: nextSeq, close: close)
        let entries = unanswered.map { RoomSharing.Entry(group: $0.group, age: Double(nextSeq - $0.seq)) }
        let share = group == nil ? Self.maxUnansweredConnections : Self.maxUnansweredPerGroup
        var closing: Unanswered?
        switch RoomSharing.decide(entries: entries, size: Self.maxUnansweredConnections, share: share, group: token.group) {
        case .admit:
            unanswered.append(token)
        case .replace(let i):
            closing = unanswered.remove(at: i)
            unanswered.append(token)
        case .turnAway:
            closing = token
        }
        lock.unlock()
        closing?.close()
        return token
    }

    func removeUnanswered(_ token: Unanswered) {
        lock.lock()
        unanswered.removeAll { $0 === token }
        lock.unlock()
    }

    /// Counts a connection that starts waiting for approval, sharing the
    /// table out by address group. Nil when the connection is turned away.
    /// `close` is called, on any thread, for a waiting connection that loses
    /// its place to this one.
    func admitWaitingConnection(deviceId: String, group: String, close: @escaping () -> Void) -> Waiting? {
        lock.lock()
        nextSeq += 1
        let token = Waiting(deviceId: deviceId, group: group, seq: nextSeq, close: close)
        let entries = waitingConnections.map {
            RoomSharing.Entry(group: $0.group, age: Double(nextSeq - $0.seq), removable: $0.close != nil)
        }
        var closing: Waiting?
        var admitted: Waiting? = token
        switch RoomSharing.decide(entries: entries, size: Self.maxWaitingConnections,
                                  share: Self.maxWaitingConnectionsPerGroup, group: group) {
        case .admit:
            waitingConnections.append(token)
        case .replace(let i):
            closing = waitingConnections.remove(at: i)
            waitingConnections.append(token)
        case .turnAway:
            admitted = nil
        }
        lock.unlock()
        closing?.close?()
        return admitted
    }

    func releaseWaiting(_ token: Waiting) {
        lock.lock()
        waitingConnections.removeAll { $0 === token }
        lock.unlock()
    }

    /// Counts a connection that cannot be closed to make room, against the
    /// whole table. False when the host already has as many waiting as it
    /// allows. Release it with `releaseWaiting(deviceId:)`.
    func admitWaiting(deviceId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        nextSeq += 1
        let token = Waiting(deviceId: deviceId, group: "", seq: nextSeq, close: nil)
        let entries = waitingConnections.map {
            RoomSharing.Entry(group: $0.group, age: Double(nextSeq - $0.seq), removable: $0.close != nil)
        }
        guard RoomSharing.decide(entries: entries, size: Self.maxWaitingConnections,
                                 share: Self.maxWaitingConnections, group: "") == .admit else { return false }
        waitingConnections.append(token)
        return true
    }

    func releaseWaiting(deviceId: String) {
        lock.lock()
        defer { lock.unlock() }
        if let i = waitingConnections.firstIndex(where: { $0.deviceId == deviceId }) {
            waitingConnections.remove(at: i)
        }
    }

    func hasWaitingConnection(deviceId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return waitingConnections.contains { $0.deviceId == deviceId }
    }

    // MARK: sessions that are open now

    /// Counts a session a device was let into, so the host can show who is
    /// connected. `deviceId` nil is a clear session, which has no device.
    func sessionOpened(deviceId: String?) {
        lock.lock()
        defer { lock.unlock() }
        if let deviceId {
            sessions[deviceId, default: 0] += 1
        } else {
            clearSessions += 1
        }
    }

    func sessionClosed(deviceId: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard let deviceId else {
            clearSessions = max(0, clearSessions - 1)
            return
        }
        guard let n = sessions[deviceId] else { return }
        sessions[deviceId] = n > 1 ? n - 1 : nil
    }

    /// How many sessions each device has open in this process now, by device
    /// id, and how many clear sessions are open besides. With approval off a
    /// device in here need not be a trusted one.
    func openSessions() -> (devices: [String: Int], clear: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (sessions, clearSessions)
    }

    /// How many open sessions no approval stands behind: the clear ones, and
    /// those of devices that are not on the trusted list. Only a host with
    /// approval off has any.
    func unapprovedSessions() -> Int {
        let open = openSessions()
        guard !open.devices.isEmpty else { return open.clear }
        let trusted = Set(store.all().filter { $0.state == .trusted }.map(\.id))
        return open.clear + open.devices.reduce(0) { $0 + (trusted.contains($1.key) ? 0 : $1.value) }
    }

    // MARK: -

    private static func computerName() -> String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !AuthWire.cleanName(name).isEmpty {
            return name
        }
        return ProcessInfo.processInfo.hostName
    }
}
