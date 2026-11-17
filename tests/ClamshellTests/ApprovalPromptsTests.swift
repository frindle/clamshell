import XCTest
@testable import Clamshell

/// What the host's approval window asks about next, and which decisions made
/// somewhere else it shows (PROTOCOL.md "Approving a device"). The records
/// here are made by hand: nothing in ApprovalPrompts reads a key or a file.
final class ApprovalPromptsTests: XCTestCase {
    private typealias Notice = ApprovalPrompts.Notice

    // MARK: helpers

    /// 64 lowercase hex digits that differ in the first 16 for different `n`
    /// below 256, so every device has its own fingerprint.
    private func id(_ n: Int) -> String {
        String(repeating: String(n / 16, radix: 16) + String(n % 16, radix: 16), count: 32)
    }

    private func device(_ n: Int, _ state: DeviceState, name: String = "", firstSeen: Double = 0,
                        decidedAt: Double? = nil, by: String? = nil) -> DeviceRecord {
        DeviceRecord(id: id(n), publicKey: "", name: name, state: state, firstSeen: firstSeen,
                     lastSeen: firstSeen, address: "192.0.2.7", decidedAt: decidedAt, decidedBy: by)
    }

    /// The window with nothing on screen.
    private func idle(_ p: inout ApprovalPrompts, _ records: [DeviceRecord],
                      now: TimeInterval = 0) -> ApprovalPrompts.Step {
        p.step(records: records, asking: nil, noticeVisible: false, now: now)
    }

    /// The device of the notice a step shows, if it shows one.
    private func shown(_ step: ApprovalPrompts.Step) -> String? {
        if case .notice(let notice) = step { return notice.device.id }
        return nil
    }

    /// Every notice the window would show, one after the other.
    private func walk(_ p: inout ApprovalPrompts, _ records: [DeviceRecord]) -> [String] {
        var ids: [String] = []
        while let next = shown(idle(&p, records)) {
            ids.append(next)
            if ids.count > 64 { break }
        }
        return ids
    }

    // MARK: decisions made somewhere else

    func testWhatWasDecidedBeforeTheAppStartedIsNotNews() {
        var p = ApprovalPrompts()
        let a = device(1, .trusted, decidedAt: 100, by: "cli")
        let b = device(2, .denied, decidedAt: 100, by: "host")
        XCTAssertEqual(p.note([a, b]), [])
        XCTAssertEqual(idle(&p, [a, b]), .dismiss)
        // The same list again is no news either.
        XCTAssertEqual(p.note([a, b]), [])
    }

    func testDecisionThisAppDidNotMakeIsReported() {
        var p = ApprovalPrompts()
        let waiting = device(1, .waiting, name: "Pad", firstSeen: 50)
        XCTAssertEqual(p.note([waiting]), [])
        let approved = device(1, .trusted, name: "Pad", firstSeen: 50, decidedAt: 200, by: "cli")
        XCTAssertEqual(p.note([approved]), [Notice(device: approved, wasTrusted: false)])
        // Told once.
        XCTAssertEqual(p.note([approved]), [])

        // A record that says "host" is reported all the same: what counts is
        // that this app did not make the decision.
        let byHost = device(2, .trusted, decidedAt: 300, by: "host")
        XCTAssertEqual(p.note([approved, byHost]), [Notice(device: byHost, wasTrusted: false)])
    }

    func testDecisionThisAppMakesIsNotReportedBack() {
        var p = ApprovalPrompts()
        let waiting = device(1, .waiting, firstSeen: 50)
        _ = p.note([waiting])
        p.expect(id(1), .trusted)
        let approved = device(1, .trusted, firstSeen: 50, decidedAt: 200, by: "host")
        XCTAssertEqual(p.note([approved]), [])

        // Good for one look at the list: a revoke that was expected but did
        // not happen does not excuse one that happens later.
        p.expect(id(1), .denied)
        XCTAssertEqual(p.note([approved]), [])
        let revoked = device(1, .denied, firstSeen: 50, decidedAt: 300, by: "cli")
        XCTAssertEqual(p.note([revoked]), [Notice(device: revoked, wasTrusted: true)])
    }

    func testExpectingOneThingAndGettingAnotherIsNews() {
        var p = ApprovalPrompts()
        _ = p.note([device(1, .waiting, firstSeen: 50)])
        p.expect(id(1), .trusted)
        let denied = device(1, .denied, firstSeen: 50, decidedAt: 200, by: "cli")
        XCTAssertEqual(p.note([denied]), [Notice(device: denied, wasTrusted: false)])
    }

    func testDeniedDeviceThatWasNeverSeenIsNotNewsButATrustedOneIs() {
        var p = ApprovalPrompts()
        _ = p.note([])
        let denied = device(1, .denied, decidedAt: 100, by: "cli")
        XCTAssertEqual(p.note([denied]), [])
        let trusted = device(2, .trusted, decidedAt: 100, by: "cli")
        XCTAssertEqual(p.note([denied, trusted]), [Notice(device: trusted, wasTrusted: false)])
    }

    func testDeviceDecidedTwiceBetweenTwoLooksIsReported() {
        var p = ApprovalPrompts()
        _ = p.note([device(1, .trusted, decidedAt: 100, by: "host")])
        // Revoked and approved again somewhere else: it stands where it
        // stood, but not by the same decision.
        let again = device(1, .trusted, decidedAt: 500, by: "cli")
        XCTAssertEqual(p.note([again]), [Notice(device: again, wasTrusted: true)])
        // Being seen again is not a decision.
        var seen = again
        seen.lastSeen = 900
        seen.address = "192.0.2.9"
        XCTAssertEqual(p.note([seen]), [])
    }

    func testOldestDecisionComesFirst() {
        var p = ApprovalPrompts()
        _ = p.note([device(1, .waiting, firstSeen: 10), device(2, .waiting, firstSeen: 20),
                    device(3, .waiting, firstSeen: 30)])
        let decided = [device(1, .trusted, firstSeen: 10, decidedAt: 300, by: "cli"),
                       device(2, .denied, firstSeen: 20, decidedAt: 100, by: "cli"),
                       device(3, .trusted, firstSeen: 30, decidedAt: 200, by: "cli")]
        XCTAssertEqual(p.note(decided).map(\.device.id), [id(2), id(3), id(1)])
        XCTAssertEqual(walk(&p, decided), [id(2), id(3), id(1)])
        XCTAssertEqual(idle(&p, decided), .dismiss)
    }

    func testWhenTooManyAreQueuedDenialsGoFirst() {
        var p = ApprovalPrompts()
        _ = p.note((1 ... 20).map { device($0, .waiting, firstSeen: Double($0)) })
        // Odd ones approved, even ones denied, in the order of their number.
        let decided = (1 ... 20).map {
            device($0, $0 % 2 == 1 ? .trusted : .denied, firstSeen: Double($0), decidedAt: 100 + Double($0), by: "cli")
        }
        // All twenty are reported; the window keeps sixteen.
        XCTAssertEqual(p.note(decided).count, 20)
        XCTAssertEqual(ApprovalPrompts.maxQueuedNotices, 16)
        let kept = [1, 3, 5, 7, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20].map(id)
        XCTAssertEqual(walk(&p, decided), kept)
    }

    func testWhenTooManyApprovalsAreQueuedTheOldestGo() {
        var p = ApprovalPrompts()
        _ = p.note((1 ... 18).map { device($0, .waiting, firstSeen: Double($0)) })
        let approved = (1 ... 18).map {
            device($0, .trusted, firstSeen: Double($0), decidedAt: 100 + Double($0), by: "cli")
        }
        _ = p.note(approved)
        XCTAssertEqual(walk(&p, approved), (3 ... 18).map(id))
    }

    func testShowAgainPutsANoticeAtTheFront() {
        var p = ApprovalPrompts()
        _ = p.note([device(1, .waiting, firstSeen: 10), device(2, .waiting, firstSeen: 20)])
        let decided = [device(1, .trusted, firstSeen: 10, decidedAt: 100, by: "cli"),
                       device(2, .trusted, firstSeen: 20, decidedAt: 200, by: "cli")]
        let news = p.note(decided)
        XCTAssertEqual(news.map(\.device.id), [id(1), id(2)])
        p.showAgain(news[1])
        XCTAssertEqual(shown(idle(&p, decided)), id(2))
        // It is on screen now: asking for it again does not queue it twice.
        p.showAgain(news[1])
        XCTAssertEqual(shown(idle(&p, decided)), id(1))
        XCTAssertEqual(idle(&p, decided), .dismiss)
        // One that was already shown can be asked for again.
        p.showAgain(news[1])
        XCTAssertEqual(shown(idle(&p, decided)), id(2))
        XCTAssertEqual(idle(&p, decided), .dismiss)
    }

    func testNoticeThatWasOvertakenIsNotShown() {
        var p = ApprovalPrompts()
        _ = p.note([device(1, .waiting, firstSeen: 10), device(2, .waiting, firstSeen: 20),
                    device(3, .waiting, firstSeen: 30)])
        let first = [device(1, .trusted, firstSeen: 10, decidedAt: 100, by: "cli"),
                     device(2, .trusted, firstSeen: 20, decidedAt: 200, by: "cli"),
                     device(3, .trusted, firstSeen: 30, decidedAt: 300, by: "cli")]
        XCTAssertEqual(p.note(first).count, 3)
        // Before any is shown: the first is forgotten, the second revoked on
        // this Mac, and the third revoked and approved again from elsewhere.
        let revoked = device(2, .denied, firstSeen: 20, decidedAt: 400, by: "host")
        let again = device(3, .trusted, firstSeen: 30, decidedAt: 500, by: "cli")
        p.expect(id(2), .denied)
        XCTAssertEqual(p.note([revoked, again]), [Notice(device: again, wasTrusted: true)])
        // Only the newest decision about the third is left to show.
        XCTAssertEqual(idle(&p, [revoked, again]), .notice(Notice(device: again, wasTrusted: true)))
        XCTAssertEqual(idle(&p, [revoked, again]), .dismiss)
    }

    func testNoticeShowsTheDeviceAsItIsNow() {
        var p = ApprovalPrompts()
        _ = p.note([device(1, .waiting, name: "Pad", firstSeen: 10)])
        let approved = device(1, .trusted, name: "Pad", firstSeen: 10, decidedAt: 100, by: "cli")
        _ = p.note([approved])
        var renamed = approved
        renamed.name = "Studio Pad"
        renamed.lastSeen = 150
        XCTAssertEqual(p.note([renamed]), [])
        XCTAssertEqual(idle(&p, [renamed]), .notice(Notice(device: renamed, wasTrusted: false)))
    }

    // MARK: what the window does next

    func testOrderOfWhatTheWindowShows() {
        var p = ApprovalPrompts()
        let w1 = device(1, .waiting, firstSeen: 10)
        let w2 = device(2, .waiting, firstSeen: 20)
        let w3 = device(3, .waiting, firstSeen: 30)
        _ = p.note([w1, w2, w3])

        // Nothing on screen: the device that has waited longest.
        XCTAssertEqual(idle(&p, [w3, w1, w2]), .ask(w1))
        // A question on screen stays, though an older device is waiting.
        XCTAssertEqual(p.step(records: [w1, w2, w3], asking: id(2), noticeVisible: false, now: 0), .ask(w2))
        // What the user picked comes before it.
        XCTAssertEqual(p.step(records: [w1, w2, w3], asking: id(2), noticeVisible: false, picked: id(3), now: 0),
                       .ask(w3))
        // A pick that is not waiting is not a pick.
        XCTAssertEqual(p.step(records: [w1, w2, w3], asking: id(2), noticeVisible: false, picked: id(9), now: 0),
                       .ask(w2))

        // The first is approved from somewhere else.
        let a1 = device(1, .trusted, firstSeen: 10, decidedAt: 100, by: "cli")
        let n1 = Notice(device: a1, wasTrusted: false)
        XCTAssertEqual(p.note([a1, w2, w3]), [n1])
        // The question on screen is not interrupted by that.
        XCTAssertEqual(p.step(records: [a1, w2, w3], asking: id(2), noticeVisible: false, now: 0), .ask(w2))
        // A question about the device that is no longer waiting gives way to
        // the notice, which comes before the next waiting device.
        XCTAssertEqual(p.step(records: [a1, w2, w3], asking: id(1), noticeVisible: false, now: 0), .notice(n1))
        // While the notice is up it stays.
        XCTAssertEqual(p.step(records: [a1, w2, w3], asking: nil, noticeVisible: true, now: 0), .keep)
        // When it is done: the next waiting device.
        XCTAssertEqual(idle(&p, [a1, w2, w3]), .ask(w2))
    }

    func testPickInterruptsANoticeWhichComesBackAfterwards() {
        var p = ApprovalPrompts()
        let w2 = device(2, .waiting, firstSeen: 20)
        let w3 = device(3, .waiting, firstSeen: 30)
        _ = p.note([w2, w3])
        let a2 = device(2, .denied, firstSeen: 20, decidedAt: 200, by: "cli")
        let n2 = Notice(device: a2, wasTrusted: false)
        XCTAssertEqual(p.note([a2, w3]), [n2])
        XCTAssertEqual(idle(&p, [a2, w3]), .notice(n2))

        // The user picks the waiting device in the menu while the notice is up.
        XCTAssertEqual(p.step(records: [a2, w3], asking: nil, noticeVisible: true, picked: id(3), now: 0), .ask(w3))
        // They approve it in the window, which is not news…
        let a3 = device(3, .trusted, firstSeen: 30, decidedAt: 300, by: "host")
        p.expect(id(3), .trusted)
        XCTAssertEqual(p.note([a2, a3]), [])
        // …and the notice that was interrupted comes back.
        XCTAssertEqual(idle(&p, [a2, a3]), .notice(n2))
        XCTAssertEqual(idle(&p, [a2, a3]), .dismiss)
    }

    func testWaitingDevicesOldestFirst() {
        let list = [device(1, .waiting, firstSeen: 30), device(2, .trusted, firstSeen: 1),
                    device(3, .waiting, firstSeen: 10), device(4, .denied, firstSeen: 2)]
        XCTAssertEqual(ApprovalPrompts.waiting(list).map(\.id), [id(3), id(1)])
        XCTAssertEqual(ApprovalPrompts.waiting([]), [])
    }

    // MARK: closing the window without deciding

    func testClosingTheWindowSetsTheWaitingDevicesAsideAndKeepsItAway() {
        var p = ApprovalPrompts()
        let w1 = device(1, .waiting, firstSeen: 10)
        let w2 = device(2, .waiting, firstSeen: 20)
        _ = p.note([w1, w2])
        XCTAssertEqual(p.next(in: [w1, w2], now: 1000), w1)

        p.setAsideAll(in: [w1, w2], now: 1000)
        XCTAssertEqual(p.setAside, [id(1), id(2)])
        XCTAssertEqual(p.quietUntil, 1020)
        XCTAssertTrue(p.isQuiet(now: 1019))
        XCTAssertFalse(p.isQuiet(now: 1020))

        // A device that asks during the quiet time does not bring the window
        // back…
        let w3 = device(3, .waiting, firstSeen: 1005)
        _ = p.note([w1, w2, w3])
        XCTAssertNil(p.next(in: [w1, w2, w3], now: 1010))
        XCTAssertEqual(idle(&p, [w1, w2, w3], now: 1010), .dismiss)
        // …and afterwards it is the only one the window asks about unasked.
        XCTAssertEqual(p.next(in: [w1, w2, w3], now: 1020), w3)
        XCTAssertEqual(idle(&p, [w1, w2, w3], now: 1020), .ask(w3))
    }

    func testQuietTimeDoesNotHoldBackWhatTheUserAskedForOrADecisionMadeElsewhere() {
        var p = ApprovalPrompts()
        let w1 = device(1, .waiting, firstSeen: 10)
        let w2 = device(2, .waiting, firstSeen: 20)
        _ = p.note([w1, w2])
        p.setAsideAll(in: [w1, w2], now: 1000)
        XCTAssertEqual(idle(&p, [w1, w2], now: 1001), .dismiss)

        // A device picked in the menu is asked about at once.
        XCTAssertEqual(p.step(records: [w1, w2], asking: nil, noticeVisible: false, picked: id(1), now: 1001),
                       .ask(w1))
        // A question that is on screen stays there.
        XCTAssertEqual(p.step(records: [w1, w2], asking: id(1), noticeVisible: false, now: 1001), .ask(w1))
        // A decision made elsewhere is shown.
        let a2 = device(2, .trusted, firstSeen: 20, decidedAt: 1002, by: "cli")
        XCTAssertEqual(p.note([w1, a2]).count, 1)
        XCTAssertEqual(shown(idle(&p, [w1, a2], now: 1003)), id(2))
        XCTAssertEqual(idle(&p, [w1, a2], now: 1003), .dismiss)
    }

    func testQuietTimeDoublesUpToFifteenMinutes() {
        var p = ApprovalPrompts()
        var quiet: [TimeInterval] = []
        // Closed again each time the window is back, 20 minutes apart: not
        // three within ten minutes, and well inside an hour.
        var now: TimeInterval = 5000
        for _ in 0 ..< 8 {
            p.setAsideAll(in: [], now: now)
            quiet.append(p.quietUntil - now)
            now += 1200
        }
        XCTAssertEqual(quiet, [20, 40, 80, 160, 320, 640, 900, 900])
        // However often it is closed.
        for _ in 0 ..< 40 {
            p.setAsideAll(in: [], now: now)
            now += 1200
        }
        XCTAssertEqual(p.quietUntil, now - 1200 + 900)
    }

    func testAnsweringDoesNotShortenTheQuietTime() {
        var p = ApprovalPrompts()
        let w1 = device(1, .waiting, firstSeen: 10)
        p.setAsideAll(in: [w1], now: 1000)
        XCTAssertEqual(p.quietUntil, 1020)
        // A window-raised question ends in Approve: the quiet time starts,
        // it is not cleared, and n goes up.
        p.questionEnded(id(1), .approved, in: [w1], now: 1030)
        XCTAssertEqual(p.quietUntil, 1070)
        XCTAssertTrue(p.isQuiet(now: 1069))
    }

    func testApprovingOrDenyingSetsNothingAsideButClosingSetsAllAside() {
        let w1 = device(1, .waiting, firstSeen: 10)
        let w2 = device(2, .waiting, firstSeen: 20)
        for outcome in [ApprovalPrompts.Outcome.approved, .denied] {
            var p = ApprovalPrompts()
            p.questionEnded(id(1), outcome, in: [w1, w2], now: 1000)
            XCTAssertEqual(p.setAside, [])
            XCTAssertNil(p.next(in: [w1, w2], now: 1010))
            XCTAssertEqual(p.next(in: [w1, w2], now: 1020), w1)
        }
        var p = ApprovalPrompts()
        p.questionEnded(id(1), .closed, in: [w1, w2], now: 1000)
        XCTAssertEqual(p.setAside, [id(1), id(2)])
    }

    func testDevicePickedInTheMenuChangesNeitherNNorTheQuietTime() {
        var p = ApprovalPrompts()
        let w1 = device(1, .waiting, firstSeen: 10)
        let w2 = device(2, .waiting, firstSeen: 20)
        p.setAsideAll(in: [w1, w2], now: 1000)
        XCTAssertEqual(p.quietUntil, 1020)
        // Picked while the window is quiet: shown at once.
        XCTAssertEqual(p.step(records: [w1, w2], asking: nil, noticeVisible: false, picked: id(2), now: 1001),
                       .ask(w2))
        // The question stays while it is on screen, then ends in Deny.
        XCTAssertEqual(p.step(records: [w1, w2], asking: id(2), noticeVisible: false, now: 1002), .ask(w2))
        p.questionEnded(id(2), .denied, in: [w1, w2], now: 1005)
        XCTAssertEqual(p.quietUntil, 1020)
        // n is still 1: the next close doubles it to 40, not 80.
        p.setAsideAll(in: [w1], now: 2000)
        XCTAssertEqual(p.quietUntil - 2000, 40)
        // A picked question that is closed leaves the quiet time alone too,
        // though it sets the waiting devices aside as always.
        _ = p.step(records: [w1, w2], asking: nil, noticeVisible: false, picked: id(1), now: 3000)
        p.questionEnded(id(1), .closed, in: [w1], now: 3001)
        XCTAssertEqual(p.quietUntil, 2040)
        XCTAssertEqual(p.setAside, [id(1), id(2)])
    }

    func testNStartsOverAfterAnHourWithNoQuestion() {
        var p = ApprovalPrompts()
        p.setAsideAll(in: [], now: 1000)          // 20
        p.setAsideAll(in: [], now: 2000)          // 40
        XCTAssertEqual(p.quietUntil - 2000, 40)
        p.setAsideAll(in: [], now: 2000 + 3599)   // 80: less than an hour since
        XCTAssertEqual(p.quietUntil - (2000 + 3599), 80)
        p.setAsideAll(in: [], now: 2000 + 3599 + 3600)
        XCTAssertEqual(p.quietUntil - (2000 + 3599 + 3600), 20)
    }

    func testThreeDeniesOrClosesWithinTenMinutesKeepTheWindowAwayForTwelveHours() {
        var p = ApprovalPrompts()
        p.questionEnded(id(1), .denied, in: [], now: 1000)
        p.questionEnded(id(2), .closed, in: [], now: 1300)
        XCTAssertEqual(p.quietUntil - 1300, 40)
        p.questionEnded(id(3), .denied, in: [], now: 1600)
        XCTAssertEqual(p.quietUntil, 1600 + 12 * 3600)
        XCTAssertTrue(p.isQuiet(now: 1600 + 12 * 3600 - 1))
        XCTAssertFalse(p.isQuiet(now: 1600 + 12 * 3600))
        // The streak starts over afterwards.
        p.questionEnded(id(4), .denied, in: [], now: 1600 + 12 * 3600)
        XCTAssertLessThan(p.quietUntil - (1600 + 12 * 3600), 3600)
    }

    func testTheThirdMustBeWithinTenMinutesOfTheFirstAndApprovalBreaksTheRow() {
        var p = ApprovalPrompts()
        p.questionEnded(id(1), .denied, in: [], now: 1000)
        p.questionEnded(id(2), .denied, in: [], now: 1300)
        p.questionEnded(id(3), .denied, in: [], now: 1601)   // 601 s after the first
        XCTAssertLessThan(p.quietUntil - 1601, 3600)

        var q = ApprovalPrompts()
        q.questionEnded(id(1), .denied, in: [], now: 1000)
        q.questionEnded(id(2), .approved, in: [], now: 1100)
        q.questionEnded(id(3), .denied, in: [], now: 1200)
        XCTAssertLessThan(q.quietUntil - 1200, 3600)

        // Questions the user picked do not count.
        var r = ApprovalPrompts()
        let w = device(5, .waiting, firstSeen: 1)
        r.questionEnded(id(1), .denied, in: [], now: 1000)
        r.questionEnded(id(2), .denied, in: [], now: 1100)
        _ = r.step(records: [w], asking: nil, noticeVisible: false, picked: id(5), now: 1150)
        r.questionEnded(id(5), .denied, in: [w], now: 1200)
        XCTAssertLessThan(r.quietUntil, 1200 + 3600)
    }

    func testClockSetBackCannotStretchTheQuietTime() {
        var p = ApprovalPrompts()
        p.setAsideAll(in: [], now: 6000)
        XCTAssertEqual(p.quietUntil, 6020)
        XCTAssertTrue(p.isQuiet(now: 6019))
        XCTAssertTrue(p.isQuiet(now: 6020 - ApprovalPrompts.longestQuiet))
        XCTAssertFalse(p.isQuiet(now: 6020 - ApprovalPrompts.longestQuiet - 1))
        XCTAssertFalse(p.isQuiet(now: 1000))
    }

    func testClockSetBackCannotStretchTheTwelveHourQuietTimeEither() {
        var p = ApprovalPrompts()
        for i in 0 ..< 3 { p.questionEnded(id(i), .closed, in: [], now: 6000 + Double(i)) }
        let until = p.quietUntil
        XCTAssertEqual(until, 6002 + 12 * 3600)
        XCTAssertTrue(p.isQuiet(now: until - 12 * 3600))
        XCTAssertFalse(p.isQuiet(now: until - 12 * 3600 - 1))
    }

    func testDevicePickedInTheMenuIsBroughtBack() {
        var p = ApprovalPrompts()
        let w1 = device(1, .waiting, firstSeen: 10)
        let w2 = device(2, .waiting, firstSeen: 20)
        _ = p.note([w1, w2])
        p.setAsideAll(in: [w1, w2], now: 1000)
        // Long after the quiet time nothing is asked: both were set aside.
        XCTAssertNil(p.next(in: [w1, w2], now: 2000))
        XCTAssertEqual(idle(&p, [w1, w2], now: 2000), .dismiss)

        p.bringBack(id(2))
        XCTAssertEqual(p.setAside, [id(1)])
        XCTAssertEqual(p.next(in: [w1, w2], now: 2000), w2)
        XCTAssertEqual(p.step(records: [w1, w2], asking: nil, noticeVisible: false, picked: id(2), now: 2000),
                       .ask(w2))
    }

    func testDeviceThatStoppedWaitingIsNoLongerSetAside() {
        var p = ApprovalPrompts()
        let w1 = device(1, .waiting, firstSeen: 10)
        let w2 = device(2, .waiting, firstSeen: 20)
        _ = p.note([w1, w2])
        p.setAsideAll(in: [w1, w2], now: 1000)
        _ = p.note([w1, w2])
        XCTAssertEqual(p.setAside, [id(1), id(2)])
        // The first is denied on this Mac; the second was forgotten.
        p.expect(id(1), .denied)
        _ = p.note([device(1, .denied, firstSeen: 10, decidedAt: 1100, by: "host")])
        XCTAssertEqual(p.setAside, [])
        // If the second asks again it is asked about like any new device.
        let back = device(2, .waiting, firstSeen: 3000)
        _ = p.note([back])
        XCTAssertEqual(p.next(in: [back], now: 3000), back)
    }

    // MARK: wording

    func testWhereADecisionCameFrom() {
        let pad = device(0xab, .trusted, name: "Pad", decidedAt: 100, by: "host")
        let unnamed = device(0x12, .trusted, decidedAt: 100, by: "host")
        let records = [pad, unnamed]
        XCTAssertEqual(ApprovalPrompts.source(of: nil, among: records), "")
        XCTAssertEqual(ApprovalPrompts.source(of: "host", among: records), "on this Mac")
        XCTAssertEqual(ApprovalPrompts.source(of: "cli", among: records), "from the command line")
        XCTAssertEqual(ApprovalPrompts.source(of: id(0xab), among: records),
                       "from \u{201C}Pad\u{201D} ABAB-ABAB-ABAB-ABAB")
        XCTAssertEqual(ApprovalPrompts.source(of: id(0x12), among: records),
                       "from \u{201C}Unnamed device\u{201D} 1212-1212-1212-1212")
        // A device that is no longer on the list is still named by its key.
        XCTAssertEqual(ApprovalPrompts.source(of: id(0xef), among: records),
                       "from device EFEF-EFEF-EFEF-EFEF")
    }

    func testSentenceForADecisionMadeElsewhere() {
        let pad = device(0xab, .trusted, name: "Pad", decidedAt: 100, by: "host")
        let approved = Notice(device: device(1, .trusted, name: "Phone", decidedAt: 200, by: "cli"),
                              wasTrusted: false)
        XCTAssertEqual(ApprovalPrompts.sentence(for: approved, among: [pad]),
                       "\u{201C}Phone\u{201D} was approved from the command line.")
        let revoked = Notice(device: device(1, .denied, name: "Phone", decidedAt: 200, by: id(0xab)),
                             wasTrusted: true)
        XCTAssertEqual(ApprovalPrompts.sentence(for: revoked, among: [pad]),
                       "\u{201C}Phone\u{201D} was revoked from \u{201C}Pad\u{201D} ABAB-ABAB-ABAB-ABAB.")
        let denied = Notice(device: device(2, .denied, decidedAt: 200, by: "host"), wasTrusted: false)
        XCTAssertEqual(ApprovalPrompts.sentence(for: denied, among: [pad]),
                       "\u{201C}Unnamed device\u{201D} was denied on this Mac.")
        // Approved again counts as approved, and nothing recorded says nothing.
        let again = Notice(device: device(3, .trusted, name: "Pad 2"), wasTrusted: true)
        XCTAssertEqual(ApprovalPrompts.sentence(for: again, among: [pad]), "\u{201C}Pad 2\u{201D} was approved.")
    }

    func testNameAlreadyUsedByATrustedDevice() {
        let trusted = device(1, .trusted, name: "Studio Pad")
        let sameName = device(2, .waiting, name: "studio pad")
        let accented = device(3, .waiting, name: "St\u{00FA}dio Pad")
        let wide = device(4, .waiting, name: "\u{FF33}tudio Pad")
        let other = device(5, .waiting, name: "Phone")
        let unnamed = device(6, .waiting)
        let all = [trusted, sameName, accented, wide, other, unnamed,
                   device(7, .trusted), device(8, .denied, name: "Phone")]
        XCTAssertTrue(ApprovalPrompts.sharesNameWithTrusted(sameName, among: all))
        XCTAssertTrue(ApprovalPrompts.sharesNameWithTrusted(accented, among: all))
        XCTAssertTrue(ApprovalPrompts.sharesNameWithTrusted(wide, among: all))
        // A denied device with the same name does not count, nor does having
        // no name, nor the device itself.
        XCTAssertFalse(ApprovalPrompts.sharesNameWithTrusted(other, among: all))
        XCTAssertFalse(ApprovalPrompts.sharesNameWithTrusted(unnamed, among: all))
        XCTAssertFalse(ApprovalPrompts.sharesNameWithTrusted(trusted, among: all))
    }

    func testLinesInTheDevicesMenu() {
        let now: TimeInterval = 1_000_000
        let pad = device(0xab, .trusted, name: "Pad", decidedAt: now - 3 * 86_400, by: "host")
        XCTAssertEqual(DevicesController.decidedLine(pad, verb: "Approved", among: [pad], now: now),
                       "Approved on this Mac, 3 d ago")
        let phone = device(1, .denied, name: "Phone", decidedAt: now - 7200, by: id(0xab))
        XCTAssertEqual(DevicesController.decidedLine(phone, verb: "Revoked", among: [pad, phone], now: now),
                       "Revoked from \u{201C}Pad\u{201D} ABAB-ABAB-ABAB-ABAB, 2 h ago")
        let noSource = device(2, .trusted, decidedAt: now - 120)
        XCTAssertEqual(DevicesController.decidedLine(noSource, verb: "Approved", among: [], now: now),
                       "Approved 2 min ago")
        let noTime = device(3, .denied, by: "cli")
        XCTAssertEqual(DevicesController.decidedLine(noTime, verb: "Denied", among: [], now: now),
                       "Denied from the command line")
        XCTAssertNil(DevicesController.decidedLine(device(4, .denied), verb: "Denied", among: [], now: now))

        XCTAssertEqual(DevicesController.sessions(1), "1 session")
        XCTAssertEqual(DevicesController.sessions(2), "2 sessions")
    }
}
