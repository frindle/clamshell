import UIKit
import GameController
import Combine

// Sends the game controllers connected to this device to the Mac, over the
// primary connection. The Mac turns them into keys and pointer movement (it
// has no virtual controller). What goes on the wire is decided in
// ControllerClient (shared, tested); this reads the controllers.
//
// A controller drives the Mac and nothing here: Info.plist turns off
// GCSupportsControllerUserInteraction, so it does not move around this app's
// own screens, and PointerLock works with GCMouse, which this does not touch.
// Everything runs on the main thread (GameController calls handlers there).

final class GameControllerBridge: ObservableObject {
    static let shared = GameControllerBridge()

    /// Each attached controller and what the Mac said about it.
    @Published private(set) var rows: [ControllerRow] = []

    private let core = ControllerClient()
    private weak var client: StreamClient?
    private var ids: [ObjectIdentifier: UInt32] = [:]
    /// The connection is up and the Mac takes controllers.
    private var attached = false
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    func start(client: StreamClient) {
        guard self.client == nil else { return }
        self.client = client

        client.onPeripheralStatus = { [weak self] payload in
            DispatchQueue.main.async {
                guard let self else { return }
                self.core.receiveStatus(payload)
                self.rows = self.core.rows
            }
        }
        client.$hostCapabilities
            .receive(on: DispatchQueue.main)
            .sink { [weak self] caps in self?.hostChanged(takes: caps.contains(.peripherals)) }
            .store(in: &cancellables)

        let nc = NotificationCenter.default
        nc.publisher(for: .GCControllerDidConnect).receive(on: DispatchQueue.main)
            .sink { [weak self] note in if let c = note.object as? GCController { self?.connected(c) } }
            .store(in: &cancellables)
        nc.publisher(for: .GCControllerDidDisconnect).receive(on: DispatchQueue.main)
            .sink { [weak self] note in if let c = note.object as? GCController { self?.gone(c) } }
            .store(in: &cancellables)
        // About to stop reading the controllers: leave them at rest on the Mac.
        nc.publisher(for: UIApplication.willResignActiveNotification).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sendRest() }
            .store(in: &cancellables)

        for c in GCController.controllers() { connected(c) }

        let t = Timer(timeInterval: 0.016, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: connection

    private func hostChanged(takes: Bool) {
        if takes && !attached {
            attached = true
            for m in core.reconnect() { send(m) }
            rows = core.rows
        } else if !takes && attached {
            attached = false
        }
    }

    private func send(_ m: PeripheralMessage) {
        guard attached else { return }
        client?.sendFrame(m.frame)
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func tick() {
        guard attached else { return }
        for m in core.tick(now: now) { send(m) }
    }

    private func sendRest() {
        guard attached else { return }
        for m in core.restReports(now: now) { send(m) }
    }

    // MARK: controllers

    private func connected(_ controller: GCController) {
        // Remotes and other controllers without a full gamepad are not sent.
        guard let pad = controller.extendedGamepad, ids[ObjectIdentifier(controller)] == nil else { return }
        let name = controller.vendorName ?? controller.productCategory
        let (id, attach) = core.connect(name: name)
        ids[ObjectIdentifier(controller)] = id
        send(attach)
        pad.valueChangedHandler = { [weak self] pad, _ in self?.changed(id, pad) }
        rows = core.rows
        changed(id, pad)
    }

    private func gone(_ controller: GCController) {
        guard let id = ids.removeValue(forKey: ObjectIdentifier(controller)) else { return }
        controller.extendedGamepad?.valueChangedHandler = nil
        if let m = core.disconnect(id: id) { send(m) }
        rows = core.rows
    }

    private func changed(_ id: UInt32, _ pad: GCExtendedGamepad) {
        var s = ControllerSnapshot()
        s.a = pad.buttonA.isPressed
        s.b = pad.buttonB.isPressed
        s.x = pad.buttonX.isPressed
        s.y = pad.buttonY.isPressed
        s.leftShoulder = pad.leftShoulder.isPressed
        s.rightShoulder = pad.rightShoulder.isPressed
        s.view = pad.buttonOptions?.isPressed ?? false
        s.menu = pad.buttonMenu.isPressed
        s.leftStickButton = pad.leftThumbstickButton?.isPressed ?? false
        s.rightStickButton = pad.rightThumbstickButton?.isPressed ?? false
        s.up = pad.dpad.up.isPressed
        s.down = pad.dpad.down.isPressed
        s.left = pad.dpad.left.isPressed
        s.right = pad.dpad.right.isPressed
        s.home = pad.buttonHome?.isPressed ?? false
        s.leftTrigger = pad.leftTrigger.value
        s.rightTrigger = pad.rightTrigger.value
        s.leftX = pad.leftThumbstick.xAxis.value
        s.leftY = pad.leftThumbstick.yAxis.value
        s.rightX = pad.rightThumbstick.xAxis.value
        s.rightY = pad.rightThumbstick.yAxis.value
        if let m = core.input(id: id, s, now: now) { send(m) }
    }
}
