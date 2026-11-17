import XCTest
@testable import Clamshell

/// The client's file sending queue (PROTOCOL.md "File transfer"), driven
/// against the real receiver the Mac host uses, writing to a temporary folder.
final class FileSendQueueTests: XCTestCase {
    private var root: URL!
    private var folder: URL { root.appendingPathComponent("inbox", isDirectory: true) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clamshell-sendq-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func names() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    /// Runs the queue against a receiver until nothing is left to do.
    private final class Bench {
        let queue = FileSendQueue()
        let receiver: FileReceiver
        var contents: [Int: Data]
        var finished: [Int: FileSendOutcome] = [:]
        var progress: [Int: UInt64] = [:]
        var done = false
        var wire: [UInt8] = []   // types the client sent, in order
        var pieces = 0

        init(receiver: FileReceiver, contents: [Int: Data]) {
            self.receiver = receiver
            self.contents = contents
        }

        func run(_ first: [FileSendStep], pieceSize: Int = 4000) {
            var work = first
            while !work.isEmpty {
                let step = work.removeFirst()
                switch step {
                case let .send(m):
                    wire.append(m.type)
                    var replies: [FileSendStep] = []
                    for r in receiver.receive(type: m.type, payload: m.payload, now: 0) {
                        replies += queue.receive(type: r.type, payload: r.payload)
                    }
                    work.insert(contentsOf: replies, at: 0)
                case let .read(length):
                    let i = queue.currentIndex!
                    let have = contents[i]!
                    let offset = Int(progress[i] ?? 0)
                    let n = min(length, pieceSize, have.count - offset)
                    pieces += 1
                    work.insert(contentsOf: queue.pieceRead(have.subdata(in: offset ..< offset + n)), at: 0)
                case let .progress(i, sent, _): progress[i] = sent
                case let .finished(i, outcome): finished[i] = outcome
                case .allDone: done = true
                }
            }
        }
    }

    private func bench(free: UInt64? = UInt64.max, enabled: Bool = true, _ contents: [Data]) -> Bench {
        let sink = DiskFileSink(folder: folder, reserveBytes: 1000, freeSpace: { _ in free })
        return Bench(receiver: FileReceiver(store: sink, transfersEnabled: enabled),
                     contents: Dictionary(uniqueKeysWithValues: contents.enumerated().map { ($0.offset, $0.element) }))
    }

    private func jobs(_ named: [(String, Data)]) -> [FileSendJob] {
        named.map { FileSendJob(name: $0.0, size: UInt64($0.1.count), modified: nil) }
    }

    // MARK: sending

    func testSeveralFilesGoOneAfterAnotherAndLandWithTheRightBytes() throws {
        let a = Data((0..<10_000).map { UInt8($0 % 251) })
        let b = Data("hello".utf8)
        let c = Data()
        let files = [("a.bin", a), ("b.txt", b), ("empty.txt", c)]
        let t = bench(files.map(\.1))
        t.run(t.queue.add(jobs(files)))
        XCTAssertEqual(t.finished, [0: .stored, 1: .stored, 2: .stored])
        XCTAssertTrue(t.done)
        XCTAssertFalse(t.queue.isBusy)
        XCTAssertEqual(names(), ["a.bin", "b.txt", "empty.txt"])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("a.bin")), a)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("b.txt")), b)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("empty.txt")), c)
        XCTAssertEqual(t.progress[0], 10_000)
        XCTAssertEqual(t.pieces, 3 + 1, "10 000 bytes in 4 000-byte pieces, then 5 bytes")
    }

    func testTheNextFileStartsOnlyAfterTheLastEnded() {
        let q = FileSendQueue()
        let steps = q.add([FileSendJob(name: "a", size: 1, modified: nil), FileSendJob(name: "b", size: 1, modified: nil)])
        XCTAssertEqual(steps.count, 1, "one offer; the second file waits")
        XCTAssertEqual(steps.first, .send(FileTransfer.offer(id: 1, name: "a", size: 1)))
        XCTAssertTrue(q.isBusy)
    }

    func testFilesAddedWhileBusyWait() {
        let q = FileSendQueue()
        _ = q.add([FileSendJob(name: "a", size: 1, modified: nil)])
        XCTAssertTrue(q.add([FileSendJob(name: "b", size: 1, modified: nil)]).isEmpty)
    }

    func testTheModifiedTimeRidesTheOffer() {
        let q = FileSendQueue()
        let steps = q.add([FileSendJob(name: "a", size: 1, modified: 1_700_000_000)])
        XCTAssertEqual(steps.first, .send(FileTransfer.offer(id: 1, name: "a", size: 1, modified: 1_700_000_000)))
    }

    // MARK: refusals

    func testHostTransfersOffAnswersStatus4() {
        let t = bench(enabled: false, [Data("x".utf8)])
        t.run(t.queue.add(jobs([("x.txt", Data("x".utf8))])))
        XCTAssertEqual(t.finished[0], .declined(status: FileTransfer.Answer.off))
        XCTAssertEqual(names(), [])
    }

    func testAFullDiskAnswersStatus2AndTheNextFileStillGoes() {
        // Room for the small file only: 1000 bytes reserve + the file.
        let small = Data("ok".utf8)
        let big = Data(repeating: 1, count: 5000)
        let sink = DiskFileSink(folder: folder, reserveBytes: 1000, freeSpace: { _ in 1500 })
        let t = Bench(receiver: FileReceiver(store: sink), contents: [0: big, 1: small])
        t.run(t.queue.add(jobs([("big.bin", big), ("small.txt", small)])))
        XCTAssertEqual(t.finished[0], .declined(status: FileTransfer.Answer.noRoom))
        XCTAssertEqual(t.finished[1], .stored)
        XCTAssertEqual(names(), ["small.txt"])
    }

    func testAHostOfferIsDeclined() {
        let q = FileSendQueue()
        let offer = FileTransfer.offer(id: 9, name: "from-host.txt", size: 3)
        XCTAssertEqual(q.receive(type: offer.type, payload: offer.payload),
                       [.send(FileTransfer.answer(id: 9, status: FileTransfer.Answer.declined))])
        // A broken offer with a readable id is declined too; one without is ignored.
        let broken = Data("{\"id\":4,\"name\":5}".utf8)
        XCTAssertEqual(q.receive(type: FileTransfer.offerType, payload: broken),
                       [.send(FileTransfer.answer(id: 4, status: FileTransfer.Answer.declined))])
        XCTAssertTrue(q.receive(type: FileTransfer.offerType, payload: Data("nonsense".utf8)).isEmpty)
        XCTAssertFalse(q.isBusy)
    }

    func testANameOrSizeTheWireCannotCarryIsFailedNotOffered() {
        let q = FileSendQueue()
        let long = String(repeating: "a", count: 300)
        let steps = q.add([FileSendJob(name: long, size: 1, modified: nil),
                           FileSendJob(name: "ok", size: 1, modified: nil)])
        XCTAssertEqual(steps.first, .finished(index: 0, .failed))
        XCTAssertEqual(steps.last, .send(FileTransfer.offer(id: 1, name: "ok", size: 1)))
    }

    func testAnAnswerForAnotherIdIsIgnored() {
        let q = FileSendQueue()
        _ = q.add([FileSendJob(name: "a", size: 1, modified: nil)])
        let wrong = FileTransfer.answer(id: 77, status: FileTransfer.Answer.accept)
        XCTAssertTrue(q.receive(type: wrong.type, payload: wrong.payload).isEmpty)
    }

    // MARK: cancel, failure, drop

    func testCancelSendsFileEnd1AndDropsTheRest() {
        let q = FileSendQueue()
        _ = q.add([FileSendJob(name: "a", size: 100, modified: nil), FileSendJob(name: "b", size: 1, modified: nil)])
        let accept = FileTransfer.answer(id: 1, status: FileTransfer.Answer.accept)
        _ = q.receive(type: accept.type, payload: accept.payload)
        let steps = q.cancelAll()
        XCTAssertEqual(steps, [.send(FileTransfer.end(id: 1, status: FileTransfer.End.cancelled)),
                               .finished(index: 0, .cancelled), .finished(index: 1, .cancelled), .allDone])
        XCTAssertFalse(q.isBusy)
    }

    func testCancelLeavesNoPartialFileOnTheReceiver() {
        let data = Data(repeating: 7, count: 9000)
        let t = bench([data])
        var steps = t.queue.add(jobs([("half.bin", data)]))
        // Run the offer and one piece, then cancel.
        var sent = 0
        while !steps.isEmpty {
            let step = steps.removeFirst()
            switch step {
            case let .send(m):
                var replies: [FileSendStep] = []
                for r in t.receiver.receive(type: m.type, payload: m.payload, now: 0) {
                    replies += t.queue.receive(type: r.type, payload: r.payload)
                }
                steps.insert(contentsOf: replies, at: 0)
                if m.type == FileTransfer.dataType { sent += 1 }
            case .read:
                if sent == 1 { steps = [] } else {
                    steps.insert(contentsOf: t.queue.pieceRead(data.prefix(4000)), at: 0)
                }
            default: break
            }
        }
        for step in t.queue.cancelAll() {
            if case let .send(m) = step { _ = t.receiver.receive(type: m.type, payload: m.payload, now: 0) }
        }
        XCTAssertEqual(t.receiver.openCount, 0)
        XCTAssertEqual(names(), [], "no file and no temporary part")
    }

    func testAReadFailureFailsThatFileAndGoesOn() {
        let q = FileSendQueue()
        _ = q.add([FileSendJob(name: "a", size: 100, modified: nil), FileSendJob(name: "b", size: 1, modified: nil)])
        let accept = FileTransfer.answer(id: 1, status: FileTransfer.Answer.accept)
        _ = q.receive(type: accept.type, payload: accept.payload)
        let steps = q.readFailed()
        XCTAssertEqual(steps.first, .send(FileTransfer.end(id: 1, status: FileTransfer.End.failed)))
        XCTAssertEqual(steps[1], .finished(index: 0, .failed))
        XCTAssertEqual(steps.last, .send(FileTransfer.offer(id: 2, name: "b", size: 1)))
    }

    func testAnUnansweredOfferTimesOut() {
        let q = FileSendQueue()
        _ = q.add([FileSendJob(name: "a", size: 1, modified: nil)])
        let steps = q.answerTimedOut()
        XCTAssertTrue(steps.contains(.finished(index: 0, .failed)))
        XCTAssertFalse(q.isBusy)
    }

    func testAClosedConnectionFailsEverythingLeft() {
        let q = FileSendQueue()
        _ = q.add([FileSendJob(name: "a", size: 1, modified: nil), FileSendJob(name: "b", size: 1, modified: nil)])
        XCTAssertEqual(q.connectionClosed(),
                       [.finished(index: 0, .failed), .finished(index: 1, .failed), .allDone])
        XCTAssertFalse(q.isBusy)
        XCTAssertTrue(q.connectionClosed().isEmpty)
    }

    func testAShortReadFailsTheTransfer() {
        let q = FileSendQueue()
        _ = q.add([FileSendJob(name: "a", size: 10, modified: nil)])
        let accept = FileTransfer.answer(id: 1, status: FileTransfer.Answer.accept)
        XCTAssertEqual(q.receive(type: accept.type, payload: accept.payload), [.read(length: 10)])
        let steps = q.pieceRead(Data())
        XCTAssertEqual(steps.first, .send(FileTransfer.end(id: 1, status: FileTransfer.End.failed)))
        XCTAssertTrue(steps.contains(.finished(index: 0, .failed)))
    }
}
