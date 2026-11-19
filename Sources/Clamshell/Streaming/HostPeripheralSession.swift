import Foundation

// The Mac host's side of peripherals for one connection (PROTOCOL.md
// "Peripherals attached to the client"): the registry core, with a backend
// that turns game controllers into keys and pointer events through a
// `GamepadMapper`. MIDI and other kinds get status 2 (this host does not
// accept the kind). It exists only for a connection whose device set
// capability bit 6 and was let in; the code that owns the connection creates
// it then and nowhere else.

/// What is attached right now, across connections, for the menu bar app to
/// show and to remove from. Thread safe.
final class PeripheralHub {
    static let shared = PeripheralHub()

    struct Item: Equatable {
        let key: String
        let sessionId: UUID
        let id: UInt32
        let kind: String
        let name: String
        /// The device that brought it.
        let device: String
    }

    private let lock = NSLock()
    private var items: [Item] = []
    private var removers: [UUID: (UInt32) -> Void] = [:]

    /// Remembers how to remove a connection's peripherals. The closure may be
    /// called from any thread and must hand off to the connection's own queue.
    func register(session: UUID, remove: @escaping (UInt32) -> Void) {
        lock.lock(); defer { lock.unlock() }
        removers[session] = remove
    }

    func unregister(session: UUID) {
        lock.lock(); defer { lock.unlock() }
        removers.removeValue(forKey: session)
        items.removeAll { $0.sessionId == session }
    }

    func add(_ item: Item) {
        lock.lock(); defer { lock.unlock() }
        items.removeAll { $0.key == item.key }
        items.append(item)
    }

    func remove(session: UUID, id: UInt32) {
        lock.lock(); defer { lock.unlock() }
        items.removeAll { $0.sessionId == session && $0.id == id }
    }

    var attached: [Item] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    /// The user removed this one on the host: its connection answers status 5.
    func requestRemove(key: String) {
        lock.lock()
        let item = items.first { $0.key == key }
        let remover = item.flatMap { removers[$0.sessionId] }
        lock.unlock()
        if let item, let remover { remover(item.id) }
    }
}

final class HostPeripheralSession: PeripheralBackend {
    static let support = PeripheralHostSupport(gamepad: .keysAndPointer, midi: false)

    /// Whether a connection may attach peripherals at all: it was let in with
    /// a handshake (so it has a device) and that device set capability bit 6.
    static func allowed(phase: StreamLink.Phase, capabilities: StreamCapabilities?) -> Bool {
        phase == .accepted && (capabilities?.contains(.peripherals) ?? false)
    }

    let sessionId = UUID()
    private let registry: PeripheralRegistry
    private let mapper: GamepadMapper
    private let hub: PeripheralHub
    private let device: String
    private let enabled: () -> Bool
    private var lastTick: TimeInterval?

    /// `enabled` is asked before every message and tick, so turning
    /// peripherals off in the menu takes effect at once.
    init(device: String, output: GamepadOutput, mapping: GamepadMapping = .load(),
         hub: PeripheralHub = .shared, enabled: @escaping () -> Bool = { HostDeviceSettings.peripheralsEnabled }) {
        self.device = device
        self.hub = hub
        self.enabled = enabled
        self.mapper = GamepadMapper(output: output, mapping: mapping)
        self.registry = PeripheralRegistry(support: Self.support, enabled: enabled())
    }

    var attachedIds: [UInt32] { registry.attachedIds }
    var heldCount: Int { mapper.heldCount }

    /// One PERIPHERAL_* message from the client; returns the framed replies.
    /// Types the host does not read from a client are ignored.
    func receive(type: UInt8, payload: Data, now: TimeInterval) -> [Data] {
        switch type {
        case Peripheral.attachType, Peripheral.inputType, Peripheral.detachType: break
        default: return []
        }
        var out = syncEnabled()
        out += registry.run(registry.receive(type: type, payload: payload, now: now), on: self)
        return out.map(\.frame)
    }

    /// Moves the pointer for the time since the last call, rests silent
    /// controllers, and follows the on/off setting.
    func tick(now: TimeInterval) -> [Data] {
        var out = syncEnabled()
        out += registry.run(registry.tick(now: now), on: self)
        if let last = lastTick { mapper.tick(dt: now - last) }
        lastTick = now
        return out.map(\.frame)
    }

    /// The user removed one in the menu bar app: status 5.
    func removeByHost(id: UInt32) -> [Data] {
        registry.run(registry.removeByHost(id: id), on: self).map(\.frame)
    }

    /// The connection ended: everything is released and removed.
    func closeAll() {
        _ = registry.run(registry.closeAll(), on: self)
        mapper.releaseAll()
        hub.unregister(session: sessionId)
    }

    private func syncEnabled() -> [PeripheralMessage] {
        let on = enabled()
        guard on != registry.enabled else { return [] }
        return registry.run(registry.setEnabled(on), on: self)
    }

    // MARK: PeripheralBackend

    func create(id: UInt32, kind: PeripheralKind, name: String, mode: PeripheralMode,
                rumble: Bool, sends: Bool, receives: Bool) -> Bool {
        guard kind == .gamepad, mode == .keysAndPointer else { return false }
        hub.add(PeripheralHub.Item(key: "\(sessionId)-\(id)", sessionId: sessionId, id: id,
                                   kind: kind.rawValue, name: name, device: device))
        return true
    }

    func apply(id: UInt32, state: GamepadState) { mapper.apply(id: id, state: state) }

    func deliverMIDI(id: UInt32, bytes: Data) {}

    func remove(id: UInt32) {
        mapper.remove(id: id)
        hub.remove(session: sessionId, id: id)
    }
}
