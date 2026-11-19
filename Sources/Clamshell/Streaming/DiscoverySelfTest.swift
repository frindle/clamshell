import Foundation
import dnssd

// Announces a service that only this machine can see, then asks the system's
// discovery service what it would tell a client: the port and the TXT record.
// That checks the one thing a unit test cannot, that the system accepts the
// registration and hands back what was built.
//
// Nothing is announced on the network and nothing listens on a port.
//
// macOS asks the user before a program may use the local network, and it asks
// for a machine-only service too. Where nobody can answer, the first
// registration is refused or never answered, and the selftest exits with
// `notAllowedHere` instead of 1 so that whoever runs it can tell "not allowed
// to try" from "tried and got it wrong". macOS does not ask root, so CI runs
// it again as root in that case; a second `notAllowedHere` is a failure.

enum DiscoverySelfTest {
    /// EX_TEMPFAIL: the system did not let this process announce at all.
    static let notAllowedHere: Int32 = 75

    /// What a lookup found. It is the lookup's callback context.
    private final class Lookup {
        let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var found: (port: UInt16, txt: Data)?

        func set(port: UInt16, txt: Data) {
            lock.lock()
            found = (port, txt)
            lock.unlock()
            done.signal()
        }

        var result: (port: UInt16, txt: Data)? {
            lock.lock()
            defer { lock.unlock() }
            return found
        }
    }

    private static let resolved: DNSServiceResolveReply = { _, _, _, error, _, _, port, txtLen, txtRecord, context in
        guard let context, error == DNSServiceErrorType(kDNSServiceErr_NoError) else { return }
        let lookup = Unmanaged<Lookup>.fromOpaque(context).takeUnretainedValue()
        let txt = txtRecord.map { Data(bytes: $0, count: Int(txtLen)) } ?? Data()
        // The port arrives in network byte order.
        lookup.set(port: UInt16(bigEndian: port), txt: txt)
    }

    /// The port and TXT record the discovery service has for the service
    /// called `name`, or nil when it has none within `seconds`.
    private static func lookUp(_ name: String, seconds: TimeInterval) -> (port: UInt16, txt: Data)? {
        let lookup = Lookup()
        let context = Unmanaged.passRetained(lookup)
        defer { context.release() }
        var ref: DNSServiceRef?
        let error = DNSServiceResolve(&ref, 0, BonjourAdvertiser.thisMachineOnly, name,
                                      NearbyHost.serviceType, "local.", resolved, context.toOpaque())
        guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else {
            print("  lookup could not start: DNS-SD error \(error)")
            return nil
        }
        let queue = DispatchQueue(label: "com.frindle.clamshell.discovery-selftest")
        guard DNSServiceSetDispatchQueue(ref, queue) == DNSServiceErrorType(kDNSServiceErr_NoError) else {
            DNSServiceRefDeallocate(ref)
            return nil
        }
        _ = lookup.done.wait(timeout: .now() + seconds)
        // On the queue the replies arrive on, so none is being handled.
        queue.sync { DNSServiceRefDeallocate(ref) }
        return lookup.result
    }

    /// The name the advertiser was given, once the system has answered.
    private static func announcedName(_ advertiser: BonjourAdvertiser, seconds: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if case .announced(let name) = advertiser.outcome { return name }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    static func run() -> Int32 {
        // Line by line, so the lines before a crash are not lost in a pipe.
        setvbuf(stdout, nil, _IOLBF, 0)
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print("\(ok ? "PASS" : "FAIL"): \(what)")
            if !ok { failures += 1 }
        }

        let hostId = String(repeating: "0123456789abcdef", count: 4)
        let expected = BonjourAdvertiser.txtRecord(BonjourAdvertiser.entries(hostId: hostId, name: "Selftest Mac"))
        let advertiser = BonjourAdvertiser(hostId: hostId, name: "Selftest Mac",
                                           interface: BonjourAdvertiser.thisMachineOnly)
        check(advertiser.outcome == .off, "nothing is announced before it is asked for")

        advertiser.start(port: 5996)
        guard let name = announcedName(advertiser, seconds: 15) else {
            let outcome = advertiser.outcome
            advertiser.stop()
            advertiser.settle()
            switch outcome {
            case .failed(let code):
                print("NOT ALLOWED HERE: the system refused the announcement: \(BonjourAdvertiser.describe(code)) (\(code))")
            default:
                print("NOT ALLOWED HERE: the system did not answer the announcement in 15 s (\(outcome)). It may be waiting for someone to allow Local Network access.")
            }
            return notAllowedHere
        }
        check(!name.isEmpty, "the system announced it under a name (\(name))")
        if let found = lookUp(name, seconds: 10) {
            check(found.port == 5996, "the announced port is the one asked for (\(found.port))")
            check(found.txt == expected, "the announced TXT record is the one built (\(found.txt.count) bytes)")
        } else {
            check(false, "the announced service can be looked up")
        }

        advertiser.start(port: 5996)
        advertiser.settle()
        check(advertiser.outcome == .announced(name), "asking again for the same port leaves the announcement alone")

        advertiser.start(port: 5995)
        if let renamed = announcedName(advertiser, seconds: 15) {
            // The withdrawal of the old port and the new registration reach
            // the discovery service one after the other; give it a moment.
            Thread.sleep(forTimeInterval: 1)
            check(lookUp(renamed, seconds: 10)?.port == 5995, "another port replaces the announcement")
        } else {
            check(false, "another port replaces the announcement (\(advertiser.outcome))")
        }

        advertiser.stop()
        advertiser.settle()
        check(advertiser.outcome == .off, "stopping reports nothing announced")
        Thread.sleep(forTimeInterval: 1)
        check(lookUp(name, seconds: 2) == nil, "a withdrawn service can no longer be looked up")

        // Start, replace and stop in quick succession: every registration is
        // given back, and nothing answers into an object that is gone.
        for i in 0..<40 {
            advertiser.start(port: 5990 + UInt16(i % 4))
            if i % 3 == 0 { advertiser.stop() }
        }
        advertiser.stop()
        advertiser.settle()
        Thread.sleep(forTimeInterval: 1)
        advertiser.settle()
        check(advertiser.outcome == .off, "starting and stopping in quick succession ends with nothing announced")
        check(lookUp(name, seconds: 2) == nil, "and nothing left behind")

        print(failures == 0 ? "PASS: discovery announces what it was asked to" : "FAIL: \(failures) discovery check(s) failed")
        return failures == 0 ? 0 : 1
    }
}
