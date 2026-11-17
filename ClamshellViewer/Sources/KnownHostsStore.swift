import Foundation

// The one copy of the known-hosts list the whole app shares (the iPad viewer,
// its external-display client and the iPhone surface all connect to the same
// Macs). It holds public keys and addresses only, so UserDefaults is fine.
// Main thread only.

final class KnownHostsStore: ObservableObject {
    static let shared = KnownHostsStore()

    private static let key = "clamshell.knownHosts.v1"

    @Published private(set) var hosts: KnownHosts

    private init() {
        let (loaded, damaged) = KnownHosts.decode(UserDefaults.standard.data(forKey: Self.key))
        hosts = loaded
        if damaged {
            clogViewer("the saved Mac identities could not all be read; kept \(loaded.hosts.count)")
        }
    }

    /// Applies one change with the app clock and saves.
    func apply(_ change: KnownHostsChange) {
        var next = hosts
        change.apply(to: &next, now: Date().timeIntervalSince1970)
        guard next != hosts else { return }
        hosts = next
        save()
    }

    /// Records that an address was dialled, for the order addresses are tried in.
    func markDialled(address: String) {
        var next = hosts
        next.markDialled(address: address, now: Date().timeIntervalSince1970)
        hosts = next
        save()
    }

    func forget(hostId: String) {
        apply(.forget(hostId: hostId))
    }

    private func save() {
        UserDefaults.standard.set(hosts.encoded(), forKey: Self.key)
    }
}
