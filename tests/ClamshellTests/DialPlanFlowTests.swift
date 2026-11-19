import XCTest
import CryptoKit
@testable import Clamshell

/// What the client does when an attempt at one of a saved Mac's addresses
/// ends (`DialPlanFlow`), with the real connection flow producing the alarms.
/// The iOS app's StreamClient only does what these outcomes say.
final class DialPlanFlowTests: XCTestCase {
    private let hostKey = P256.Signing.PrivateKey()
    private let deviceKey = P256.Signing.PrivateKey()
    /// The home-network address, then the tunnel address the user picked.
    private let home = "ws://192.0.2.10:5903"
    private let tunnel = "wss://mac.example.com/stream"
    private let other = "ws://192.0.2.11:5903"

    private var hostPub: Data { hostKey.publicKey.x963Representation }

    /// What an attempt looked like from the app: how it ended, the last state
    /// it showed, and whether the socket opened.
    private struct Attempt {
        var end: FlowEnd
        var shown: FlowState?
        var opened: Bool
    }

    /// An attempt at `url` whose host presents a key that is not the saved one.
    private func stranger(at url: String, falls: Bool) throws -> Attempt {
        // The saved Mac is known at the home address, the tunnel address and a
        // third one, under a key that is not the one `hostPub` presents.
        var saved = KnownHosts()
        let savedKey = P256.Signing.PrivateKey().publicKey.x963Representation
        for address in [home, tunnel, other] {
            saved.recordVerified(key: savedKey, name: "Example Mac", address: address, now: 1)
        }
        let frame = StreamMessage.frame(type: .hello, payload: Data([1, 2]))
        var config = ClientAuthConfig(deviceKey: deviceKey.publicKey.x963Representation,
                                      sign: AuthSignature.signer(deviceKey), deviceName: "Example iPad",
                                      appVersion: "0.1.0", dialledURL: url, makeHello: { frame })
        config.fallsThrough = falls
        var flow = ClientAuthFlow(config: config, known: saved)
        _ = flow.opened()
        let host = try HostHandshake(identityKey: hostPub, capabilities: [.relativeMouse], name: "Example Mac")
        let actions = flow.received(type: StreamMessageType.authChallenge.rawValue, payload: host.challenge.payload)
        var end: FlowEnd?
        var shown: FlowState?
        for action in actions {
            if case let .end(e, _) = action { end = e }
            if case let .state(s) = action { shown = s }
        }
        return Attempt(end: try XCTUnwrap(end), shown: shown, opened: true)
    }

    private func decide(_ attempt: Attempt, at url: String, picked: String, isLast: Bool,
                        held: DialAlarm? = nil) -> DialPlanFlow.Outcome {
        DialPlanFlow.decide(end: attempt.end, shown: attempt.shown, opened: attempt.opened, address: url,
                            isPicked: url == picked, isLast: isLast, held: held)
    }

    private func alarm(_ attempt: Attempt, at url: String) throws -> DialAlarm {
        DialAlarm(state: try XCTUnwrap(attempt.shown), address: url)
    }

    // MARK: current behaviour

    func testStrangerOnTheFirstPrivateAddressThenThePinnedKeyOnTheTunnelConnectsWithNoAlarm() throws {
        let first = try stranger(at: home, falls: true)
        XCTAssertEqual(first.end, .nextAddress)
        let outcome = decide(first, at: home, picked: tunnel, isLast: false)
        let held = try alarm(first, at: home)
        XCTAssertEqual(outcome, .tryNext(held: held))
        // The tunnel address answers with the pinned key and connects: no alarm is left.
        let connected = FlowState.connected(verified: true, hostName: "Example Mac")
        XCTAssertNil(DialPlanFlow.held(after: connected, outcome.held))
        // Showing anything else keeps it.
        XCTAssertEqual(DialPlanFlow.held(after: .connecting, outcome.held), held)
    }

    func testStrangerOnAnAddressTheUserPickedIsAnAlarmAtOnce() throws {
        // The picked address does not fall through: the flow itself stops with the alarm.
        let picked = try stranger(at: tunnel, falls: false)
        XCTAssertEqual(picked.end, .stop)
        guard case .changedIdentity? = picked.shown else { return XCTFail("expected the changed-identity alarm") }
    }

    func testEveryAddressFailingShowsTheHeldAlarmNamingTheAddressThatRaisedIt() throws {
        let first = try stranger(at: home, falls: true)
        let held = try alarm(first, at: home)
        let a = decide(first, at: home, picked: other, isLast: false)
        XCTAssertEqual(a, .tryNext(held: held))
        // The last address, the one the user picked, never opens.
        let b = decide(Attempt(end: .failure, shown: nil, opened: false), at: other, picked: other,
                       isLast: true, held: a.held)
        XCTAssertEqual(b, .showAlarm(held))
        XCTAssertEqual(held.address, home)
    }

    func testAnAddressThatNeverOpensMovesOnWithNoAlarm() {
        let miss = Attempt(end: .failure, shown: nil, opened: false)
        XCTAssertEqual(decide(miss, at: home, picked: tunnel, isLast: false), .tryNext(held: nil))
        XCTAssertEqual(decide(miss, at: tunnel, picked: tunnel, isLast: true),
                       .showError(restartPlan: true, held: nil))
    }

    func testAnAddressTheClientChoseThatOpenedButGotNoSessionMovesOn() {
        let early = Attempt(end: .failure, shown: .failed("example"), opened: true)
        XCTAssertEqual(decide(early, at: home, picked: tunnel, isLast: false), .tryNext(held: nil))
    }

    func testASessionThatDroppedIsRetriedAtTheSameAddress() {
        let dropped = Attempt(end: .failure, shown: .connected(verified: true, hostName: "Example Mac"), opened: true)
        XCTAssertEqual(decide(dropped, at: home, picked: tunnel, isLast: false),
                       .showError(restartPlan: false, held: nil))
    }
}

// MARK: a picked address that opens and then drops

extension DialPlanFlowTests {
    func testPickedAddressThatOpensThenFailsShowsTheHeldAlarmNamingTheFirstAddress() throws {
        let first = try stranger(at: home, falls: true)
        let a = decide(first, at: home, picked: tunnel, isLast: false)
        let dropped = Attempt(end: .failure, shown: .connecting, opened: true)
        let b = decide(dropped, at: tunnel, picked: tunnel, isLast: true, held: a.held)
        XCTAssertEqual(b, .showAlarm(try alarm(first, at: home)))
    }

    func testPickedAddressThatOpensThenFailsWithNoAlarmRestartsThePlan() {
        let dropped = Attempt(end: .failure, shown: .connecting, opened: true)
        XCTAssertEqual(decide(dropped, at: tunnel, picked: tunnel, isLast: true),
                       .showError(restartPlan: true, held: nil))
    }

    func testPickedAddressThatReachedASessionKeepsItsPlace() {
        let dropped = Attempt(end: .failure, shown: .waitingForApproval(
            hostName: "Example Mac", hostFingerprint: "", deviceName: "Example iPad", deviceFingerprint: ""), opened: true)
        XCTAssertEqual(decide(dropped, at: tunnel, picked: tunnel, isLast: true),
                       .showError(restartPlan: false, held: nil))
    }
}

// MARK: picked address in the middle of the plan

extension DialPlanFlowTests {

    func testHeldAlarmIsNotLostWhenThePickedAddressIsNotLast() throws {
        // Plan [home, tunnel, other]: home answers with a stranger's key, the
        // picked tunnel opens and drops, and other still has to be tried.
        let first = try stranger(at: home, falls: true)
        let a = decide(first, at: home, picked: tunnel, isLast: false)
        let dropped = Attempt(end: .failure, shown: .connecting, opened: true)
        let b = decide(dropped, at: tunnel, picked: tunnel, isLast: false, held: a.held)
        XCTAssertEqual(b, .tryNext(held: try alarm(first, at: home)))
        // other cannot be reached: the held alarm is what the user sees.
        let miss = Attempt(end: .failure, shown: .failed("example"), opened: false)
        let c = decide(miss, at: other, picked: tunnel, isLast: true, held: b.held)
        XCTAssertEqual(c, .showAlarm(try alarm(first, at: home)))
    }

    func testPickedAddressInTheMiddleThatDropsWithNoAlarmKeepsItsPlace() {
        let dropped = Attempt(end: .failure, shown: .connecting, opened: true)
        XCTAssertEqual(decide(dropped, at: tunnel, picked: tunnel, isLast: false),
                       .showError(restartPlan: false, held: nil))
    }
}
