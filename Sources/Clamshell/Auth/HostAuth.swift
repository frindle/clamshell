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
    /// `defaults write com.frindle.clamshell requireDeviceApproval -bool false`
    /// turns approval off. Anything but a clear "false" leaves it on.
    static let approvalDefaultsKey = "requireDeviceApproval"
    static let defaultsDomain = "com.frindle.clamshell"
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
        fileprivate init(close: @escaping () -> Void) { self.close = close }
    }

    private let lock = NSLock()
    private var approvalOverride: Bool?
    private var unanswered: [Unanswered] = []
    private var waitingConnections: [String: Int] = [:]
    private var sessions: [String: Int] = [:]
    private var clearSessions = 0
    private var lastSeenApproval: Bool?
    private var settingTimer: DispatchSourceTimer?

    /// `requireApproval` nil reads the user's setting; selftests pass a value.
    init(directory: URL, requireApproval: Bool? = nil, watch: Bool = true) {
        identity = HostIdentity.load(in: directory)
        store = DeviceTrustStore(directory: directory, watch: watch)
        self.directory = HostDirectory(directory: directory)
        approvalOverride = requireApproval
        hostName = Self.computerName()
        // Start from the setting as it is now, so the first change is noticed.
        lastSeenApproval = requireApproval ?? Self.storedRequireApproval()
    }

    deinit { settingTimer?.cancel() }

    // MARK: approval on or off

    /// True unless the user turned device approval off.
    var requireApproval: Bool {
        lock.lock()
        let override = approvalOverride
        lock.unlock()
        return override ?? Self.storedRequireApproval()
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
        timer.schedule(deadline: .now() + 5, repeating: 5)
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

    private static func storedRequireApproval() -> Bool {
        CFPreferencesAppSynchronize(defaultsDomain as CFString)
        let value = CFPreferencesCopyAppValue(approvalDefaultsKey as CFString, defaultsDomain as CFString)
        return (value as? Bool) ?? true
    }

    // MARK: connections that have not got in yet

    /// Counts a connection that was just sent the challenge. When too many
    /// are open the oldest is closed to make room: a real client answers in
    /// milliseconds, so a pile of silent connections cannot keep it out.
    /// `close` may be called on any thread.
    func addUnanswered(close: @escaping () -> Void) -> Unanswered {
        let token = Unanswered(close: close)
        lock.lock()
        unanswered.append(token)
        let evicted = unanswered.count > Self.maxUnansweredConnections ? unanswered.removeFirst() : nil
        lock.unlock()
        evicted?.close()
        return token
    }

    func removeUnanswered(_ token: Unanswered) {
        lock.lock()
        unanswered.removeAll { $0 === token }
        lock.unlock()
    }

    /// Counts a connection that starts waiting for approval. False when the
    /// host already has as many waiting as it allows.
    func admitWaiting(deviceId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard waitingConnections.values.reduce(0, +) < Self.maxWaitingConnections else { return false }
        waitingConnections[deviceId, default: 0] += 1
        return true
    }

    func releaseWaiting(deviceId: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let n = waitingConnections[deviceId] else { return }
        waitingConnections[deviceId] = n > 1 ? n - 1 : nil
    }

    func hasWaitingConnection(deviceId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return waitingConnections[deviceId] != nil
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
