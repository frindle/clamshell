import XCTest
import CryptoKit
@testable import Clamshell

/// The MAC over the device list and the approval setting. The keychain is an
/// in-memory fake: nothing here touches the real one.
final class TrustIntegrityTests: XCTestCase {
    private final class FakeKeys: IntegrityKeyStore {
        var key: Data?
        var failReads = false
        func readKey() throws -> Data? {
            if failReads { throw KeychainStatusError(status: -25308) }
            return key
        }
        func addKey(_ key: Data) throws -> Bool {
            if self.key != nil { return false }
            self.key = key
            return true
        }
    }

    private final class Prefs {
        var value: Any?
        var mac: Any?
    }

    private var dir: URL!
    private var keys: FakeKeys!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clamshell-integrity-\(UUID().uuidString)", isDirectory: true)
        keys = FakeKeys()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: helpers

    private var listFile: URL { dir.appendingPathComponent(DeviceTrustStore.fileName) }

    /// A new process: a fresh TrustIntegrity over the same keychain.
    private func store() -> DeviceTrustStore {
        DeviceTrustStore(directory: dir, watch: false, integrity: TrustIntegrity(keys: keys))
    }

    private func newKey() -> Data { P256.Signing.PrivateKey().publicKey.x963Representation }

    private func approve(_ s: DeviceTrustStore, _ key: Data) {
        _ = s.ask(publicKey: key, name: "Pad", address: "192.0.2.7", hasOpenConnection: { _ in false })
        s.decide(id: DeviceIdentity.id(ofPublicKey: key), .approve, by: DeviceTrustStore.decidedOnHost,
                 onlyIfWaiting: false)
    }

    private func auth(_ prefs: Prefs, integrity: TrustIntegrity) -> HostAuth {
        HostAuth(directory: dir, watch: false, readStored: { prefs.value }, integrity: integrity,
                 readStoredMAC: { prefs.mac }, saveStored: { prefs.value = $0; prefs.mac = $1 })
    }

    private func editFile(_ change: (inout [String: Any]) -> Void) throws {
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: listFile)) as! [String: Any]
        change(&json)
        try JSONSerialization.data(withJSONObject: json).write(to: listFile)
    }

    // MARK: device list

    func testListWithAValidMACLoads() {
        let k = newKey()
        approve(store(), k)
        let again = store()
        XCTAssertTrue(again.isTrusted(DeviceIdentity.id(ofPublicKey: k)))
        let text = try? String(contentsOf: listFile)
        XCTAssertTrue(text?.contains("\"mac\"") == true)
    }

    func testEditedListIsNotTrustedAndEveryoneIsUnapproved() throws {
        let k = newKey()
        approve(store(), k)
        // Another program adds a device of its own to the list.
        let intruder = newKey()
        try editFile { json in
            var devices = json["devices"] as! [[String: Any]]
            var copy = devices[0]
            copy["id"] = DeviceIdentity.id(ofPublicKey: intruder)
            copy["publicKey"] = Hex.encode(intruder)
            devices.append(copy)
            json["devices"] = devices
        }
        let s = store()
        XCTAssertTrue(s.all().isEmpty)
        XCTAssertFalse(s.isTrusted(DeviceIdentity.id(ofPublicKey: k)))
        XCTAssertFalse(s.isTrusted(DeviceIdentity.id(ofPublicKey: intruder)))
    }

    func testChangingOneFieldWithoutTheKeyIsCaught() throws {
        let k = newKey()
        approve(store(), k)
        try editFile { json in
            var devices = json["devices"] as! [[String: Any]]
            devices[0]["state"] = "trusted"
            devices[0]["name"] = "Someone else"
            json["devices"] = devices
        }
        XCTAssertTrue(store().all().isEmpty)
    }

    func testListWithTheMACRemovedIsNotTrustedOnceAKeyExists() throws {
        let k = newKey()
        approve(store(), k)
        try editFile { $0["mac"] = nil }
        XCTAssertTrue(store().all().isEmpty)
        XCTAssertNotNil(keys.key)
    }

    func testApprovingAgainAfterAFailedCheckWritesAFreshSignedListAndKeepsTheOldOne() throws {
        let k = newKey()
        approve(store(), k)
        try editFile { $0["mac"] = "00" }
        let s = store()
        XCTAssertTrue(s.all().isEmpty)
        let k2 = newKey()
        approve(s, k2)
        let again = store()
        XCTAssertEqual(again.all().map(\.id), [DeviceIdentity.id(ofPublicKey: k2)])
        XCTAssertTrue(again.isTrusted(DeviceIdentity.id(ofPublicKey: k2)))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(names.contains { $0.hasPrefix(DeviceTrustStore.fileName) && $0 != DeviceTrustStore.fileName },
                      "\(names)")
    }

    func testMigrationSignsAnExistingUnsignedListOnce() throws {
        // A list written by a build before MACs.
        let k = newKey()
        let plain = DeviceTrustStore(directory: dir, watch: false)
        approve(plain, k)
        XCTAssertFalse((try String(contentsOf: listFile)).contains("\"mac\""))
        XCTAssertNil(keys.key)

        let migrated = store()
        XCTAssertTrue(migrated.isTrusted(DeviceIdentity.id(ofPublicKey: k)))
        XCTAssertNotNil(keys.key, "the key is made on the first run")
        XCTAssertTrue((try String(contentsOf: listFile)).contains("\"mac\""))
        // A later run keeps trusting it, and an edit is now caught.
        XCTAssertTrue(store().isTrusted(DeviceIdentity.id(ofPublicKey: k)))
        try editFile { json in
            var devices = json["devices"] as! [[String: Any]]
            devices[0]["name"] = "Edited"
            json["devices"] = devices
        }
        XCTAssertTrue(store().all().isEmpty)
    }

    func testMissingKeychainItemAfterAListExistsIsNotSilentlyRekeyed() throws {
        let k = newKey()
        approve(store(), k)
        keys.key = nil
        let s = store()
        XCTAssertTrue(s.all().isEmpty)
        XCTAssertNil(keys.key, "reading must not make a new key")
        XCTAssertNil(try keys.readKey())
        // And a fresh process still does not trust it.
        XCTAssertTrue(store().all().isEmpty)
        XCTAssertNil(keys.key)
    }

    func testUnreadableKeychainTrustsNothingAndDoesNotCrash() {
        let k = newKey()
        approve(store(), k)
        keys.failReads = true
        let s = store()
        XCTAssertTrue(s.all().isEmpty)
        // A change cannot be signed, so it is not made.
        let k2 = newKey()
        XCTAssertEqual(s.ask(publicKey: k2, name: "Pad", address: "192.0.2.7", hasOpenConnection: { _ in false }),
                       .busy)
    }

    func testFreshHostWithNoListMakesNoKeyUntilSomethingIsSaved() {
        let s = store()
        XCTAssertTrue(s.all().isEmpty)
        XCTAssertNil(keys.key)
        approve(s, newKey())
        XCTAssertNotNil(keys.key)
    }

    // MARK: approval setting

    func testFlippedApprovalSettingWithoutAValidMACReadsOn() {
        let integrity = TrustIntegrity(keys: keys)
        let prefs = Prefs()
        let a = auth(prefs, integrity: integrity)
        XCTAssertTrue(a.requireApproval)
        // Another program writes the value alone.
        prefs.value = false
        XCTAssertTrue(a.requireApproval)
        // Or with a MAC it made up.
        prefs.mac = String(repeating: "ab", count: 32)
        XCTAssertTrue(a.requireApproval)
        // Or a real MAC for the other value.
        prefs.mac = "00"
        XCTAssertTrue(a.requireApproval)
    }

    func testTurningApprovalOffThroughTheHostSticksAndOnIsPlain() {
        let integrity = TrustIntegrity(keys: keys)
        let prefs = Prefs()
        let a = auth(prefs, integrity: integrity)
        XCTAssertTrue(a.setRequireApproval(false))
        XCTAssertFalse(a.requireApproval)
        // A new process with the same keychain agrees.
        XCTAssertFalse(auth(prefs, integrity: TrustIntegrity(keys: keys)).requireApproval)
        // Copying the MAC onto a value that was edited is not an issue, but a
        // different key is: a stolen preferences file is useless elsewhere.
        XCTAssertTrue(auth(prefs, integrity: TrustIntegrity(keys: { let f = FakeKeys(); f.key = Data(repeating: 7, count: 32); return f }())).requireApproval)
        a.setRequireApproval(true)
        XCTAssertTrue(a.requireApproval)
        XCTAssertTrue(auth(prefs, integrity: TrustIntegrity(keys: keys)).requireApproval)
    }

    func testMigrationSignsAnApprovalSettingThatWasAlreadyOff() {
        let prefs = Prefs()
        prefs.value = false
        let a = auth(prefs, integrity: TrustIntegrity(keys: keys))
        XCTAssertFalse(a.requireApproval)
        XCTAssertNotNil(prefs.mac)
        // Once a key exists, an unsigned "off" is not adopted.
        let prefs2 = Prefs()
        prefs2.value = false
        XCTAssertTrue(auth(prefs2, integrity: TrustIntegrity(keys: keys)).requireApproval)
        XCTAssertNil(prefs2.mac)
    }

    func testApprovalSettingStaysOnWhenTheKeyIsMissingAfterBeingSigned() {
        let prefs = Prefs()
        let a = auth(prefs, integrity: TrustIntegrity(keys: keys))
        a.setRequireApproval(false)
        keys.key = nil
        XCTAssertTrue(auth(prefs, integrity: TrustIntegrity(keys: keys)).requireApproval)
        XCTAssertNil(keys.key)
    }

    func testApprovalCannotBeTurnedOffWhenTheKeychainIsUnreadable() {
        keys.failReads = true
        let prefs = Prefs()
        let a = auth(prefs, integrity: TrustIntegrity(keys: keys))
        XCTAssertFalse(a.setRequireApproval(false))
        XCTAssertTrue(a.requireApproval)
        XCTAssertNil(prefs.value)
    }
}
