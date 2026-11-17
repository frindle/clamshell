import Foundation

// The client's side of sending files, several one after another (PROTOCOL.md
// "File transfer"). No I/O and no clock: the app reads files and writes to the
// socket, and this decides what to send next. It sits on `FileSender`, which
// is one transfer. Shared by the iOS app (compiled into it) and the tests.

/// A file the user chose to send.
struct FileSendJob: Equatable {
    let name: String
    let size: UInt64
    let modified: Int64?
}

/// What the app does next.
enum FileSendStep: Equatable {
    /// Write this message to the socket.
    case send(FileTransferMessage)
    /// Read up to `length` bytes from the current file and give them to
    /// `pieceRead`. Asked for again only after the previous piece was written.
    case read(length: Int)
    /// Bytes of file `index` that have gone out.
    case progress(index: Int, sent: UInt64, size: UInt64)
    /// File `index` is over, one way or the other.
    case finished(index: Int, FileSendOutcome)
    /// Nothing is left to send.
    case allDone
}

final class FileSendQueue {
    private(set) var jobs: [FileSendJob] = []
    private(set) var outcomes: [Int: FileSendOutcome] = [:]
    private var sender: FileSender?
    private var index = 0
    private var nextId: UInt32 = 1

    /// A file is being offered or sent, or more are waiting.
    var isBusy: Bool { sender != nil || index < jobs.count }
    var currentIndex: Int? { sender == nil ? nil : index }

    /// Adds files to the end. Starts the first if nothing is going on.
    func add(_ new: [FileSendJob]) -> [FileSendStep] {
        let wasBusy = isBusy
        jobs += new
        return wasBusy ? [] : startNext()
    }

    /// One FILE_* message from the host. An offer from the host is declined:
    /// this app receives no files. Other types are not for the client.
    func receive(type: UInt8, payload: Data) -> [FileSendStep] {
        switch type {
        case FileTransfer.offerType:
            switch FileTransfer.parseOffer(payload) {
            case let .usable(o): return [.send(FileTransfer.answer(id: o.id, status: FileTransfer.Answer.declined))]
            case let .decline(id): return [.send(FileTransfer.answer(id: id, status: FileTransfer.Answer.declined))]
            case .ignore: return []
            }
        case FileTransfer.answerType:
            guard var s = sender, let (id, status) = FileTransfer.decodeStatus(payload), id == s.id else { return [] }
            s.handleAnswer(status: status)
            sender = s
            if case let .ended(outcome) = s.phase { return finish(outcome) }
            guard s.phase == .accepted else { return [] }
            // An empty file has no data to send: it ends at once.
            return s.size == 0 ? endSteps() : [.read(length: s.nextPieceLength())]
        case FileTransfer.endType:
            guard var s = sender, let (id, status) = FileTransfer.decodeStatus(payload), id == s.id else { return [] }
            s.handleEnd(status: status)
            sender = s
            if case let .ended(outcome) = s.phase { return finish(outcome) }
            return []
        default:
            return []
        }
    }

    /// The bytes asked for by `.read`. Empty bytes mean the file ended early.
    func pieceRead(_ bytes: Data) -> [FileSendStep] {
        guard var s = sender else { return [] }
        guard let message = s.pieceMessage(bytes) else {
            let fail = s.fail()
            sender = s
            return (fail.map { [FileSendStep.send($0)] } ?? []) + finish(.failed)
        }
        sender = s
        var steps: [FileSendStep] = [.send(message), .progress(index: index, sent: s.sent, size: s.size)]
        if s.allSent {
            steps += endSteps()
        } else {
            steps.append(.read(length: s.nextPieceLength()))
        }
        return steps
    }

    /// The file could not be read: FILE_END 2, then on to the next.
    func readFailed() -> [FileSendStep] {
        guard var s = sender else { return [] }
        let fail = s.fail()
        sender = s
        return (fail.map { [FileSendStep.send($0)] } ?? []) + finish(.failed)
    }

    /// The host did not answer in time: give up on this file.
    func answerTimedOut() -> [FileSendStep] {
        guard let s = sender, s.phase == .offered else { return [] }
        return readFailed()
    }

    /// The user cancelled: the file in flight is cancelled (FILE_END 1) and
    /// the files still waiting are not sent.
    func cancelAll() -> [FileSendStep] {
        var steps: [FileSendStep] = []
        if var s = sender {
            if let m = s.cancel() { steps.append(.send(m)) }
            sender = nil
            outcomes[index] = .cancelled
            steps.append(.finished(index: index, .cancelled))
            index += 1
        }
        while index < jobs.count {
            outcomes[index] = .cancelled
            steps.append(.finished(index: index, .cancelled))
            index += 1
        }
        steps.append(.allDone)
        return steps
    }

    /// The connection ended: nothing can be sent now.
    func connectionClosed() -> [FileSendStep] {
        guard isBusy else { return [] }
        var steps: [FileSendStep] = []
        if sender != nil {
            sender = nil
            outcomes[index] = .failed
            steps.append(.finished(index: index, .failed))
            index += 1
        }
        while index < jobs.count {
            outcomes[index] = .failed
            steps.append(.finished(index: index, .failed))
            index += 1
        }
        steps.append(.allDone)
        return steps
    }

    // MARK: steps

    private func startNext() -> [FileSendStep] {
        guard index < jobs.count else { return [.allDone] }
        let job = jobs[index]
        // A name the wire cannot carry or a file too big is failed here, not offered.
        guard job.name.utf8.count <= FileTransfer.maxNameBytes, job.size <= FileTransfer.maxSize else {
            outcomes[index] = .failed
            let done = FileSendStep.finished(index: index, .failed)
            index += 1
            return [done] + startNext()
        }
        let s = FileSender(id: nextId, name: job.name, size: job.size, modified: job.modified)
        nextId &+= 1
        sender = s
        return [.send(s.offerMessage())]
    }

    private func endSteps() -> [FileSendStep] {
        guard var s = sender, let m = s.endMessage() else { return [] }
        sender = s
        return [.send(m)]
    }

    private func finish(_ outcome: FileSendOutcome) -> [FileSendStep] {
        sender = nil
        outcomes[index] = outcome
        let done = FileSendStep.finished(index: index, outcome)
        index += 1
        return [done] + startNext()
    }
}
