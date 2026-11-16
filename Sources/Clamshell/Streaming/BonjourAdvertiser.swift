import Foundation
import dnssd

// Tells the local network that this Mac is a Clamshell host (PROTOCOL.md
// "Discovery (Bonjour)"), so a client can list it instead of asking for an
// address.
//
// The advertisement is registered by itself, not as part of a stream
// listener, so that nothing about announcing can keep a listener from
// accepting connections: not the Local Network permission it needs, not a
// name conflict, not a discovery service that does not answer. When it fails
// the host is missing from the client's list and still answers a client that
// has its address.
//
// What is announced is a hint. A client that finds this host still has to be
// shown the host key it saved, and the host still has to approve the device.

final class BonjourAdvertiser {
    enum Outcome: Equatable {
        /// Not asked for.
        case off
        /// Asked for, no answer yet. It stays like this while the system's
        /// Local Network question is unanswered.
        case starting
        /// On the network under this name.
        case announced(String)
        /// Refused, with the DNS-SD error code. It is asked for again later.
        case failed(Int32)
    }

    /// `defaults write com.frindle.clamshell announceOnLAN -bool false` turns
    /// the advertisement off. Anything but a clear "false" leaves it on.
    static let defaultsKey = "announceOnLAN"

    static var isEnabled: Bool {
        CFPreferencesAppSynchronize(HostAuth.defaultsDomain as CFString)
        let value = CFPreferencesCopyAppValue(defaultsKey as CFString, HostAuth.defaultsDomain as CFString)
        return (value as? Bool) ?? true
    }

    static func setEnabled(_ on: Bool) {
        CFPreferencesSetAppValue(defaultsKey as CFString, on ? kCFBooleanTrue : kCFBooleanFalse,
                                 HostAuth.defaultsDomain as CFString)
        CFPreferencesAppSynchronize(HostAuth.defaultsDomain as CFString)
    }

    /// Every network interface.
    static let everyInterface: UInt32 = 0
    /// `kDNSServiceInterfaceIndexLocalOnly`: other programs on this machine
    /// can find the service, the network cannot. For the selftest.
    static let thisMachineOnly: UInt32 = .max

    // MARK: - What is announced

    /// The TXT entries of PROTOCOL.md "Discovery": the handshake version, the
    /// first 16 characters of the host id, the host's name and its kind. The
    /// name is left out when nothing of it can be shown.
    static func entries(hostId: String, name: String) -> [(key: String, value: String)] {
        var entries: [(key: String, value: String)] = [
            ("v", String(AuthWire.version)),
            ("id", String(hostId.prefix(16))),
        ]
        let shown = AuthWire.cleanName(name)
        if !shown.isEmpty { entries.append(("name", shown)) }
        entries.append(("kind", "mac"))
        return entries
    }

    /// A DNS-SD TXT record: each entry is one length byte, then `key=value`.
    /// An entry is left out when its key is not printable ASCII or holds an
    /// `=`, or when it does not fit in 255 bytes. A record must hold at least
    /// one byte, so with no entries it is a single zero.
    static func txtRecord(_ entries: [(key: String, value: String)]) -> Data {
        var record = Data()
        for entry in entries {
            let key = Array(entry.key.utf8)
            guard !key.isEmpty, key.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E && $0 != UInt8(ascii: "=") }) else { continue }
            let bytes = key + [UInt8(ascii: "=")] + Array(entry.value.utf8)
            guard bytes.count <= 255 else { continue }
            record.append(UInt8(bytes.count))
            record.append(contentsOf: bytes)
        }
        return record.isEmpty ? Data([0]) : record
    }

    /// A DNS-SD error in words the menu and the log can show.
    static func describe(_ error: Int32) -> String {
        switch Int(error) {
        case kDNSServiceErr_PolicyDenied:
            return "Local Network access is off for Clamshell in System Settings › Privacy & Security"
        case kDNSServiceErr_ServiceNotRunning, kDNSServiceErr_DefunctConnection:
            return "the system's discovery service stopped answering"
        case kDNSServiceErr_NameConflict:
            return "another service on the network has this Mac's name"
        default:
            return "DNS-SD error \(error)"
        }
    }

    /// Seconds to wait before asking again after this many failures in a row:
    /// 5, 10, 20 and so on, up to five minutes. The discovery service may
    /// have restarted, or the user may have allowed Local Network access in
    /// the meantime, and nothing tells the host when that happens.
    static func retryDelay(afterFailures failures: Int) -> TimeInterval {
        min(300, 5 * pow(2, Double(max(0, min(failures, 10) - 1))))
    }

    // MARK: - Registering

    /// One announcement of one port. It asks the system, keeps what the
    /// system answered, and asks again after a failure until it is withdrawn.
    ///
    /// It is its own callback context: the system's callback holds a
    /// reference from a successful `DNSServiceRegister` until `close`.
    private final class Registration {
        let port: UInt16
        private let txt: Data
        private let interface: UInt32
        private let queue: DispatchQueue
        private let lock = NSLock()
        private var current: Outcome = .starting
        // The rest is touched on `queue` only.
        private var ref: DNSServiceRef?
        private var withdrawn = false
        private var failures = 0

        init(port: UInt16, txt: Data, interface: UInt32, queue: DispatchQueue) {
            self.port = port
            self.txt = txt
            self.interface = interface
            self.queue = queue
        }

        var outcome: Outcome {
            lock.lock()
            defer { lock.unlock() }
            return current
        }

        /// On the queue.
        func begin() {
            guard !withdrawn, ref == nil else { return }
            let context = Unmanaged.passRetained(self)
            var ref: DNSServiceRef?
            // No name: the system uses the computer's name and picks another
            // if that one is taken. The port goes in network byte order.
            let error = txt.withUnsafeBytes { bytes in
                DNSServiceRegister(&ref, 0, interface, nil, NearbyHost.serviceType, nil, nil,
                                   port.bigEndian, UInt16(txt.count), bytes.baseAddress,
                                   BonjourAdvertiser.reply, context.toOpaque())
            }
            guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else {
                context.release()
                failed(error)
                return
            }
            self.ref = ref
            let queued = DNSServiceSetDispatchQueue(ref, queue)
            if queued != DNSServiceErrorType(kDNSServiceErr_NoError) {
                close()
                failed(queued)
            }
        }

        /// On the queue. The advertiser is done with this announcement.
        func withdraw() {
            withdrawn = true
            close()
        }

        /// On the queue. Replies are delivered on it too, so none is in the
        /// middle of being handled. The callback's reference goes after
        /// whatever is already waiting on the queue, so a reply that was on
        /// its way still finds this object and is ignored for its stale ref.
        private func close() {
            guard let ref else { return }
            self.ref = nil
            DNSServiceRefDeallocate(ref)
            let context = Unmanaged.passUnretained(self)
            queue.async { context.release() }
        }

        /// On the queue: what the system answered.
        func replied(from ref: DNSServiceRef?, flags: DNSServiceFlags, error: DNSServiceErrorType, name: String) {
            guard let ref, ref == self.ref else { return }
            guard error == DNSServiceErrorType(kDNSServiceErr_NoError) else {
                // After an error the system expects the registration back.
                close()
                failed(error)
                return
            }
            if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0 {
                failures = 0
                note(.announced(name))
            } else {
                // The name was taken away; the system answers again when it
                // has registered another.
                note(.starting)
            }
        }

        /// On the queue.
        private func failed(_ error: DNSServiceErrorType) {
            failures += 1
            note(.failed(error))
            queue.asyncAfter(deadline: .now() + BonjourAdvertiser.retryDelay(afterFailures: failures)) { [weak self] in
                self?.begin()
            }
        }

        /// Records the outcome and logs it when it is not the one before, so
        /// a refusal that repeats at every retry is logged once.
        private func note(_ outcome: Outcome) {
            lock.lock()
            let changed = current != outcome
            current = outcome
            lock.unlock()
            guard changed else { return }
            switch outcome {
            case .announced(let name):
                clog("DISCOVERY: announced on the local network as \u{201C}\(name)\u{201D}, port \(port)")
            case .failed(let code):
                clog("DISCOVERY: could not announce this Mac on the local network: \(BonjourAdvertiser.describe(code)). Clients can still connect by address. Asking again later.")
            case .starting:
                clog("DISCOVERY: the system withdrew the announcement; waiting for it to come back")
            case .off:
                break
            }
        }
    }

    private static let reply: DNSServiceRegisterReply = { ref, flags, error, name, _, _, context in
        guard let context else { return }
        let registration = Unmanaged<Registration>.fromOpaque(context).takeUnretainedValue()
        registration.replied(from: ref, flags: flags, error: error, name: name.map { String(cString: $0) } ?? "")
    }

    private let queue = DispatchQueue(label: "com.frindle.clamshell.discovery")
    private let txt: Data
    private let interface: UInt32
    private let lock = NSLock()
    private var registration: Registration?

    init(hostId: String, name: String, interface: UInt32 = BonjourAdvertiser.everyInterface) {
        txt = Self.txtRecord(Self.entries(hostId: hostId, name: name))
        self.interface = interface
    }

    deinit {
        if let registration { queue.async { registration.withdraw() } }
    }

    var outcome: Outcome {
        lock.lock()
        defer { lock.unlock() }
        return registration?.outcome ?? .off
    }

    /// Announces `port`. Does nothing when that port is already announced or
    /// being asked for.
    func start(port: UInt16) {
        lock.lock()
        if let registration, registration.port == port {
            lock.unlock()
            return
        }
        let old = registration
        let new = Registration(port: port, txt: txt, interface: interface, queue: queue)
        registration = new
        lock.unlock()
        queue.async {
            old?.withdraw()
            new.begin()
        }
    }

    func stop() {
        lock.lock()
        let old = registration
        registration = nil
        lock.unlock()
        guard let old else { return }
        queue.async { old.withdraw() }
        clog("DISCOVERY: no longer announced on the local network")
    }

    /// Returns when everything asked for so far has been handed to the
    /// system. For the selftest.
    func settle() {
        queue.sync {}
    }
}
