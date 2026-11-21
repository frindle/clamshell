import XCTest
import CryptoKit
@testable import Clamshell

/// The update hand-off and the fail-fast Keychain answer. No real keychain.
final class TrustBridgeTests: XCTestCase {
    private var dir: URL!
    private let key = Data((0 ..< 32).map { UInt8($0) })
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("clamshell-bridge-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testHandOffIsOwnerOnlyAndTakenOnce() throws {
        try TrustBridge.offer(key: key, forCdhash: "abc", directory: dir, now: now)
        var st = stat()
        XCTAssertEqual(stat(TrustBridge.url(in: dir).path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        XCTAssertEqual(TrustBridge.take(directory: dir, ownCdhash: "abc", now: now.addingTimeInterval(5)), .key(key))
        XCTAssertEqual(TrustBridge.take(directory: dir, ownCdhash: "abc", now: now.addingTimeInterval(6)), .none, "used once")
        XCTAssertFalse(FileManager.default.fileExists(atPath: TrustBridge.url(in: dir).path))
    }

    func testWrongBuildIsRefusedAndTheFileRemoved() throws {
        try TrustBridge.offer(key: key, forCdhash: "abc", directory: dir, now: now)
        guard case .rejected = TrustBridge.take(directory: dir, ownCdhash: "other", now: now) else { return XCTFail() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: TrustBridge.url(in: dir).path))
    }

    func testExpiredIsRefused() throws {
        try TrustBridge.offer(key: key, forCdhash: "abc", directory: dir, now: now)
        guard case .rejected = TrustBridge.take(directory: dir, ownCdhash: "abc",
                                                now: now.addingTimeInterval(TrustBridge.lifetime + 1)) else { return XCTFail() }
    }

    func testGarbageAndShortKeysAreRefused() throws {
        try Data("not json".utf8).write(to: TrustBridge.url(in: dir))
        guard case .rejected = TrustBridge.take(directory: dir, ownCdhash: "abc", now: now) else { return XCTFail() }
        XCTAssertThrowsError(try TrustBridge.offer(key: Data([1, 2]), forCdhash: "abc", directory: dir, now: now))
    }

    func testSymbolicLinkIsNotFollowed() throws {
        let target = dir.appendingPathComponent("elsewhere")
        try TrustBridge.offer(key: key, forCdhash: "abc", directory: dir, now: now)
        try FileManager.default.moveItem(at: TrustBridge.url(in: dir), to: target)
        try FileManager.default.createSymbolicLink(at: TrustBridge.url(in: dir), withDestinationURL: target)
        guard case .rejected = TrustBridge.take(directory: dir, ownCdhash: "abc", now: now) else { return XCTFail() }
    }

    // MARK: resolver order

    func testResolverPrefersOwnItemThenHandOffThenOldItem() throws {
        var stored: [Data] = []
        var bridgeCalls = 0
        func resolver(build: Data?, bridge: Data?, legacy: Data?) -> IntegrityKeyResolver {
            IntegrityKeyResolver(readBuild: { build }, takeBridge: { bridgeCalls += 1; return bridge },
                                 readLegacy: { legacy }, storeBuild: { stored.append($0) })
        }
        let a = Data(repeating: 1, count: 32), b = Data(repeating: 2, count: 32), c = Data(repeating: 3, count: 32)
        XCTAssertEqual(try resolver(build: a, bridge: b, legacy: c).resolve(), a)
        XCTAssertEqual(bridgeCalls, 0, "the hand-off is not even looked at when this build has its key")
        XCTAssertEqual(try resolver(build: nil, bridge: b, legacy: c).resolve(), b)
        XCTAssertEqual(try resolver(build: nil, bridge: nil, legacy: c).resolve(), c)
        XCTAssertEqual(stored, [b, c], "what was found is kept under this build's own item")
        stored = []
        XCTAssertNil(try resolver(build: nil, bridge: nil, legacy: nil).resolve())
        XCTAssertTrue(stored.isEmpty)
    }

    func testUnreadableOldItemStaysAnError() {
        struct Denied: Error {}
        let r = IntegrityKeyResolver(readBuild: { nil }, takeBridge: { nil },
                                     readLegacy: { throw Denied() }, storeBuild: { _ in })
        XCTAssertThrowsError(try r.resolve())
    }

    // MARK: fail-fast

    private final class Keys: IntegrityKeyStore {
        var reads = 0
        var fail = true
        func readKey(allowPrompt: Bool) throws -> Data? {
            reads += 1
            if fail { throw KeychainStatusError(status: -25308) }
            return Data(repeating: 9, count: 32)
        }
        func deleteKey() throws {}
        func addKey(_ key: Data) throws -> Bool { true }
    }

    func testUnavailableAnswersAtOnceUntilTheRetryInterval() {
        let keys = Keys()
        var clock = now
        let integrity = TrustIntegrity(keys: keys, now: { clock })
        XCTAssertTrue(integrity.isUnavailable)
        XCTAssertEqual(keys.reads, 1)
        for _ in 0 ..< 5 { XCTAssertTrue(integrity.isUnavailable) }
        XCTAssertEqual(keys.reads, 1, "no new read, so a new connection is not held up")
        keys.fail = false
        clock = now.addingTimeInterval(TrustIntegrity.unavailableRetryInterval + 1)
        XCTAssertFalse(integrity.isUnavailable, "approved meanwhile: the next look finds the key")
        XCTAssertEqual(keys.reads, 2)
    }

    func testBusyReasonOneIsTheKeychainReason() {
        XCTAssertEqual(HostBusyReason.keychain.rawValue, 1)
    }
}
