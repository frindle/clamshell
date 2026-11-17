import Foundation

// The Mac host's side of file transfer for one connection (PROTOCOL.md "File
// transfer"): the receiver core, writing into the Downloads/Clamshell folder.
// It exists only for a connection whose device set capability bit 5 and was
// let in; the code that owns the connection creates it then and nowhere else.
// The host never starts a transfer to the client in this version: it answers
// nothing the client could take for an offer of its own, and a FILE_ANSWER or
// a FILE_END for a transfer that is not open is ignored by the receiver.

final class HostFileSession {
    private let receiver: FileReceiver
    private let sink: DiskFileSink
    private let enabled: () -> Bool
    private let onStored: (URL) -> Void

    /// `enabled` is asked before every message, so turning transfers off in
    /// the menu takes effect for the next offer. `onStored` is told the final
    /// URL of each file that has arrived complete.
    init(sink: DiskFileSink = DiskFileSink(),
         enabled: @escaping () -> Bool = { HostDeviceSettings.filesEnabled },
         onStored: @escaping (URL) -> Void) {
        self.sink = sink
        self.receiver = FileReceiver(store: sink, transfersEnabled: enabled())
        self.enabled = enabled
        self.onStored = onStored
    }

    /// Whether a connection may transfer files at all: it was let in with a
    /// handshake (so it has a device) and that device set capability bit 5.
    /// A waiting, clear or closed connection never does.
    static func allowed(phase: StreamLink.Phase, capabilities: StreamCapabilities?) -> Bool {
        phase == .accepted && (capabilities?.contains(.fileTransfer) ?? false)
    }

    var openCount: Int { receiver.openCount }

    /// One FILE_* message from the client; returns the messages to send back,
    /// already framed. Other types are ignored.
    func receive(type: UInt8, payload: Data, now: TimeInterval) -> [Data] {
        switch type {
        case FileTransfer.offerType, FileTransfer.dataType, FileTransfer.endType: break
        default: return []
        }
        receiver.transfersEnabled = enabled()
        let out = receiver.receive(type: type, payload: payload, now: now)
        for message in out where message.type == FileTransfer.endType {
            if let (_, status) = FileTransfer.decodeStatus(message.payload),
               status == FileTransfer.End.complete, let url = sink.lastStoredURL {
                onStored(url)
            }
        }
        return out.map(\.frame)
    }

    /// Fails transfers that have received nothing for 60 s; returns what to send.
    func tick(now: TimeInterval) -> [Data] {
        receiver.tick(now: now).map(\.frame)
    }

    /// The connection ended: every transfer still open is discarded, so no
    /// partial file stays behind.
    func closeAll() {
        receiver.closeAll()
    }
}
