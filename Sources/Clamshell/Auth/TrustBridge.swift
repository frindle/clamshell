import Foundation
import Security

// A self-update changes the code hash of Clamshell. The keychain item that
// holds the integrity key only lets the build that made it read without
// asking, so without help the first launch of the new build would stop at a
// password prompt that nobody is there to answer (a Mac with no screen).
//
// The bridge: just before it restarts into the new build, the old build, which
// can read the key, leaves a short-lived hand-off file for exactly that new
// build. The new build reads it once, stores the key under an item it made
// itself (so it can read it later without asking), and removes the file.
//
// What the file is worth to an attacker: while it exists (at most
// `lifetime` seconds, normally a few) a program running as the same user can
// read the key. That program can already write the device list, which is the
// thing the key protects, so the window is the price of an update that needs
// no password. The file is owner-only (0600), never a symbolic link, names
// the one code hash that may take it, and is deleted by whoever looks at it.
// No "allow all applications" access is ever set on the keychain item.
enum TrustBridge {
    static let fileName = "integrity-handoff"
    static let lifetime: TimeInterval = 600
    static let maxBytes = 1024

    struct Offer: Codable, Equatable {
        var key: String
        var cdhash: String
        var expires: Double
    }

    enum TakeResult: Equatable {
        case key(Data)
        case none
        /// A hand-off file was there but is not for this build or is stale;
        /// it was removed.
        case rejected(String)
    }

    static func url(in directory: URL) -> URL { directory.appendingPathComponent(fileName) }

    static func offer(key: Data, forCdhash cdhash: String, directory: URL, now: Date = Date()) throws {
        guard key.count == 32, !cdhash.isEmpty else { throw SecureFileError.unsafe("nothing to hand off") }
        let offer = Offer(key: Hex.encode(key), cdhash: cdhash, expires: now.timeIntervalSince1970 + lifetime)
        try SecureFile.replace(url(in: directory), contents: try JSONEncoder().encode(offer))
    }

    /// The key for `ownCdhash`, once. Always removes a file it looked at.
    static func take(directory: URL, ownCdhash: String, now: Date = Date()) -> TakeResult {
        let file = url(in: directory)
        let data: Data
        do { data = try SecureFile.read(file, maxBytes: maxBytes) } catch SecureFileError.notFound {
            return .none
        } catch {
            unlink(file.path)
            return .rejected("the hand-off file was not safe to read (\(error))")
        }
        unlink(file.path)
        guard let offer = try? JSONDecoder().decode(Offer.self, from: data),
              let key = Hex.decode(offer.key), key.count == 32 else {
            return .rejected("the hand-off file is not valid")
        }
        guard now.timeIntervalSince1970 <= offer.expires, offer.expires - now.timeIntervalSince1970 <= lifetime else {
            return .rejected("the hand-off file had expired")
        }
        guard offer.cdhash == ownCdhash else { return .rejected("the hand-off file is for a different build") }
        return .key(key)
    }

    /// Called by the old build once the new one is in place and before the
    /// restart. Does nothing (and says so) when the key cannot be read here.
    static func handOff(toApp path: String, directory: URL) {
        guard let hash = cdhash(ofApp: path) else {
            clog("INTEGRITY: no update hand-off (cannot read the new build's code hash)")
            return
        }
        guard case .key(let key) = TrustIntegrity.keychain(for: directory).lookup() else {
            clog("INTEGRITY: no update hand-off (the key cannot be read by this build either)")
            return
        }
        let bytes = key.withUnsafeBytes { Data($0) }
        do {
            try offer(key: bytes, forCdhash: hash, directory: directory)
            clog("INTEGRITY: left a short-lived hand-off for the new build so the update needs no Keychain approval")
        } catch {
            clog("INTEGRITY: no update hand-off (\(error))")
        }
    }

    /// Hex code hash of the app at `path`, nil when unsigned or unreadable.
    static func cdhash(ofApp path: String) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, SecCSFlags(), &code) == errSecSuccess,
              let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let unique = dict[kSecCodeInfoUnique as String] as? Data else { return nil }
        return Hex.encode(unique)
    }

    /// Code hash of the running build.
    static let ownCdhash: String? = {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let unique = dict[kSecCodeInfoUnique as String] as? Data else { return nil }
        return Hex.encode(unique)
    }()
}

/// Where to look for the integrity key, in order, and what to do about what is
/// found. Pure, so the order is tested without a keychain.
struct IntegrityKeyResolver {
    /// The item made by this build.
    var readBuild: () throws -> Data?
    /// The hand-off from the previous build, if there is one for this build.
    var takeBridge: () -> Data?
    /// The item an earlier build made (may need the user to approve).
    var readLegacy: () throws -> Data?
    /// Stores under this build's own item.
    var storeBuild: (Data) -> Void

    func resolve() throws -> Data? {
        if let own = try readBuild() { return own }
        if let handed = takeBridge() {
            storeBuild(handed)
            return handed
        }
        if let old = try readLegacy() {
            storeBuild(old)
            return old
        }
        return nil
    }
}
