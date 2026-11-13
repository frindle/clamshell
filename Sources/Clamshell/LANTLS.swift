import Foundation
import Network
import Security

/// Optional TLS for the browser-facing LAN listeners (the web page on 5901,
/// the VNC websocket and the three stream bridges). Inert until a PEM
/// certificate and private key are configured; with nothing configured every
/// listener is plain exactly as before.
///
/// Where the paths come from, first match wins:
///   1. defaults keys `lanTLSCertPath` and `lanTLSKeyPath`
///      (`defaults write com.frindle.clamshell lanTLSCertPath /path/cert.pem`)
///   2. `~/Library/Application Support/Clamshell/lan-tls.json`:
///      {"cert": "/path/fullchain.pem", "key": "/path/privkey.pem"}
/// The cert file may hold the whole chain. The key may be RSA or EC, PKCS#8 or
/// traditional PEM, unencrypted.
enum LANTLS {
    struct Paths: Equatable {
        let cert: String
        let key: String
    }

    static let certKey = "lanTLSCertPath"
    static let keyKey = "lanTLSKeyPath"

    static var configFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clamshell/lan-tls.json")
    }

    /// Pure so `swift test` covers precedence and malformed input.
    static func paths(defaults: UserDefaults = .standard, fileData: Data?) -> Paths? {
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
            return (t as NSString).expandingTildeInPath
        }
        if let c = clean(defaults.string(forKey: certKey)), let k = clean(defaults.string(forKey: keyKey)) {
            return Paths(cert: c, key: k)
        }
        if let data = fileData,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let c = clean(obj["cert"] as? String), let k = clean(obj["key"] as? String) {
            return Paths(cert: c, key: k)
        }
        return nil
    }

    static func configuredPaths() -> Paths? {
        paths(fileData: try? Data(contentsOf: configFileURL))
    }

    /// The loaded identity, or nil when TLS is not configured or could not be
    /// loaded (logged, and the listeners stay plain so the app keeps working).
    private(set) static var identity: SecIdentity?
    private static var loadedFor: Paths?

    /// Call before building listeners. Cheap when nothing is configured.
    static func reload() {
        guard let p = configuredPaths() else {
            identity = nil; loadedFor = nil
            return
        }
        if p == loadedFor, identity != nil { return }
        do {
            identity = try loadIdentity(cert: p.cert, key: p.key)
            loadedFor = p
            clog("LAN TLS: serving the browser listeners over TLS with \(p.cert)")
        } catch {
            identity = nil; loadedFor = nil
            clog("LAN TLS: configured but not usable (\(error)) — staying on plain ws/http")
        }
    }

    /// NWParameters for a browser-facing listener: plain TCP unless TLS is
    /// loaded. Callers add the WebSocket framer on top as before.
    static func parameters() -> NWParameters {
        guard let identity, let secIdentity = sec_identity_create(identity) else { return .tcp }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }

    struct LoadError: Error, CustomStringConvertible {
        let description: String
    }

    /// Network.framework wants a SecIdentity, which needs the certificate and
    /// its key in a keychain. Bundle the two PEM files into a PKCS#12 with the
    /// system openssl (one process, once, at start) and import it into a
    /// private keychain file under Application Support, so nothing lands in
    /// the login keychain. The throwaway passphrase never leaves memory.
    private static func loadIdentity(cert: String, key: String) throws -> SecIdentity {
        let fm = FileManager.default
        guard fm.isReadableFile(atPath: cert) else { throw LoadError(description: "cannot read \(cert)") }
        guard fm.isReadableFile(atPath: key) else { throw LoadError(description: "cannot read \(key)") }

        let pass = UUID().uuidString
        let p12 = fm.temporaryDirectory.appendingPathComponent("clamshell-lan-\(UUID().uuidString).p12")
        defer { try? fm.removeItem(at: p12) }
        let openssl = Process()
        openssl.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        openssl.arguments = ["pkcs12", "-export", "-inkey", key, "-in", cert, "-out", p12.path, "-passout", "env:CLAMSHELL_P12_PASS"]
        openssl.environment = ["CLAMSHELL_P12_PASS": pass]
        let err = Pipe()
        openssl.standardError = err
        try openssl.run()
        openssl.waitUntilExit()
        guard openssl.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw LoadError(description: "openssl could not pair the cert and key: \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let blob = try Data(contentsOf: p12)

        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Clamshell")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let kcPath = dir.appendingPathComponent("lan-tls.keychain").path
        try? fm.removeItem(atPath: kcPath)
        var keychain: SecKeychain?
        let kcPass = UUID().uuidString
        let st = kcPass.withCString { SecKeychainCreate(kcPath, UInt32(strlen($0)), $0, false, nil, &keychain) }
        guard st == errSecSuccess, let keychain else { throw LoadError(description: "keychain create failed (\(st))") }

        var items: CFArray?
        let opts: [String: Any] = [kSecImportExportPassphrase as String: pass,
                                   kSecImportExportKeychain as String: keychain]
        let ist = SecPKCS12Import(blob as CFData, opts as CFDictionary, &items)
        guard ist == errSecSuccess, let arr = items as? [[String: Any]],
              let first = arr.first, let id = first[kSecImportItemIdentity as String] else {
            throw LoadError(description: "PKCS#12 import failed (\(ist))")
        }
        return id as! SecIdentity // swiftlint:disable:this force_cast
    }
}
