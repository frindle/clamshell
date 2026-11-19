import XCTest
@testable import Clamshell

/// The Mac host's file session (PROTOCOL.md "File transfer"), writing into a
/// temporary folder.
final class HostFileSessionTests: XCTestCase {
    private var root: URL!
    private var folder: URL { root.appendingPathComponent("inbox", isDirectory: true) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clamshell-hostfiles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func names() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    private func session(enabled: @escaping () -> Bool = { true }, free: UInt64? = UInt64.max,
                         stored: @escaping (URL) -> Void = { _ in }) -> HostFileSession {
        HostFileSession(sink: DiskFileSink(folder: folder, reserveBytes: 1000, freeSpace: { _ in free }),
                        enabled: enabled, onStored: stored)
    }

    private func send(_ s: HostFileSession, _ m: FileTransferMessage, now: TimeInterval = 0) -> [FileTransferMessage] {
        // Frames are [type][4-byte length][payload]; unwrap to compare.
        s.receive(type: m.type, payload: m.payload, now: now).map { frame in
            FileTransferMessage(type: frame[0], payload: frame.dropFirst(5))
        }
    }

    private func answerStatus(_ replies: [FileTransferMessage]) -> UInt8? {
        guard let a = replies.first(where: { $0.type == FileTransfer.answerType }) else { return nil }
        return FileTransfer.decodeStatus(a.payload)?.status
    }

    // MARK: who may transfer

    func testOnlyAnAcceptedDeviceWithBit5MayTransfer() {
        XCTAssertTrue(HostFileSession.allowed(phase: .accepted, capabilities: [.fileTransfer]))
        XCTAssertFalse(HostFileSession.allowed(phase: .accepted, capabilities: [.relativeMouse, .peripherals]))
        XCTAssertFalse(HostFileSession.allowed(phase: .accepted, capabilities: nil))
        for phase in [StreamLink.Phase.awaitingResponse, .open, .closed] {
            XCTAssertFalse(HostFileSession.allowed(phase: phase, capabilities: [.fileTransfer]), "\(phase)")
        }
    }

    func testTheHostAdvertisesBit5() {
        XCTAssertEqual(StreamCapabilities.fileTransfer.rawValue, 1 << 5)
    }

    // MARK: transfers

    func testAnAcceptedTransferWritesTheRightBytes() throws {
        var told: [URL] = []
        let s = session(stored: { told.append($0) })
        let bytes = Data((0..<5000).map { UInt8($0 % 251) })
        XCTAssertEqual(answerStatus(send(s, FileTransfer.offer(id: 7, name: "note.txt", size: UInt64(bytes.count)))),
                       FileTransfer.Answer.accept)
        _ = send(s, FileTransfer.data(id: 7, bytes: bytes), now: 1)
        let done = send(s, FileTransfer.end(id: 7, status: FileTransfer.End.complete), now: 2)
        XCTAssertEqual(done.first?.type, FileTransfer.endType)
        XCTAssertEqual(names(), ["note.txt"])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("note.txt")), bytes)
        XCTAssertEqual(told.map(\.lastPathComponent), ["note.txt"])
        XCTAssertEqual(s.openCount, 0)
    }

    func testTurningTransfersOffAnswersStatus4() {
        var on = true
        let s = session(enabled: { on })
        on = false
        XCTAssertEqual(answerStatus(send(s, FileTransfer.offer(id: 1, name: "a.txt", size: 3))),
                       FileTransfer.Answer.off)
        XCTAssertEqual(names(), [])
    }

    func testAFullDiskAnswersStatus2() {
        let s = session(free: 10)
        XCTAssertEqual(answerStatus(send(s, FileTransfer.offer(id: 1, name: "big.bin", size: 5000))),
                       FileTransfer.Answer.noRoom)
        XCTAssertEqual(names(), [])
    }

    func testADropMidTransferLeavesNoPartialFile() {
        var told = 0
        let s = session(stored: { _ in told += 1 })
        _ = send(s, FileTransfer.offer(id: 3, name: "half.bin", size: 10_000))
        _ = send(s, FileTransfer.data(id: 3, bytes: Data(repeating: 1, count: 4000)), now: 1)
        XCTAssertEqual(s.openCount, 1)
        s.closeAll() // the connection ended
        XCTAssertEqual(s.openCount, 0)
        XCTAssertEqual(names(), [], "neither the file nor its temporary part stays behind")
        XCTAssertEqual(told, 0)
    }

    func testAStalledTransferIsFailedAndRemoved() {
        let s = session()
        _ = send(s, FileTransfer.offer(id: 4, name: "slow.bin", size: 100))
        let out = s.tick(now: 1000)
        XCTAssertFalse(out.isEmpty)
        XCTAssertEqual(names(), [])
    }

    func testOtherTypesAndStrayMessagesAreIgnored() {
        let s = session()
        XCTAssertTrue(s.receive(type: FileTransfer.answerType, payload: Data(), now: 0).isEmpty)
        XCTAssertTrue(send(s, FileTransfer.data(id: 9, bytes: Data([1]))).isEmpty)
        XCTAssertEqual(names(), [])
    }
}
