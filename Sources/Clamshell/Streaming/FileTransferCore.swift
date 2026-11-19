import Foundation

// File transfer core (PROTOCOL.md "File transfer"). Foundation only, so it can
// compile into the iOS app as well. Pure decision layer: it decodes payloads,
// decides what a receiver answers and keeps the per-connection bookkeeping,
// and talks to storage only through `FileTransferStore`. No sockets, no
// clock of its own (the caller passes `now`), no file system here.

/// One message to put on the wire: `type` and `payload` are the inner message,
/// `frame` adds the `[type][4-byte length]` header before SECURE wraps it.
struct FileTransferMessage: Equatable {
    let type: UInt8
    let payload: Data

    var frame: Data {
        var d = Data(capacity: 5 + payload.count)
        d.append(type)
        d.appendBE(UInt32(payload.count))
        d.append(payload)
        return d
    }
}

/// A file offer as a receiver reads it.
struct FileOffer: Equatable {
    let id: UInt32
    let name: String
    let size: UInt64
    /// Seconds since 1970; nil when absent or not a whole number.
    let modified: Int64?
}

/// What a receiver does with a FILE_OFFER payload.
enum FileOfferParse: Equatable {
    case usable(FileOffer)
    /// The id is usable but the name or size is not: answer status 1.
    case decline(id: UInt32)
    /// Nothing to answer to.
    case ignore
}

enum FileTransferState: Equatable {
    case open, stored, failed, cancelled
}

/// Where a receiver puts the bytes. The receiver has already checked order,
/// sizes and counts; the store only has to keep them.
protocol FileTransferStore: AnyObject {
    /// True when `size` bytes fit, with whatever reserve the store keeps.
    func hasRoom(forBytes size: UInt64) -> Bool
    /// Start a transfer. `storedName` is the output of
    /// `FileTransfer.storedName(for:)`, never the name as offered. False: it
    /// cannot be started.
    func begin(id: UInt32, storedName: String, size: UInt64) -> Bool
    /// Append the next bytes. False: they could not be kept.
    func write(id: UInt32, bytes: Data) -> Bool
    /// Every byte arrived: make the file final. False: it could not be.
    func finish(id: UInt32) -> Bool
    /// Throw the partial file away. Safe to call for an id that is gone.
    func discard(id: UInt32)
}

enum FileTransfer {
    static let offerType: UInt8 = 0x58
    static let answerType: UInt8 = 0x59
    static let dataType: UInt8 = 0x5A
    static let endType: UInt8 = 0x5B

    static let maxNameBytes = 255
    static let maxDataBytes = 64 * 1024
    static let maxOpenTransfers = 4
    static let idleTimeout: TimeInterval = 60
    /// 2^53 - 1: the largest size a JSON number carries exactly.
    static let maxSize: UInt64 = (1 << 53) - 1

    /// FILE_ANSWER status.
    enum Answer {
        static let accept: UInt8 = 0
        static let declined: UInt8 = 1
        static let noRoom: UInt8 = 2
        static let tooMany: UInt8 = 3
        static let off: UInt8 = 4
    }

    /// FILE_END status.
    enum End {
        static let complete: UInt8 = 0
        static let cancelled: UInt8 = 1
        static let failed: UInt8 = 2
    }

    // MARK: encoders

    static func offer(id: UInt32, name: String, size: UInt64, modified: Int64? = nil) -> FileTransferMessage {
        var obj: [String: Any] = ["id": id, "name": name, "size": size]
        if let modified { obj["modified"] = modified }
        let json = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return FileTransferMessage(type: offerType, payload: json)
    }

    static func answer(id: UInt32, status: UInt8) -> FileTransferMessage {
        var p = Data(capacity: 5)
        p.appendBE(id)
        p.append(status)
        return FileTransferMessage(type: answerType, payload: p)
    }

    static func data(id: UInt32, bytes: Data) -> FileTransferMessage {
        var p = Data(capacity: 4 + bytes.count)
        p.appendBE(id)
        p.append(bytes)
        return FileTransferMessage(type: dataType, payload: p)
    }

    static func end(id: UInt32, status: UInt8) -> FileTransferMessage {
        var p = Data(capacity: 5)
        p.appendBE(id)
        p.append(status)
        return FileTransferMessage(type: endType, payload: p)
    }

    // MARK: decoders

    /// FILE_ANSWER and FILE_END payloads: id, status. Longer is accepted.
    static func decodeStatus(_ payload: Data) -> (id: UInt32, status: UInt8)? {
        guard payload.count >= 5 else { return nil }
        return (payload.beUInt32(at: 0), payload[payload.startIndex + 4])
    }

    /// FILE_DATA payload: id, then the bytes (possibly none).
    static func decodeData(_ payload: Data) -> (id: UInt32, bytes: Data)? {
        guard payload.count >= 4 else { return nil }
        return (payload.beUInt32(at: 0), Data(payload.dropFirst(4)))
    }

    // MARK: offers

    /// A JSON number that is a whole number, as a Double; nil for anything
    /// else (text, booleans, fractions, non-finite).
    private static func wholeNumber(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d == d.rounded(.towardZero) else { return nil }
        return d
    }

    static func parseOffer(_ payload: Data) -> FileOfferParse {
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let idValue = wholeNumber(obj["id"]),
              idValue >= 0, idValue <= Double(UInt32.max) else { return .ignore }
        let id = UInt32(idValue)
        guard let name = obj["name"] as? String,
              name.utf8.count <= maxNameBytes,
              let sizeValue = wholeNumber(obj["size"]),
              sizeValue >= 0, sizeValue <= Double(maxSize) else { return .decline(id: id) }
        var modified: Int64?
        if let m = wholeNumber(obj["modified"]), abs(m) <= Double(maxSize) {
            modified = Int64(m)
        }
        return .usable(FileOffer(id: id, name: name, size: UInt64(sizeValue), modified: modified))
    }

    // MARK: names

    /// Characters that look like `.`, `/` or `\` but are none of them: the
    /// full-width and small full stops, the one dot leader, the division,
    /// fraction, full-width and big solidus, the box diagonal, and the set
    /// minus and full-width reverse solidus.
    private static let lookAlikeSeparators: Set<UInt32> = [
        0xFF0E, 0xFE52, 0x2024, 0x2215, 0x2044, 0xFF0F, 0x29F8, 0x2571, 0x2216, 0xFF3C, 0xFE68, 0x29F5,
    ]

    /// The name a receiver stores for an offered name: what follows the last
    /// `/` or `\`, without control characters, `:` or Unicode format characters
    /// (category Cf: the bidirectional overrides and isolates U+202A..202E and
    /// U+2066..2069, the zero-width and direction marks U+200B..200F, U+FEFF and
    /// the like, which can make a name read as another one), without the line
    /// and paragraph separators U+2028 and U+2029 and the blank filler U+3164,
    /// with look-alike dots and slashes (U+FF0E, U+2215 and the like) replaced
    /// by `_`, without dots and blanks (Unicode spaces such as U+00A0 and
    /// U+3000 included) at the start or blanks at the end; `file` when nothing
    /// is left. Trailing dots are kept, as the shared test vectors say.
    static func storedName(for offered: String) -> String {
        var scalars = Array(offered.unicodeScalars)
        if let cut = scalars.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            scalars = Array(scalars[(cut + 1)...])
        }
        scalars.removeAll { u in
            switch u.value {
            case 0x00...0x1F, 0x7F...0x9F, 0x3A, 0x2028, 0x2029, 0x3164: return true
            default: return u.properties.generalCategory == .format
            }
        }
        scalars = scalars.map { lookAlikeSeparators.contains($0.value) ? "_" : $0 }
        func isBlank(_ u: Unicode.Scalar) -> Bool {
            u == " " || u.properties.isWhitespace || u.properties.generalCategory == .spaceSeparator
        }
        while let first = scalars.first, first == "." || isBlank(first) { scalars.removeFirst() }
        while let last = scalars.last, isBlank(last) { scalars.removeLast() }
        if scalars.isEmpty { return "file" }
        var s = String.UnicodeScalarView()
        s.append(contentsOf: scalars)
        return String(s)
    }

    /// `name` for n <= 1, otherwise the number goes before the extension (the
    /// part from the last dot on, unless that dot is the first or last
    /// character): `scan.pdf` -> `scan 2.pdf`.
    static func numberedName(_ name: String, _ n: Int) -> String {
        guard n > 1 else { return name }
        let units = Array(name.unicodeScalars)
        if let dot = units.lastIndex(of: "."), dot != 0, dot != units.count - 1 {
            var base = String.UnicodeScalarView(); base.append(contentsOf: units[..<dot])
            var ext = String.UnicodeScalarView(); ext.append(contentsOf: units[dot...])
            return "\(String(base)) \(n)\(String(ext))"
        }
        return "\(name) \(n)"
    }

    /// Like `numberedName`, but the result never exceeds `maxNameBytes` of
    /// UTF-8: the base name (before the extension) is shortened a character at
    /// a time until the numbered name fits.
    static func numberedNameFitting(_ name: String, _ n: Int) -> String {
        var result = numberedName(name, n)
        guard n > 1, result.utf8.count > maxNameBytes else { return result }
        var units = Array(name.unicodeScalars)
        var ext = String.UnicodeScalarView()
        if let dot = units.lastIndex(of: "."), dot != 0, dot != units.count - 1 {
            ext.append(contentsOf: units[dot...])
            units = Array(units[..<dot])
        }
        let suffix = " \(n)" + String(ext)
        var base = String.UnicodeScalarView()
        var used = suffix.utf8.count
        for u in units {
            let w = String(u).utf8.count
            if used + w > maxNameBytes { break }
            base.append(u)
            used += w
        }
        result = String(base) + suffix
        return result
    }

    /// The first of `name`, `name 2`, `name 3`, ... that `isTaken` does not
    /// report. Used for the decision only; a store must still claim the final
    /// name in one step that cannot replace a file.
    static func freeName(_ name: String, isTaken: (String) -> Bool) -> String {
        var n = 1
        while true {
            let candidate = numberedName(name, n)
            if !isTaken(candidate) { return candidate }
            n += 1
        }
    }
}

// MARK: - Receiver

/// Incoming transfers on one connection. Feed it the FILE_OFFER, FILE_DATA and
/// FILE_END messages the other side sends (only when the handshake set the
/// file transfer bit) and send back what it returns.
///
/// Note for the code that routes messages: FILE_END is the one type that goes
/// both ways, and ids are numbered separately per direction, so a FILE_END
/// carrying an id that is open in both directions cannot be told apart by the
/// wire format alone. This type only knows about incoming transfers.
final class FileReceiver {
    private struct Open {
        let size: UInt64
        var received: UInt64
        var lastActivity: TimeInterval
    }

    private let store: FileTransferStore
    private var open: [UInt32: Open] = [:]
    private var lastClosed: (id: UInt32, state: FileTransferState)?

    /// False answers every offer with status 4 ("transfers are turned off").
    var transfersEnabled: Bool

    init(store: FileTransferStore, transfersEnabled: Bool = true) {
        self.store = store
        self.transfersEnabled = transfersEnabled
    }

    var openCount: Int { open.count }

    /// `.open` while the transfer is open, the way it ended if it is the most
    /// recent one to end, nil otherwise.
    func state(of id: UInt32) -> FileTransferState? {
        if open[id] != nil { return .open }
        if let last = lastClosed, last.id == id { return last.state }
        return nil
    }

    /// Handle one incoming message; returns what to send back. Types other
    /// than offer, data and end are ignored.
    func receive(type: UInt8, payload: Data, now: TimeInterval) -> [FileTransferMessage] {
        switch type {
        case FileTransfer.offerType: return handleOffer(payload, now: now)
        case FileTransfer.dataType: return handleData(payload, now: now)
        case FileTransfer.endType: return handleEnd(payload)
        default: return []
        }
    }

    /// Fail every transfer that has received nothing for 60 s. Call it from a
    /// timer; the clock is the caller's.
    func tick(now: TimeInterval) -> [FileTransferMessage] {
        let stale = open.filter { now - $0.value.lastActivity >= FileTransfer.idleTimeout }.keys.sorted()
        return stale.flatMap { fail($0) }
    }

    /// The connection ended: nothing resumes, discard everything open.
    func closeAll() {
        for id in open.keys.sorted() {
            store.discard(id: id)
            lastClosed = (id, .failed)
        }
        open.removeAll()
    }

    // MARK: steps

    private func handleOffer(_ payload: Data, now: TimeInterval) -> [FileTransferMessage] {
        let offer: FileOffer
        switch FileTransfer.parseOffer(payload) {
        case .ignore:
            return []
        case let .decline(id):
            guard open[id] == nil else { return [] }
            return [FileTransfer.answer(id: id, status: transfersEnabled ? FileTransfer.Answer.declined : FileTransfer.Answer.off)]
        case let .usable(o):
            guard open[o.id] == nil else { return [] }
            offer = o
        }
        func reply(_ status: UInt8) -> [FileTransferMessage] { [FileTransfer.answer(id: offer.id, status: status)] }
        guard transfersEnabled else { return reply(FileTransfer.Answer.off) }
        guard open.count < FileTransfer.maxOpenTransfers else { return reply(FileTransfer.Answer.tooMany) }
        guard store.hasRoom(forBytes: offer.size) else { return reply(FileTransfer.Answer.noRoom) }
        guard store.begin(id: offer.id, storedName: FileTransfer.storedName(for: offer.name), size: offer.size) else {
            return reply(FileTransfer.Answer.noRoom)
        }
        open[offer.id] = Open(size: offer.size, received: 0, lastActivity: now)
        return reply(FileTransfer.Answer.accept)
    }

    private func handleData(_ payload: Data, now: TimeInterval) -> [FileTransferMessage] {
        guard let (id, bytes) = FileTransfer.decodeData(payload), var t = open[id] else { return [] }
        guard !bytes.isEmpty else { return [] }
        guard bytes.count <= FileTransfer.maxDataBytes,
              t.received + UInt64(bytes.count) <= t.size,
              store.write(id: id, bytes: bytes) else { return fail(id) }
        t.received += UInt64(bytes.count)
        t.lastActivity = now
        open[id] = t
        return []
    }

    private func handleEnd(_ payload: Data) -> [FileTransferMessage] {
        guard let (id, status) = FileTransfer.decodeStatus(payload), let t = open[id] else { return [] }
        switch status {
        case FileTransfer.End.complete:
            guard t.received == t.size, store.finish(id: id) else { return fail(id) }
            open[id] = nil
            lastClosed = (id, .stored)
            return [FileTransfer.end(id: id, status: FileTransfer.End.complete)]
        case FileTransfer.End.cancelled:
            close(id, as: .cancelled)
            return []
        default:
            close(id, as: .failed)
            return []
        }
    }

    private func close(_ id: UInt32, as state: FileTransferState) {
        store.discard(id: id)
        open[id] = nil
        lastClosed = (id, state)
    }

    /// Fail a transfer on our side: discard it and tell the sender.
    private func fail(_ id: UInt32) -> [FileTransferMessage] {
        close(id, as: .failed)
        return [FileTransfer.end(id: id, status: FileTransfer.End.failed)]
    }
}

// MARK: - Sender

enum FileSendOutcome: Equatable {
    case stored
    /// The receiver answered with this non-zero status.
    case declined(status: UInt8)
    case cancelled
    case failed
}

/// One outgoing transfer: offered, accepted, sending, ended. No I/O: the
/// caller reads the file, asks how many bytes to read next, and hands the
/// bytes back to get the message to send.
struct FileSender {
    enum Phase: Equatable {
        case offered
        case accepted
        case sending
        /// FILE_END 0 sent, waiting for the receiver to say it is stored.
        case finishing
        case ended(FileSendOutcome)
    }

    let id: UInt32
    let name: String
    let size: UInt64
    let modified: Int64?
    private(set) var phase: Phase = .offered
    private(set) var sent: UInt64 = 0

    init(id: UInt32, name: String, size: UInt64, modified: Int64? = nil) {
        self.id = id
        self.name = name
        self.size = size
        self.modified = modified
    }

    var isEnded: Bool { if case .ended = phase { return true } else { return false } }
    var allSent: Bool { sent == size }

    func offerMessage() -> FileTransferMessage {
        FileTransfer.offer(id: id, name: name, size: size, modified: modified)
    }

    /// How many bytes to read for the next FILE_DATA: at most `maxPiece` and
    /// 64 KB; 0 when nothing is to be sent now.
    func nextPieceLength(maxPiece: Int = FileTransfer.maxDataBytes) -> Int {
        guard phase == .accepted || phase == .sending else { return 0 }
        let remaining = size - sent
        return Int(min(UInt64(max(0, min(maxPiece, FileTransfer.maxDataBytes))), remaining))
    }

    /// The FILE_DATA for the next bytes of the file; nil if they do not fit
    /// the rules (wrong phase, empty, too big, past the offered size).
    mutating func pieceMessage(_ bytes: Data) -> FileTransferMessage? {
        guard phase == .accepted || phase == .sending,
              !bytes.isEmpty, bytes.count <= FileTransfer.maxDataBytes,
              sent + UInt64(bytes.count) <= size else { return nil }
        sent += UInt64(bytes.count)
        phase = .sending
        return FileTransfer.data(id: id, bytes: bytes)
    }

    /// FILE_END 0 once every byte is sent; nil before that.
    mutating func endMessage() -> FileTransferMessage? {
        guard phase == .accepted || phase == .sending, allSent else { return nil }
        phase = .finishing
        return FileTransfer.end(id: id, status: FileTransfer.End.complete)
    }

    /// Cancel from our side (FILE_END 1); nil if already over.
    mutating func cancel() -> FileTransferMessage? {
        guard !isEnded else { return nil }
        phase = .ended(.cancelled)
        return FileTransfer.end(id: id, status: FileTransfer.End.cancelled)
    }

    /// Fail from our side (FILE_END 2), for example when the file cannot be
    /// read; nil if already over.
    mutating func fail() -> FileTransferMessage? {
        guard !isEnded else { return nil }
        phase = .ended(.failed)
        return FileTransfer.end(id: id, status: FileTransfer.End.failed)
    }

    /// The receiver's FILE_ANSWER.
    mutating func handleAnswer(status: UInt8) {
        guard phase == .offered else { return }
        phase = status == FileTransfer.Answer.accept ? .accepted : .ended(.declined(status: status))
    }

    /// The receiver's FILE_END.
    mutating func handleEnd(status: UInt8) {
        guard !isEnded else { return }
        switch status {
        case FileTransfer.End.complete:
            if phase == .finishing { phase = .ended(.stored) } else { phase = .ended(.failed) }
        case FileTransfer.End.cancelled:
            phase = .ended(.cancelled)
        default:
            phase = .ended(.failed)
        }
    }

    /// The connection ended.
    mutating func connectionClosed() {
        if !isEnded { phase = .ended(.failed) }
    }
}
