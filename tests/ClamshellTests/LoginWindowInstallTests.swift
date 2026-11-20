import XCTest
import CryptoKit
@testable import Clamshell

final class LoginWindowInstallTests: XCTestCase {
    private var base: URL!
    private var user: URL!
    private var mirror: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("lw-install-\(UUID().uuidString)")
        user = base.appendingPathComponent("user")
        mirror = base.appendingPathComponent("mirror")
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    private func put(_ name: String, _ bytes: Data) throws {
        try SecureFile.replace(user.appendingPathComponent(name), contents: bytes)
    }

    private func mirrored(_ name: String) -> Data? {
        try? Data(contentsOf: mirror.appendingPathComponent(name))
    }

    private func mode(_ url: URL) -> mode_t {
        var st = stat()
        lstat(url.path, &st)
        return st.st_mode & 0o777
    }

    // MARK: state sync

    func testSyncCopiesKeyAndDeviceListOwnerOnly() throws {
        let key = P256.Signing.PrivateKey().rawRepresentation
        try put(HostIdentity.fileName, key)
        try put(DeviceTrustStore.fileName, Data("{\"version\":1,\"devices\":[]}".utf8))
        let outcome = try LoginWindowInstall.sync(userDirectory: user, userUID: getuid(), mirror: mirror)
        XCTAssertEqual(outcome, .updated([HostIdentity.fileName, DeviceTrustStore.fileName]))
        XCTAssertEqual(mirrored(HostIdentity.fileName), key)
        XCTAssertEqual(mode(mirror), 0o700)
        XCTAssertEqual(mode(mirror.appendingPathComponent(HostIdentity.fileName)), 0o600)
        XCTAssertEqual(mode(mirror.appendingPathComponent(DeviceTrustStore.fileName)), 0o600)
    }

    func testSyncIsQuietWhenNothingChanged() throws {
        try put(HostIdentity.fileName, P256.Signing.PrivateKey().rawRepresentation)
        _ = try LoginWindowInstall.sync(userDirectory: user, userUID: getuid(), mirror: mirror)
        XCTAssertEqual(try LoginWindowInstall.sync(userDirectory: user, userUID: getuid(), mirror: mirror), .unchanged)
    }

    func testSyncFollowsARevokedDeviceListAndItsRemoval() throws {
        try put(HostIdentity.fileName, P256.Signing.PrivateKey().rawRepresentation)
        try put(DeviceTrustStore.fileName, Data("one".utf8))
        _ = try LoginWindowInstall.sync(userDirectory: user, userUID: getuid(), mirror: mirror)
        try put(DeviceTrustStore.fileName, Data("two".utf8))
        XCTAssertEqual(try LoginWindowInstall.sync(userDirectory: user, userUID: getuid(), mirror: mirror),
                       .updated([DeviceTrustStore.fileName]))
        XCTAssertEqual(mirrored(DeviceTrustStore.fileName), Data("two".utf8))
        try FileManager.default.removeItem(at: user.appendingPathComponent(DeviceTrustStore.fileName))
        _ = try LoginWindowInstall.sync(userDirectory: user, userUID: getuid(), mirror: mirror)
        XCTAssertNil(mirrored(DeviceTrustStore.fileName)) // nobody trusted any more
    }

    func testSyncNeverInventsOrAcceptsABadHostKey() throws {
        XCTAssertThrowsError(try LoginWindowInstall.sync(userDirectory: user, userUID: getuid(), mirror: mirror))
        try put(HostIdentity.fileName, Data("not a key".utf8))
        XCTAssertThrowsError(try LoginWindowInstall.sync(userDirectory: user, userUID: getuid(), mirror: mirror))
        XCTAssertNil(mirrored(HostIdentity.fileName))
    }

    func testSyncRefusesSymlinksAndOtherOwners() throws {
        let secret = base.appendingPathComponent("secret")
        try Data(P256.Signing.PrivateKey().rawRepresentation).write(to: secret)
        try FileManager.default.createSymbolicLink(at: user.appendingPathComponent(HostIdentity.fileName),
                                                   withDestinationURL: secret)
        XCTAssertThrowsError(try LoginWindowInstall.sync(userDirectory: user, userUID: getuid(), mirror: mirror))
        try FileManager.default.removeItem(at: user.appendingPathComponent(HostIdentity.fileName))
        try put(HostIdentity.fileName, P256.Signing.PrivateKey().rawRepresentation)
        // The file is ours; ask for it as if another user owned it.
        XCTAssertThrowsError(try LoginWindowInstall.sync(userDirectory: user, userUID: getuid() &+ 1, mirror: mirror))
    }

    func testSyncIgnoresOversizeDeviceList() throws {
        try put(HostIdentity.fileName, P256.Signing.PrivateKey().rawRepresentation)
        try put(DeviceTrustStore.fileName, Data(count: DeviceTrustStore.maxFileBytes + 1))
        XCTAssertThrowsError(try LoginWindowInstall.sync(userDirectory: user, userUID: getuid(), mirror: mirror))
    }

    // MARK: the agent reads what sync wrote

    /// Port handoff precondition: the agent builds its HostAuth on the mirror
    /// and so presents the user's host identity and trusts the user's devices.
    func testAgentAuthUsesTheUsersIdentityAndDevices() throws {
        let key = P256.Signing.PrivateKey()
        try put(HostIdentity.fileName, key.rawRepresentation)
        let device = P256.Signing.PrivateKey().publicKey.x963Representation
        let userAuth = HostAuth(directory: user, requireApproval: true, watch: false)
        _ = userAuth.store.ask(publicKey: device, name: "Example iPad", address: "192.0.2.10", hasOpenConnection: { _ in false })
        let id = DeviceIdentity.id(ofPublicKey: device)
        _ = userAuth.store.decide(id: id, .approve, by: "test", onlyIfWaiting: true)
        XCTAssertTrue(userAuth.store.isTrusted(id))

        _ = try LoginWindowInstall.sync(userDirectory: user, userUID: getuid(), mirror: mirror)
        let agentAuth = HostAuth(directory: mirror, requireApproval: true, watch: false)
        XCTAssertEqual(agentAuth.identity.publicKey, userAuth.identity.publicKey)
        XCTAssertTrue(agentAuth.identity.isPersistent)
        XCTAssertTrue(agentAuth.store.isTrusted(id))
        XCTAssertTrue(agentAuth.requireApproval)
    }

    // MARK: plists and status

    func testRenderFillsAndEscapesPlaceholders() throws {
        let out = try LoginWindowInstall.render(template: "<s>__A__</s><s>__B__</s>", values: ["A": "x & y", "B": "<z>"])
        XCTAssertEqual(out, "<s>x &amp; y</s><s>&lt;z&gt;</s>")
        XCTAssertThrowsError(try LoginWindowInstall.render(template: "__A____MISSING__", values: ["A": "1"]))
    }

    func testShippedTemplatesRenderWithTheInstallValues() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let layout = LoginWindowInstall.Layout()
        let config = LoginWindowInstall.Config(user: "example", uid: 501, userStateDirectory: "/Users/example/Library/Application Support/Clamshell")
        let agent = try String(contentsOf: root.appendingPathComponent("scripts/loginwindow-agent/\(LoginWindowInstall.agentLabel).plist"), encoding: .utf8)
        let sync = try String(contentsOf: root.appendingPathComponent("scripts/loginwindow-agent/\(LoginWindowInstall.syncLabel).plist"), encoding: .utf8)
        let a = try LoginWindowInstall.render(template: agent, values: LoginWindowInstall.agentValues(layout))
        let s = try LoginWindowInstall.render(template: sync, values: LoginWindowInstall.syncValues(layout, config))
        let ap = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(a.utf8), format: nil) as? [String: Any])
        let sp = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(s.utf8), format: nil) as? [String: Any])
        // The agent runs the root-owned copy, in the login window only, on its own state folder.
        XCTAssertEqual((ap["ProgramArguments"] as? [String])?.first, layout.binary.path)
        XCTAssertEqual(ap["LimitLoadToSessionType"] as? String, "LoginWindow")
        XCTAssertEqual((ap["EnvironmentVariables"] as? [String: String])?["CLAMSHELL_STATE_DIR"], layout.stateDirectory.path)
        XCTAssertTrue(layout.binary.path.hasPrefix("/Library/"))
        XCTAssertEqual(sp["WatchPaths"] as? [String], [config.userStateDirectory])
        XCTAssertEqual((sp["ProgramArguments"] as? [String])?.suffix(2), ["loginwindow", "sync"])
    }

    func testStatusReportsAnEmptyInstall() {
        var layout = LoginWindowInstall.Layout(root: base.appendingPathComponent("none"),
                                               agentPlist: base.appendingPathComponent("a.plist"),
                                               syncPlist: base.appendingPathComponent("s.plist"))
        layout.mirrorOwner = getuid()
        let s = LoginWindowInstall.status(layout)
        XCTAssertFalse(s.installed)
        XCTAssertFalse(s.healthy)
    }

    func testMirrorMatchesNoticesAStaleCopy() throws {
        try put(HostIdentity.fileName, P256.Signing.PrivateKey().rawRepresentation)
        _ = try LoginWindowInstall.sync(userDirectory: user, userUID: getuid(), mirror: mirror)
        XCTAssertEqual(LoginWindowInstall.mirrorMatches(userDirectory: user, userUID: getuid(), mirror: mirror, mirrorUID: getuid()), true)
        try put(DeviceTrustStore.fileName, Data("changed".utf8))
        XCTAssertEqual(LoginWindowInstall.mirrorMatches(userDirectory: user, userUID: getuid(), mirror: mirror, mirrorUID: getuid()), false)
    }
}
