import Foundation
import SystemConfiguration

// What every listener on this host shares when deciding who may connect: the
// host's identity key, the device list, whether approval is on, and the
// limits on connections that have not got in yet. The limits are counted for
// the whole process, because one host runs a listener per display.

final class HostAuth {
    /// The host's real state, in the user's state directory.
    static let shared = HostAuth(directory: HostState.directory, integrity: .keychain(for: HostState.directory))

    static let maxUnansweredConnections = 32
    static let maxWaitingConnections = 8
    /// What one address group may hold of each table (see `RoomSharing`).
    static let maxUnansweredPerGroup = 8
    static let maxWaitingConnectionsPerGroup = 3
    /// With integrity on (the real host), `defaults write ... -bool false` no
    /// longer turns approval off by itself: the value also needs the MAC that
    /// the host's own switch writes next to it (`approvalMACDefaultsKey`).
    /// Without a valid MAC a stored "false" reads as on. Anything but a clear
    /// "false" leaves it on in any case.
    static let approvalDefaultsKey = "requireDeviceApproval"
    static let approvalMACDefaultsKey = "requireDeviceApprovalMAC"
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
    private let readStoredMAC: () -> Any?
    private let saveStored: (Bool, String?) -> Void
    private let integrity: TrustIntegrity?
    private var loggedBadApprovalMAC = false

    /// `requireApproval` nil reads the user's setting; selftests pass a value.
    /// `settingPollInterval` is how often a change made from outside is looked
    /// for; `readStored`, `readStoredMAC` and `saveStored` replace the user's
    /// preferences, for tests. `integrity` nil keeps no MACs (tests and
    /// selftests); the real host passes the keychain-backed one.
    init(directory: URL, requireApproval: Bool? = nil, watch: Bool = true,
         settingPollInterval: TimeInterval = 5, readStored: (() -> Any?)? = nil,
         integrity: TrustIntegrity? = nil, readStoredMAC: (() -> Any?)? = nil,
         saveStored: ((Bool, String?) -> Void)? = nil) {
        self.settingPollInterval = settingPollInterval
        self.readStored = readStored ?? Self.storedPreference
        self.readStoredMAC = readStoredMAC ?? Self.storedMACPreference
        self.saveStored = saveStored ?? Self.savePreference
        self.integrity = integrity
        identity = HostIdentity.load(in: directory)
        // The setting is looked at first, so that a first run after an upgrade
        // signs it before the device list asks for the key.
        if requireApproval == nil {
            Self.adoptApprovalSetting(integrity: integrity, stored: self.readStored(), mac: self.readStoredMAC(),
                                      save: self.saveStored)
        }
        store = DeviceTrustStore(directory: directory, watch: watch, integrity: integrity)
        self.directory = HostDirectory(directory: directory)
        approvalOverride = requireApproval
        hostName = Self.computerName()
        // Start from the setting as it is now, so the first change is noticed.
        lastSeenApproval = requireApproval ?? Self.approval(fromStored: self.readStored(), mac: self.readStoredMAC(),
                                                            integrity: integrity)
    }

    /// First run with integrity checks: makes the key and signs the setting
    /// as the user left it, once. Later a setting without a valid MAC is not
    /// adopted.
    private static func adoptApprovalSetting(integrity: TrustIntegrity?, stored: Any?, mac: Any?,
                                             save: (Bool, String?) -> Void) {
        guard let integrity, mac == nil else { return }
        guard let key = integrity.beginMigration() else { return }
        let on = approval(fromStored: stored)
        if !on {
            save(false, TrustIntegrity.mac(key, domain: TrustIntegrity.approvalDomain, TrustIntegrity.approvalBytes(false)))
            clog("DEVICES: first run with integrity checks — signed the setting that device approval is off")
        }
    }

    deinit { settingTimer?.cancel() }

    // MARK: approval on or off

    /// True unless the user turned device approval off.
    var requireApproval: Bool {
        lock.lock()
        let override = approvalOverride
        lock.unlock()
        if let override { return override }
        let stored = readStored()
        let mac = readStoredMAC()
        let result = Self.approval(fromStored: stored, mac: mac, integrity: integrity)
        if result, !Self.approval(fromStored: stored) {
            lock.lock()
            let first = !loggedBadApprovalMAC
            loggedBadApprovalMAC = true
            lock.unlock()
            if first { clog("DEVICES: the setting turning device approval off has no valid integrity check — approval stays ON. Turn it off from the Clamshell menu instead.") }
        }
        return result
    }

    /// Saves the user's choice, with the MAC that makes it count, and tells
    /// the listeners. Turning approval off needs the integrity key; without
    /// it approval stays on and this returns false.
    @discardableResult
    func setRequireApproval(_ on: Bool) -> Bool {
        var mac: String?
        if let integrity {
            guard let key = integrity.keyForWrite() else {
                clog("DEVICES: cannot change the approval setting: the integrity key cannot be used")
                if !on { return false }
                saveStored(true, nil)
                noteApproval()
                return true
            }
            mac = TrustIntegrity.mac(key, domain: TrustIntegrity.approvalDomain, TrustIntegrity.approvalBytes(on))
        }
        saveStored(on, mac)
        noteApproval()
        return true
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

    private static func storedMACPreference() -> Any? {
        CFPreferencesAppSynchronize(defaultsDomain as CFString)
        return CFPreferencesCopyAppValue(approvalMACDefaultsKey as CFString, defaultsDomain as CFString)
    }

    private static func savePreference(_ on: Bool, _ mac: String?) {
        CFPreferencesSetAppValue(approvalDefaultsKey as CFString,
                                 on ? kCFBooleanTrue : kCFBooleanFalse,
                                 defaultsDomain as CFString)
        CFPreferencesSetAppValue(approvalMACDefaultsKey as CFString, mac.map { $0 as CFString }, defaultsDomain as CFString)
        CFPreferencesAppSynchronize(defaultsDomain as CFString)
    }

    /// The setting with integrity: a value that turns approval off counts
    /// only with a valid MAC for "off"; otherwise approval is on. Turning
    /// approval on needs no MAC, so a flipped value can only ever make the
    /// host stricter. Without `integrity` this is `approval(fromStored:)`.
    static func approval(fromStored value: Any?, mac: Any?, integrity: TrustIntegrity?) -> Bool {
        let parsed = approval(fromStored: value)
        guard let integrity, !parsed else { return parsed }
        guard let text = mac as? String, case .key(let key) = integrity.lookup(),
              TrustIntegrity.verify(key, domain: TrustIntegrity.approvalDomain,
                                    TrustIntegrity.approvalBytes(false), mac: text) else { return true }
        return false
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
