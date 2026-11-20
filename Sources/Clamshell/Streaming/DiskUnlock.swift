import Foundation
import CryptoKit

// "Unlock disk": the iPad and Windows apps SSH straight to the Mac's pre-boot
// sshd (port 22) and sign in with the FileVault user's name and password, which
// is how macOS 26 and later unlocks the disk before it boots. This file is the
// part that does not depend on an SSH library, so it is tested in CI and shared
// with the iOS app: host-key pinning, the overall timeout and the result words.
// An SSH library is plugged in as an `SSHUnlockTransport`.
//
// Rules: the host key is checked before any password is sent (the transport sends
// it only after `acceptHostKey` said yes); the first key seen for an address is
// shown and pinned only if the user says yes; a different key later is refused;
// nothing here ever logs a user name or password.

enum SSHFingerprint {
    /// OpenSSH's form: "SHA256:" and the unpadded base64 of the SHA-256 of the key blob.
    static func sha256(ofKeyBlob blob: Data) -> String {
        "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}

/// The host keys the user has accepted, by "host:port".
struct SSHHostPins: Equatable {
    enum Decision: Equatable {
        case trusted
        case ask(fingerprint: String)
        case mismatch(expected: String, got: String)
    }

    private(set) var pins: [String: String]

    init(_ pins: [String: String] = [:]) { self.pins = pins }

    static func endpoint(host: String, port: Int) -> String { "\(host.lowercased()):\(port)" }

    func decide(endpoint: String, fingerprint: String) -> Decision {
        guard let known = pins[endpoint] else { return .ask(fingerprint: fingerprint) }
        return known == fingerprint ? .trusted : .mismatch(expected: known, got: fingerprint)
    }

    mutating func pin(endpoint: String, fingerprint: String) { pins[endpoint] = fingerprint }
    mutating func forget(endpoint: String) { pins[endpoint] = nil }
}

enum DiskUnlockResult: Equatable {
    case unlocked
    case wrongPassword
    case hostKeyMismatch
    case hostKeyDeclined
    case unreachable
    case timedOut
    case failed

    var text: String {
        switch self {
        case .unlocked: return "Unlocked. Waiting for the Mac to start…"
        case .wrongPassword: return "The Mac did not accept that user name and password. The Mac allows only a few tries."
        case .hostKeyMismatch: return "The Mac's SSH key is not the one you trusted before. Nothing was sent. If you did not change the Mac, someone may be in the way."
        case .hostKeyDeclined: return "Not trusted, so nothing was sent."
        case .unreachable: return "Could not reach the Mac's unlock service. It may still be starting, or Remote Login may be off."
        case .timedOut: return "The Mac did not finish in time."
        case .failed: return "The unlock did not work."
        }
    }
}

/// What an SSH library reports back, before pinning is folded in.
enum SSHAttempt: Equatable {
    case authenticated      // signed in; the Mac then ends the session by itself
    case authFailed         // the Mac refused the password
    case hostKeyRefused     // acceptHostKey said no; nothing was sent
    case connectFailed
    case failed
}

protocol SSHUnlockTransport {
    /// Connects, calls `acceptHostKey` with the key's fingerprint BEFORE sending any secret,
    /// and signs in only if it returns true. Gives up connecting after `connectTimeout` seconds.
    func attempt(host: String, port: Int, username: String, password: String,
                 connectTimeout: TimeInterval, acceptHostKey: @escaping (String) async -> Bool) async -> SSHAttempt
}

final class DiskUnlocker {
    static let connectTimeout: TimeInterval = 10
    static let overallTimeout: TimeInterval = 60

    private let transport: SSHUnlockTransport
    private let loadPins: () -> SSHHostPins
    private let savePins: (SSHHostPins) -> Void
    /// Shows the fingerprint of a key seen for the first time and returns the user's yes or no.
    private let askToTrust: (_ endpoint: String, _ fingerprint: String) async -> Bool
    private let log: (String) -> Void
    private let overall: TimeInterval

    init(transport: SSHUnlockTransport, loadPins: @escaping () -> SSHHostPins, savePins: @escaping (SSHHostPins) -> Void,
         askToTrust: @escaping (String, String) async -> Bool, log: @escaping (String) -> Void = { _ in },
         overallTimeout: TimeInterval = DiskUnlocker.overallTimeout) {
        self.transport = transport
        self.loadPins = loadPins
        self.savePins = savePins
        self.askToTrust = askToTrust
        self.log = log
        self.overall = overallTimeout
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var mismatch = false
        func markMismatch() { lock.lock(); mismatch = true; lock.unlock() }
        var wasMismatch: Bool { lock.lock(); defer { lock.unlock() }; return mismatch }
    }

    func unlock(host: String, port: Int = 22, username: String, password: String) async -> DiskUnlockResult {
        let endpoint = SSHHostPins.endpoint(host: host, port: port)
        let box = Box()
        let transport = self.transport, loadPins = self.loadPins, savePins = self.savePins
        let ask = self.askToTrust, log = self.log
        let result: DiskUnlockResult? = await withTaskGroup(of: DiskUnlockResult?.self) { group in
            group.addTask {
                log("unlock: connecting")
                let attempt = await transport.attempt(
                    host: host, port: port, username: username, password: password,
                    connectTimeout: Self.connectTimeout) { fingerprint in
                    var pins = loadPins()
                    switch pins.decide(endpoint: endpoint, fingerprint: fingerprint) {
                    case .trusted:
                        return true
                    case .mismatch:
                        box.markMismatch()
                        log("unlock: host key does not match the pinned one")
                        return false
                    case .ask:
                        guard await ask(endpoint, fingerprint) else { return false }
                        pins.pin(endpoint: endpoint, fingerprint: fingerprint)
                        savePins(pins)
                        log("unlock: host key pinned")
                        return true
                    }
                }
                switch attempt {
                case .authenticated: return .unlocked
                case .authFailed: return .wrongPassword
                case .hostKeyRefused: return box.wasMismatch ? .hostKeyMismatch : .hostKeyDeclined
                case .connectFailed: return .unreachable
                case .failed: return .failed
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(self.overall * 1_000_000_000))
                return Task.isCancelled ? nil : .timedOut
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let final = result ?? .failed
        log("unlock: \(final)")
        return final
    }
}
