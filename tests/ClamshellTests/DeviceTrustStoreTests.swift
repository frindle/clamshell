import XCTest
import CryptoKit
@testable import Clamshell

/// The host's state on disk: the identity key, the device list and the
/// commands that edit it (PROTOCOL.md "Device authentication and encrypted
/// session", host rules). Every test gets its own directory and a clock it
/// moves by hand.
final class DeviceTrustStoreTests: XCTestCase {
    private var dir: URL!
    private var clock = Date(timeIntervalSince1970: 1_794_000_000)

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clamshell-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: helpers

    private var listFile: URL { dir.appendingPathComponent(DeviceTrustStore.fileName) }
    private var keyFile: URL { dir.appendingPathComponent(HostIdentity.fileName) }

    private func store(in directory: URL? = nil, watch: Bool = false) -> DeviceTrustStore {
        DeviceTrustStore(directory: directory ?? dir, watch: watch, now: { [unowned self] in self.clock })
    }

    private func newKey() -> Data { P256.Signing.PrivateKey().publicKey.x963Representation }
    private func id(_ key: Data) -> String { DeviceIdentity.id(ofPublicKey: key) }

    private func ask(_ s: DeviceTrustStore, _ key: Data, name: String = "Pad",
                     open: Bool = false) -> DeviceTrustStore.Answer {
        s.ask(publicKey: key, name: name, address: "192.0.2.7", hasOpenConnection: { _ in open })
    }

    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as! NSNumber).intValue
    }

    private func names(in directory: URL? = nil) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: (directory ?? dir).path).sorted()
    }

    private func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    private func one(_ match: DeviceTrustStore.Match) -> DeviceRecord? {
        if case .one(let record) = match { return record }
        return nil
    }

    // MARK: asking and deciding

    func testNewDeviceWaitsUntilApprovedAndThatIsKept() throws {
        let s = store()
        XCTAssertTrue(s.canPersist)
        let key = newKey()
        XCTAssertNil(s.state(of: id(key)))
        XCTAssertEqual(ask(s, key), .waiting)
        XCTAssertEqual(s.state(of: id(key)), .waiting)
        XCTAssertEqual(s.waiting().map(\.id), [id(key)])
        XCTAssertFalse(s.isTrusted(id(key)))
        XCTAssertEqual(try mode(listFile), 0o600)
        XCTAssertEqual(try mode(dir), 0o700)

        // Asking again lists nothing new.
        XCTAssertEqual(ask(s, key), .waiting)
        XCTAssertEqual(s.all().count, 1)

        let approved = s.decide(id: id(key), .approve, by: DeviceTrustStore.decidedOnHost, onlyIfWaiting: true)
        XCTAssertEqual(approved?.state, .trusted)
        XCTAssertEqual(approved?.decidedBy, "host")
        XCTAssertEqual(approved?.decidedAt, clock.timeIntervalSince1970)
        XCTAssertEqual(ask(s, key), .trusted)
        XCTAssertTrue(s.waiting().isEmpty)

        // A second store on the same directory is what another process sees.
        let other = store()
        let kept = try XCTUnwrap(other.record(id: id(key)))
        XCTAssertEqual(kept.state, .trusted)
        XCTAssertEqual(kept.name, "Pad")
        XCTAssertEqual(kept.address, "192.0.2.7")
        XCTAssertEqual(kept.publicKey, Hex.encode(key))
        XCTAssertEqual(kept.fingerprint, DeviceIdentity.fingerprint(ofPublicKey: key))
        XCTAssertEqual(ask(other, key), .trusted)
        XCTAssertEqual(try names().filter { $0.hasPrefix(SecureFile.tempPrefix) }, [])
    }

    func testSomethingThatIsNotAKeyIsDeniedAndNotListed() throws {
        let s = store()
        let answer = s.ask(publicKey: Data(count: 65), name: "x", address: "", hasOpenConnection: { _ in false })
        XCTAssertEqual(answer, .denied)
        XCTAssertTrue(s.all().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: listFile.path))
    }

    func testNamesAndAddressesAreCleanedBeforeTheyAreKept() throws {
        let s = store()
        let key = newKey()
        _ = s.ask(publicKey: key, name: "Pad\u{202E}\u{07}\n", address: " 10.0.0.1\u{1B}[31m ",
                  hasOpenConnection: { _ in false })
        let record = try XCTUnwrap(s.record(id: id(key)))
        XCTAssertEqual(record.name, "Pad")
        XCTAssertEqual(record.address, "10.0.0.1[31m")
        XCTAssertEqual(record.label, "Pad")
        let unnamed = newKey()
        clock += 1
        _ = s.ask(publicKey: unnamed, name: "\u{200B}", address: "", hasOpenConnection: { _ in false })
        XCTAssertEqual(s.record(id: id(unnamed))?.name, "")
        XCTAssertEqual(s.record(id: id(unnamed))?.label, "Unnamed device")
    }

    func testDeniedDeviceCannotMakeTheHostWrite() throws {
        let s = store()
        let key = newKey()
        _ = ask(s, key)
        XCTAssertEqual(s.decide(id: id(key), .deny, by: "host", onlyIfWaiting: true)?.state, .denied)
        let before = try Data(contentsOf: listFile)
        clock += 3600
        XCTAssertEqual(ask(s, key, name: "Another name"), .denied)
        XCTAssertEqual(try Data(contentsOf: listFile), before)
        XCTAssertEqual(s.record(id: id(key))?.name, "Pad")
    }

    func testWaitingDeviceIsNotedAtMostEveryTenSeconds() throws {
        let s = store()
        let key = newKey()
        _ = ask(s, key, name: "First")
        let before = try Data(contentsOf: listFile)
        clock += 1
        XCTAssertEqual(ask(s, key, name: "Second"), .waiting)
        XCTAssertEqual(try Data(contentsOf: listFile), before)
        clock += 10
        XCTAssertEqual(ask(s, key, name: "Second"), .waiting)
        let record = try XCTUnwrap(s.record(id: id(key)))
        XCTAssertEqual(record.name, "Second")
        XCTAssertEqual(record.lastSeen, clock.timeIntervalSince1970)
        XCTAssertEqual(record.firstSeen, clock.timeIntervalSince1970 - 11)
    }

    func testTrustedDeviceKeepsItsNameAndAddressFresh() throws {
        let s = store()
        let key = newKey()
        _ = ask(s, key, name: "Old")
        s.decide(id: id(key), .approve, by: "host", onlyIfWaiting: true)
        clock += 1
        XCTAssertEqual(ask(s, key, name: "New"), .trusted)
        XCTAssertEqual(s.record(id: id(key))?.name, "New")
        // An empty name does not wipe the one on record.
        clock += 100
        XCTAssertEqual(ask(s, key, name: ""), .trusted)
        XCTAssertEqual(s.record(id: id(key))?.name, "New")
        XCTAssertEqual(s.record(id: id(key))?.lastSeen, clock.timeIntervalSince1970)

        // noteConnected is for a host with approval off: it never adds anyone.
        clock += 100
        s.noteConnected(id: id(key), name: "Newer", address: "198.51.100.2")
        XCTAssertEqual(s.record(id: id(key))?.name, "Newer")
        XCTAssertEqual(s.record(id: id(key))?.address, "198.51.100.2")
        let stranger = newKey()
        s.noteConnected(id: id(stranger), name: "Stranger", address: "")
        XCTAssertNil(s.record(id: id(stranger)))
        XCTAssertEqual(s.all().count, 1)
    }

    func testWaitingListLimits() throws {
        let s = store()
        var keys: [Data] = []
        for _ in 0 ..< 10 {
            let key = newKey()
            keys.append(key)
            XCTAssertEqual(ask(s, key, open: true), .waiting)
            clock += 1
        }
        // An eleventh new device inside the same minute.
        XCTAssertEqual(ask(s, newKey(), open: true), .busy)
        XCTAssertEqual(s.waiting().count, 10)
        // A device already on the list is not a new one.
        XCTAssertEqual(ask(s, keys[3], open: true), .waiting)

        clock += 61
        for _ in 0 ..< 6 {
            let key = newKey()
            keys.append(key)
            XCTAssertEqual(ask(s, key, open: true), .waiting)
            clock += 1
        }
        XCTAssertEqual(s.waiting().count, 16)
        XCTAssertEqual(s.waiting().map(\.id), keys.map(id))

        clock += 61
        // Full, and every waiting device still has a connection open.
        XCTAssertEqual(ask(s, newKey(), open: true), .busy)
        XCTAssertEqual(s.waiting().map(\.id), keys.map(id))

        // Full, but the oldest has gone away: the newcomer takes its place.
        let late = newKey()
        XCTAssertEqual(ask(s, late, open: false), .waiting)
        XCTAssertEqual(s.waiting().map(\.id), (keys.dropFirst() + [late]).map(id))

        // Only a device with no connection is replaced.
        let later = newKey()
        let answer = s.ask(publicKey: later, name: "", address: "",
                           hasOpenConnection: { $0 != self.id(keys[2]) })
        XCTAssertEqual(answer, .waiting)
        XCTAssertNil(s.state(of: id(keys[2])))
        XCTAssertEqual(s.state(of: id(keys[1])), .waiting)
        XCTAssertEqual(s.waiting().count, 16)

        // Trusted and denied devices do not count against the waiting list.
        XCTAssertNotNil(s.decide(id: id(keys[1]), .approve, by: "host", onlyIfWaiting: true))
        XCTAssertEqual(s.waiting().count, 15)
        XCTAssertEqual(ask(s, newKey(), open: true), .waiting)
    }

    func testWaitingDeviceIsDroppedAfterADay() throws {
        let s = store()
        let waiting = newKey(), trusted = newKey(), denied = newKey()
        for key in [waiting, trusted, denied] { _ = ask(s, key) }
        s.decide(id: id(trusted), .approve, by: "host", onlyIfWaiting: true)
        s.decide(id: id(denied), .deny, by: "host", onlyIfWaiting: true)

        clock += DeviceTrustStore.waitingLifetime - 1
        XCTAssertEqual(s.state(of: id(waiting)), .waiting)
        clock += 2
        XCTAssertNil(s.state(of: id(waiting)))
        XCTAssertTrue(s.waiting().isEmpty)
        // Nobody can approve what is no longer listed.
        XCTAssertNil(s.decide(id: id(waiting), .approve, by: "host", onlyIfWaiting: true))
        XCTAssertEqual(s.state(of: id(trusted)), .trusted)
        XCTAssertEqual(s.state(of: id(denied)), .denied)

        // It may ask again, and that starts a new day.
        XCTAssertEqual(ask(s, waiting), .waiting)
        XCTAssertEqual(s.record(id: id(waiting))?.firstSeen, clock.timeIntervalSince1970)
        XCTAssertEqual(store().state(of: id(waiting)), .waiting)
    }

    func testWhatEachDecisionMayChange() throws {
        let s = store()
        let key = newKey()
        let unknown = id(newKey())
        XCTAssertNil(s.decide(id: unknown, .approve, by: "host", onlyIfWaiting: false))
        XCTAssertNil(s.revoke(id: unknown, by: "host"))
        XCTAssertNil(s.forget(id: unknown))

        _ = ask(s, key)
        // Revoke is for trusted devices only.
        XCTAssertNil(s.revoke(id: id(key), by: "host"))
        XCTAssertEqual(s.decide(id: id(key), .deny, by: "host", onlyIfWaiting: true)?.state, .denied)
        // A decision relayed by another device settles waiting devices only.
        let relay = id(newKey())
        XCTAssertNil(s.decide(id: id(key), .approve, by: relay, onlyIfWaiting: true))
        XCTAssertEqual(s.state(of: id(key)), .denied)
        // On the host itself a denied device can be approved after all.
        clock += 5
        let approved = s.decide(id: id(key), .approve, by: DeviceTrustStore.decidedOnCommandLine, onlyIfWaiting: false)
        XCTAssertEqual(approved?.state, .trusted)
        XCTAssertEqual(approved?.decidedBy, "cli")
        XCTAssertEqual(approved?.decidedAt, clock.timeIntervalSince1970)
        // Nothing to do for a device that is already there.
        XCTAssertNil(s.decide(id: id(key), .approve, by: "host", onlyIfWaiting: false))
        XCTAssertNil(s.decide(id: id(key), .deny, by: "host", onlyIfWaiting: false))
        XCTAssertNil(s.decide(id: id(key), .deny, by: relay, onlyIfWaiting: true))
        XCTAssertEqual(s.state(of: id(key)), .trusted)

        let revoked = s.revoke(id: id(key), by: relay)
        XCTAssertEqual(revoked?.state, .denied)
        XCTAssertEqual(revoked?.decidedBy, relay)
        XCTAssertEqual(ask(s, key), .denied)
        XCTAssertNil(s.revoke(id: id(key), by: "host"))

        XCTAssertEqual(s.forget(id: id(key))?.id, id(key))
        XCTAssertNil(s.forget(id: id(key)))
        XCTAssertTrue(s.all().isEmpty)
        XCTAssertTrue(store().all().isEmpty)
        // Forgotten, so it may ask again.
        XCTAssertEqual(ask(s, key), .waiting)
    }

    func testFindingADeviceByFingerprintOrId() throws {
        let s = store()
        let key = newKey()
        _ = ask(s, key)
        let fingerprint = DeviceIdentity.fingerprint(ofPublicKey: key)
        XCTAssertEqual(fingerprint.count, 19)
        for query in [fingerprint, fingerprint.lowercased(), " \(fingerprint) ",
                      fingerprint.replacingOccurrences(of: "-", with: ""),
                      id(key), id(key).uppercased()] {
            XCTAssertEqual(one(s.resolve(query))?.id, id(key), query)
        }
        for query in ["", "abcd", String(id(key).prefix(15)), String(id(key).prefix(17)),
                      String(repeating: "g", count: 16), id(key) + "0", "ＡＢ12-CD34-EF56-7890"] {
            guard case .badQuery = s.resolve(query) else { return XCTFail("accepted \(query)") }
        }
        guard case .none = s.resolve(String(repeating: "0", count: 16)) else { return XCTFail("matched zeros") }
    }

    // MARK: the file

    func testEditedFileKeepsOnlyRecordsWhoseIdIsTheirKeysHash() throws {
        let good = newKey(), other = newKey(), upper = newKey()
        func record(id: String, key: String, name: String = "x", state: String = "trusted") -> [String: Any] {
            ["id": id, "publicKey": key, "name": name, "state": state,
             "firstSeen": 1, "lastSeen": 2, "address": "a\u{07}b", "decidedBy": "nobody in particular"]
        }
        let devices: [[String: Any]] = [
            record(id: id(good), key: Hex.encode(good), name: "Good\u{202E}one"),
            record(id: id(good), key: Hex.encode(good), name: "the same device again"),
            record(id: id(other), key: Hex.encode(good), name: "another device's id on this key"),
            record(id: String(repeating: "a", count: 64), key: String(repeating: "0", count: 130), name: "no key"),
            record(id: id(upper), key: Hex.encode(upper).uppercased(), name: "upper"),
        ]
        try makeDirectory(dir)
        try JSONSerialization.data(withJSONObject: ["version": 1, "devices": devices]).write(to: listFile)

        let s = store()
        XCTAssertEqual(Set(s.all().map(\.id)), [id(good), id(upper)])
        let kept = try XCTUnwrap(s.record(id: id(good)))
        XCTAssertEqual(kept.name, "Goodone")
        XCTAssertEqual(kept.address, "ab")
        XCTAssertNil(kept.decidedBy)
        XCTAssertEqual(s.record(id: id(upper))?.publicKey, Hex.encode(upper))
        XCTAssertNil(s.state(of: id(other)))
        // The file was written with the default mode; reading it tightened that.
        XCTAssertEqual(try mode(listFile), 0o600)
    }

    func testEditedFileCannotHoldMoreWaitingDevicesThanTheListAllows() throws {
        var devices: [[String: Any]] = []
        var ids: [String] = []
        for i in 0 ..< 20 {
            let key = newKey()
            ids.append(id(key))
            devices.append(["id": id(key), "publicKey": Hex.encode(key), "name": "", "state": "waiting",
                            "firstSeen": clock.timeIntervalSince1970 + Double(i),
                            "lastSeen": clock.timeIntervalSince1970 + Double(i), "address": ""])
        }
        try makeDirectory(dir)
        try JSONSerialization.data(withJSONObject: ["version": 1, "devices": devices]).write(to: listFile)
        clock += 100
        XCTAssertEqual(Set(store().waiting().map(\.id)), Set(ids.suffix(16)))
    }

    func testDamagedFileIsSetAsideAndNobodyIsTrusted() throws {
        let key = newKey()
        let first = store()
        _ = ask(first, key)
        first.decide(id: id(key), .approve, by: "host", onlyIfWaiting: true)

        for damage in ["not json", "{\"version\":2,\"devices\":[]}", "{\"version\":1,\"devices\":[{\"id\":7}]}"] {
            try Data(damage.utf8).write(to: listFile)
            let s = store()
            XCTAssertTrue(s.all().isEmpty, damage)
            XCTAssertFalse(FileManager.default.fileExists(atPath: listFile.path), damage)
        }
        XCTAssertEqual(try names().filter { $0.hasPrefix("devices.json.unusable-") }.count, 3)

        // The once-trusted device has to ask again, and the list works again.
        let s = store()
        XCTAssertEqual(ask(s, key), .waiting)
        XCTAssertEqual(store().state(of: id(key)), .waiting)
    }

    func testSymbolicLinkIsNotFollowed() throws {
        // A complete, valid list that trusts a device, somewhere else…
        let elsewhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("clamshell-elsewhere-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let key = newKey()
        let real = store(in: elsewhere)
        _ = ask(real, key)
        real.decide(id: id(key), .approve, by: "host", onlyIfWaiting: true)
        let target = elsewhere.appendingPathComponent(DeviceTrustStore.fileName)
        let targetBytes = try Data(contentsOf: target)

        // …linked into this host's directory.
        try makeDirectory(dir)
        try FileManager.default.createSymbolicLink(at: listFile, withDestinationURL: target)
        let s = store()
        XCTAssertTrue(s.all().isEmpty)
        XCTAssertEqual(ask(s, key), .waiting)
        XCTAssertEqual(try Data(contentsOf: target), targetBytes)
        var st = stat()
        XCTAssertEqual(lstat(listFile.path, &st), 0)
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(real.state(of: id(key)), .trusted)
    }

    func testTwoStoresShareOneFile() throws {
        let a = store(), b = store()
        let key = newKey()
        XCTAssertEqual(ask(a, key), .waiting)
        // b has not looked since, but a decision always starts from the file.
        XCTAssertNotNil(b.decide(id: id(key), .approve, by: "cli", onlyIfWaiting: true))
        // a's list is stale until it reloads; an asking device is answered
        // from the file all the same.
        XCTAssertEqual(a.state(of: id(key)), .waiting)
        XCTAssertEqual(ask(a, key), .trusted)
        XCTAssertEqual(a.state(of: id(key)), .trusted)

        XCTAssertNotNil(b.revoke(id: id(key), by: "cli"))
        XCTAssertEqual(a.state(of: id(key)), .trusted)
        a.reload()
        XCTAssertEqual(a.state(of: id(key)), .denied)
        XCTAssertEqual(ask(a, key), .denied)
    }

    func testChangesAreAnnounced() throws {
        let s = store()
        let key = newKey()
        let listed = expectation(forNotification: DeviceTrustStore.didChange, object: s)
        listed.assertForOverFulfill = false
        _ = ask(s, key)
        wait(for: [listed], timeout: 2)

        let decided = expectation(forNotification: DeviceTrustStore.didChange, object: s)
        decided.assertForOverFulfill = false
        s.decide(id: id(key), .approve, by: "host", onlyIfWaiting: true)
        wait(for: [decided], timeout: 2)

        // Nothing changed, nothing announced.
        let quiet = expectation(forNotification: DeviceTrustStore.didChange, object: s)
        quiet.isInverted = true
        XCTAssertEqual(ask(s, key), .trusted)
        XCTAssertNil(s.decide(id: id(key), .approve, by: "host", onlyIfWaiting: false))
        s.reload()
        wait(for: [quiet], timeout: 0.3)
    }

    func testWatcherNoticesAChangeMadeByAnotherProcess() throws {
        let watching = store(watch: true)
        let other = store()
        let key = newKey()
        let noticed = expectation(forNotification: DeviceTrustStore.didChange, object: watching)
        noticed.assertForOverFulfill = false
        XCTAssertEqual(ask(other, key), .waiting)
        wait(for: [noticed], timeout: 10)
        XCTAssertEqual(watching.state(of: id(key)), .waiting)
    }

    func testListLastsForOneRunWhenTheDirectoryCannotBeUsed() throws {
        // A file where the directory should be.
        try Data().write(to: dir)
        let s = store()
        XCTAssertFalse(s.canPersist)
        let key = newKey()
        XCTAssertEqual(ask(s, key), .waiting)
        XCTAssertNotNil(s.decide(id: id(key), .approve, by: "host", onlyIfWaiting: true))
        XCTAssertEqual(ask(s, key), .trusted)
        XCTAssertNotNil(s.revoke(id: id(key), by: "host"))
        XCTAssertEqual(ask(s, key), .denied)

        let identity = HostIdentity.load(in: dir)
        XCTAssertFalse(identity.isPersistent)
        XCTAssertNotEqual(identity.publicKey, HostIdentity.load(in: dir).publicKey)
    }

    // MARK: files

    func testSecureFile() throws {
        try HostState.prepare(dir)
        XCTAssertEqual(try mode(dir), 0o700)
        let file = dir.appendingPathComponent("x")
        XCTAssertThrowsError(try SecureFile.read(file, maxBytes: 8)) { XCTAssertEqual($0 as? SecureFileError, .notFound) }
        try SecureFile.createExclusive(file, contents: Data([1]))
        XCTAssertEqual(try mode(file), 0o600)
        XCTAssertThrowsError(try SecureFile.createExclusive(file, contents: Data([2]))) {
            XCTAssertEqual($0 as? SecureFileError, .exists)
        }
        XCTAssertEqual(try SecureFile.read(file, maxBytes: 8), Data([1]))
        try SecureFile.replace(file, contents: Data([3, 4]))
        XCTAssertEqual(try SecureFile.read(file, maxBytes: 2), Data([3, 4]))
        XCTAssertThrowsError(try SecureFile.read(file, maxBytes: 1)) {
            XCTAssertEqual($0 as? SecureFileError, .unsafe("is larger than expected"))
        }
        XCTAssertThrowsError(try SecureFile.read(dir, maxBytes: 8)) {
            XCTAssertEqual($0 as? SecureFileError, .unsafe("is not a regular file"))
        }
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try SecureFile.read(link, maxBytes: 8)) {
            XCTAssertEqual($0 as? SecureFileError, .unsafe("is a symbolic link"))
        }
        // Nothing temporary is left behind.
        XCTAssertEqual(try names(), ["link", "x"])
    }

    func testDirectoryOpenToOthersIsTightened() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        try HostState.prepare(dir)
        XCTAssertEqual(try mode(dir), 0o700)
    }

    // MARK: the host's own key

    func testHostIdentityIsCreatedOnceAndKept() throws {
        let a = HostIdentity.load(in: dir)
        XCTAssertTrue(a.isPersistent)
        let b = HostIdentity.load(in: dir)
        XCTAssertEqual(a.publicKey, b.publicKey)
        XCTAssertTrue(DeviceIdentity.isValidPublicKey(a.publicKey))
        XCTAssertEqual(a.id, DeviceIdentity.id(ofPublicKey: a.publicKey))
        XCTAssertEqual(a.fingerprint, DeviceIdentity.fingerprint(ofPublicKey: a.publicKey))
        XCTAssertEqual(try mode(keyFile), 0o600)
        XCTAssertEqual(try Data(contentsOf: keyFile).count, 32)
        // It signs as the key it shows.
        let message = Data("message".utf8)
        XCTAssertTrue(AuthSignature.verify(try a.sign(message), over: message, publicKey: b.publicKey))
    }

    func testHostIdentityReplacesAFileThatIsNotAKey() throws {
        let a = HostIdentity.load(in: dir)
        try Data(count: 5).write(to: keyFile)
        let b = HostIdentity.load(in: dir)
        XCTAssertTrue(b.isPersistent)
        XCTAssertNotEqual(a.publicKey, b.publicKey)
        XCTAssertEqual(HostIdentity.load(in: dir).publicKey, b.publicKey)
        XCTAssertEqual(try names().filter { $0.hasPrefix("host-identity.key.unusable-") }.count, 1)
    }

    func testHostIdentityDoesNotFollowALink() throws {
        let elsewhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("clamshell-elsewhere-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let foreign = HostIdentity.load(in: elsewhere)
        try makeDirectory(dir)
        try FileManager.default.createSymbolicLink(at: keyFile,
                                                   withDestinationURL: elsewhere.appendingPathComponent(HostIdentity.fileName))
        let mine = HostIdentity.load(in: dir)
        XCTAssertTrue(mine.isPersistent)
        XCTAssertNotEqual(mine.publicKey, foreign.publicKey)
        XCTAssertEqual(HostIdentity.load(in: dir).publicKey, mine.publicKey)
        XCTAssertEqual(HostIdentity.load(in: elsewhere).publicKey, foreign.publicKey)
    }

    // MARK: limits shared by every listener

    func testWaitingConnectionLimit() {
        let auth = HostAuth(directory: dir, requireApproval: true, watch: false)
        for i in 0 ..< HostAuth.maxWaitingConnections { XCTAssertTrue(auth.admitWaiting(deviceId: "d\(i % 3)")) }
        XCTAssertFalse(auth.admitWaiting(deviceId: "new"))
        XCTAssertFalse(auth.admitWaiting(deviceId: "d0"))
        XCTAssertFalse(auth.hasWaitingConnection(deviceId: "new"))
        XCTAssertTrue(auth.hasWaitingConnection(deviceId: "d0"))
        // d0 holds three of the eight.
        auth.releaseWaiting(deviceId: "d0")
        auth.releaseWaiting(deviceId: "d0")
        XCTAssertTrue(auth.hasWaitingConnection(deviceId: "d0"))
        auth.releaseWaiting(deviceId: "d0")
        XCTAssertFalse(auth.hasWaitingConnection(deviceId: "d0"))
        auth.releaseWaiting(deviceId: "d0")
        XCTAssertTrue(auth.admitWaiting(deviceId: "new"))
        XCTAssertTrue(auth.hasWaitingConnection(deviceId: "new"))
    }

    func testOldestUnansweredConnectionMakesRoom() {
        let auth = HostAuth(directory: dir, requireApproval: true, watch: false)
        var closed: [Int] = []
        var tokens: [HostAuth.Unanswered] = []
        for i in 0 ..< HostAuth.maxUnansweredConnections {
            tokens.append(auth.addUnanswered { closed.append(i) })
        }
        XCTAssertEqual(closed, [])
        // One that answered is no longer counted.
        auth.removeUnanswered(tokens[0])
        _ = auth.addUnanswered { closed.append(100) }
        XCTAssertEqual(closed, [])
        _ = auth.addUnanswered { closed.append(101) }
        XCTAssertEqual(closed, [1])
        _ = auth.addUnanswered { closed.append(102) }
        XCTAssertEqual(closed, [1, 2])
    }

    func testApprovalCanBeSwitchedAndIsAnnounced() {
        let auth = HostAuth(directory: dir, requireApproval: true, watch: false)
        XCTAssertTrue(auth.requireApproval)
        let off = expectation(forNotification: HostAuth.approvalDidChange, object: auth)
        off.assertForOverFulfill = false
        auth.overrideRequireApproval(false)
        wait(for: [off], timeout: 2)
        XCTAssertFalse(auth.requireApproval)

        let unchanged = expectation(forNotification: HostAuth.approvalDidChange, object: auth)
        unchanged.isInverted = true
        auth.overrideRequireApproval(false)
        wait(for: [unchanged], timeout: 0.3)
        XCTAssertFalse(auth.hostName.isEmpty)
    }

    // MARK: commands

    func testDeviceCommands() throws {
        let auth = HostAuth(directory: dir, requireApproval: true, watch: false)
        var lines: [String] = []
        func run(_ args: String...) -> Int32 {
            lines = []
            return DeviceCommands.run(args, auth: auth) { lines.append($0) }
        }

        XCTAssertEqual(run("devices"), 0)
        XCTAssertTrue(lines[0].contains(auth.identity.fingerprint), lines[0])
        XCTAssertEqual(lines[1], "Device approval is on.")
        XCTAssertTrue(lines.contains("No devices yet."))

        let key = newKey()
        let fingerprint = DeviceIdentity.fingerprint(ofPublicKey: key)
        _ = auth.store.ask(publicKey: key, name: "Pad", address: "192.0.2.7", hasOpenConnection: { _ in false })
        XCTAssertEqual(run("devices"), 0)
        XCTAssertTrue(lines.contains("Waiting for approval:"))
        XCTAssertTrue(lines.contains { $0.contains(fingerprint) && $0.contains("Pad") && $0.contains("192.0.2.7") })

        XCTAssertEqual(run("approve"), 64)
        XCTAssertEqual(run("approve", fingerprint, "extra"), 64)
        XCTAssertEqual(run("devices", "extra"), 64)
        XCTAssertEqual(run("approve", "not a fingerprint"), 64)
        XCTAssertEqual(run("launch"), 64)
        XCTAssertEqual(run("approve", "0000-0000-0000-0000"), 1)
        XCTAssertEqual(auth.store.state(of: id(key)), .waiting)

        XCTAssertEqual(run("approve", fingerprint), 0)
        XCTAssertEqual(auth.store.state(of: id(key)), .trusted)
        XCTAssertEqual(auth.store.record(id: id(key))?.decidedBy, "cli")
        XCTAssertEqual(run("approve", fingerprint), 0)
        XCTAssertEqual(run("deny", fingerprint), 1)
        XCTAssertEqual(auth.store.state(of: id(key)), .trusted)
        XCTAssertEqual(run("devices"), 0)
        XCTAssertTrue(lines.contains("Trusted:"))
        XCTAssertTrue(lines.contains { $0.contains(fingerprint) && $0.contains("approved from the command line") })

        XCTAssertEqual(run("revoke", id(key)), 0)
        XCTAssertEqual(auth.store.state(of: id(key)), .denied)
        XCTAssertEqual(run("revoke", fingerprint), 0)
        XCTAssertEqual(run("deny", fingerprint), 0)
        XCTAssertEqual(run("forget", fingerprint.lowercased()), 0)
        XCTAssertNil(auth.store.state(of: id(key)))
        XCTAssertEqual(run("forget", fingerprint), 1)

        // Deny is for a device that is still waiting.
        _ = auth.store.ask(publicKey: key, name: "Pad", address: "", hasOpenConnection: { _ in false })
        XCTAssertEqual(run("deny", fingerprint), 0)
        XCTAssertEqual(auth.store.state(of: id(key)), .denied)
        XCTAssertEqual(auth.store.record(id: id(key))?.decidedBy, "cli")
    }

    func testAgo() {
        XCTAssertEqual(DeviceCommands.ago(100, now: 130), "just now")
        XCTAssertEqual(DeviceCommands.ago(100, now: 250), "2 min ago")
        XCTAssertEqual(DeviceCommands.ago(100, now: 7300), "2 h ago")
        XCTAssertEqual(DeviceCommands.ago(100, now: 200_000), "2 d ago")
        XCTAssertEqual(DeviceCommands.ago(100, now: 50), "just now")
    }

    func testHex() {
        XCTAssertEqual(Hex.encode(Data([0x00, 0x0f, 0xa5, 0xff])), "000fa5ff")
        XCTAssertEqual(Hex.decode("000FA5ff"), Data([0x00, 0x0f, 0xa5, 0xff]))
        XCTAssertEqual(Hex.decode(""), Data())
        XCTAssertNil(Hex.decode("abc"))
        XCTAssertNil(Hex.decode("zz"))
        XCTAssertNil(Hex.decode("0x"))
        XCTAssertNil(Hex.decode("１２"))
        XCTAssertTrue(DeviceIdentity.isWellFormedId(String(repeating: "0a", count: 32)))
        XCTAssertFalse(DeviceIdentity.isWellFormedId(String(repeating: "0A", count: 32)))
        XCTAssertFalse(DeviceIdentity.isWellFormedId(String(repeating: "0a", count: 31)))
    }
}
