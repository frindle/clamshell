import Foundation
import Combine

// Sends files the user picked (Files, iCloud Drive, a USB drive) to the Mac,
// one after another. The rules are in FileSendQueue (shared, tested); this
// reads the files, writes to the socket and shows what happened. Main thread
// only, except where a comment says otherwise.

final class FileSendController: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id: Int
        let name: String
        let size: UInt64
        var sent: UInt64 = 0
        /// Nil while waiting or sending.
        var result: String?
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var busy = false

    private unowned let client: StreamClient
    private let queue = FileSendQueue()
    private var pending: [FileSendStep] = []
    private var inFlight = false
    private var answerTimer: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    /// Where each file is, and which of them were opened under security scope.
    private var urls: [Int: URL] = [:]
    private var scoped = Set<Int>()
    /// Open files. Used on `readQueue` only.
    private var handles: [Int: FileHandle] = [:]
    private let readQueue = DispatchQueue(label: "clamshell.viewer.filesend")

    /// How long the Mac has to answer an offer. Someone may be asked.
    static let answerTimeout: TimeInterval = 60

    init(client: StreamClient) {
        self.client = client
        client.onFileMessage = { [weak self] type, payload in
            DispatchQueue.main.async { self?.receive(type: type, payload: payload) }
        }
        // The connection ended or came back without the Mac taking files.
        client.$hostCapabilities
            .receive(on: DispatchQueue.main)
            .sink { [weak self] caps in
                if !caps.contains(.fileTransfer) { self?.connectionClosed() }
            }
            .store(in: &cancellables)
    }

    // MARK: user actions

    /// Files chosen in the document picker. Their access is kept open until
    /// each one is done.
    func send(_ picked: [URL]) {
        guard !picked.isEmpty else { return }
        var jobs: [FileSendJob] = []
        for url in picked {
            let index = queue.jobs.count + jobs.count
            let opened = url.startAccessingSecurityScopedResource()
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
            urls[index] = url
            if opened { scoped.insert(index) }
            // A folder or a file whose size cannot be read gets a size the
            // queue fails at once (nothing is offered for it).
            let readable = values?.isDirectory != true && values?.fileSize != nil
            let size = readable ? UInt64(values?.fileSize ?? 0) : UInt64.max
            let modified = values?.contentModificationDate.map { Int64($0.timeIntervalSince1970) }
            jobs.append(FileSendJob(name: url.lastPathComponent, size: size, modified: modified))
            items.append(Item(id: index, name: url.lastPathComponent, size: readable ? size : 0))
        }
        busy = true
        run(queue.add(jobs))
    }

    /// Stops the file being sent and drops the ones waiting.
    func cancel() {
        pending = pending.filter { if case .finished = $0 { return true } else { return false } }
        answerTimer?.cancel()
        run(queue.cancelAll())
    }

    func clearFinished() {
        items.removeAll { $0.result != nil }
    }

    // MARK: wire

    private func receive(type: UInt8, payload: Data) {
        if type == FileTransfer.answerType { answerTimer?.cancel() }
        run(queue.receive(type: type, payload: payload))
    }

    private func connectionClosed() {
        pending = pending.filter { if case .finished = $0 { return true } else { return false } }
        answerTimer?.cancel()
        run(queue.connectionClosed())
    }

    // MARK: running the steps

    private func run(_ steps: [FileSendStep]) {
        pending += steps
        drain()
    }

    /// One step at a time: the next file piece is read only after the last was
    /// written to the socket.
    private func drain() {
        guard !inFlight else { return }
        while !pending.isEmpty {
            switch pending.removeFirst() {
            case let .send(message):
                inFlight = true
                client.sendAndWait(message.frame) { [weak self] ok in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.inFlight = false
                        if !ok { self.connectionClosed(); return }
                        if message.type == FileTransfer.offerType { self.armAnswerTimer() }
                        self.drain()
                    }
                }
                return
            case let .read(length):
                guard let index = queue.currentIndex, let url = urls[index] else { continue }
                inFlight = true
                readQueue.async { [weak self] in
                    guard let self else { return }
                    let data = try? self.handle(for: index, url: url).read(upToCount: length)
                    DispatchQueue.main.async {
                        self.inFlight = false
                        // Cancelled or ended while the read was going.
                        if self.queue.currentIndex == index { self.run(self.queue.pieceRead(data ?? Data())) }
                        else { self.drain() }
                    }
                }
                return
            case let .progress(index, sent, _):
                if let i = items.firstIndex(where: { $0.id == index }) { items[i].sent = sent }
            case let .finished(index, outcome):
                finish(index, outcome)
            case .allDone:
                busy = false
            }
        }
    }

    private func armAnswerTimer() {
        answerTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.run(self.queue.answerTimedOut())
        }
        answerTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.answerTimeout, execute: item)
    }

    private func finish(_ index: Int, _ outcome: FileSendOutcome) {
        if let i = items.firstIndex(where: { $0.id == index }) {
            items[i].result = Self.words(outcome)
            if outcome == .stored { items[i].sent = items[i].size }
        }
        if scoped.remove(index) != nil { urls[index]?.stopAccessingSecurityScopedResource() }
        urls[index] = nil
        readQueue.async { [weak self] in
            try? self?.handles[index]?.close()
            self?.handles[index] = nil
        }
    }

    /// On `readQueue`.
    private func handle(for index: Int, url: URL) throws -> FileHandle {
        if let h = handles[index] { return h }
        let h = try FileHandle(forReadingFrom: url)
        handles[index] = h
        return h
    }

    static func words(_ outcome: FileSendOutcome) -> String {
        switch outcome {
        case .stored: return "Sent"
        case .cancelled: return "Cancelled"
        case .failed: return "Failed"
        case let .declined(status):
            switch status {
            case FileTransfer.Answer.declined: return "The Mac declined it"
            case FileTransfer.Answer.noRoom: return "No room on the Mac"
            case FileTransfer.Answer.tooMany: return "The Mac is receiving too many files"
            case FileTransfer.Answer.off: return "Receiving files is turned off on the Mac"
            default: return "Not accepted by the Mac"
            }
        }
    }
}
