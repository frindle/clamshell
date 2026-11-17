import Foundation

// The one copy of the known-hosts list the whole app shares (the iPad viewer,
// its external-display client and the iPhone surface all connect to the same
// Macs). It holds public keys and addresses only, so UserDefaults is fine.
// Main thread only.
//
// A saved copy that cannot be read is refused, never replaced (see
// KnownHostsKeeper): `damage` is then set, connections stop with a plain
// message, nothing is written, and "Reset saved Macs..." is the way out.

private final class UserDefaultsBlobs: KnownHostsBlobStore {
    func read(_ name: String) -> Data? { UserDefaults.standard.data(forKey: name) }
    func write(_ data: Data, as name: String) { UserDefaults.standard.set(data, forKey: name) }
    func remove(_ name: String) { UserDefaults.standard.removeObject(forKey: name) }
}

final class KnownHostsStore: ObservableObject {
    static let shared = KnownHostsStore()

    private let keeper = KnownHostsKeeper(blobs: UserDefaultsBlobs())

    @Published private(set) var hosts: KnownHosts
    /// Non-nil when the saved Macs could not be read: what to tell the person.
    @Published private(set) var damage: String?

    private init() {
        hosts = keeper.hosts
        damage = keeper.damage
        if damage != nil {
            clogViewer("the saved Mac identities could not be read; refusing to connect and leaving them as they are")
        }
    }

    /// Applies one change with the app clock and saves.
    func apply(_ change: KnownHostsChange) {
        guard keeper.apply(change, now: Date().timeIntervalSince1970) else { return }
        hosts = keeper.hosts
    }

    /// Records that an address was dialled, for the order addresses are tried in.
    func markDialled(address: String) {
        keeper.markDialled(address: address, now: Date().timeIntervalSince1970)
        hosts = keeper.hosts
    }

    func forget(hostId: String) {
        apply(.forget(hostId: hostId))
    }

    /// Puts a damaged saved copy aside (under `known-hosts.damaged-<UTC
    /// timestamp>.json`, nothing is deleted) and starts with no saved Macs.
    func resetDamaged() {
        if let kept = keeper.reset(at: Date()) {
            clogViewer("the damaged saved Macs were kept as \(kept); starting with none")
        }
        hosts = keeper.hosts
        damage = keeper.damage
    }
}
