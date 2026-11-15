import UIKit
import GameController
import ObjectiveC

// Pointer lock for a hardware mouse or trackpad: the iPad pointer is hidden and
// frozen and its raw movement goes to the host as INPUT_MOUSE_RELATIVE.
// Offered only when the host advertises `relativeMouse`.
//
// SwiftUI's hosting controller offers no pointer-lock API, so the window's
// root view controller class gets a `prefersPointerLocked` implementation that
// reads `PointerLock.isLocked`.

final class PointerLock: ObservableObject {
    static let shared = PointerLock()

    @Published private(set) var isLocked = false
    private weak var client: StreamClient?
    private var engaged = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] _ in
            self?.attachMouseHandlers()
        })
        // The system can end a lock (for example when the app loses focus):
        // follow it so the button reflects reality.
        observers.append(nc.addObserver(forName: UIPointerLockState.didChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, self.isLocked else { return }
            // The scene arrives in userInfo, not as the notification object.
            guard let scene = note.userInfo?[UIPointerLockState.sceneUserInfoKey] as? UIScene,
                  let state = scene.pointerLockState else { return }
            if state.isLocked { self.engaged = true } else if self.engaged { self.set(false, client: nil) }
        })
    }

    /// Shown briefly when iPadOS declines to lock the pointer.
    @Published private(set) var notice: String?
    private var generation = 0

    func set(_ on: Bool, client: StreamClient?) {
        if on == isLocked { return }
        isLocked = on
        engaged = false
        generation += 1
        self.client = on ? client : nil
        if on { Self.installOverride() }
        attachMouseHandlers()
        Self.rootViewController()?.setNeedsUpdateOfPrefersPointerLocked()
        if on { checkGranted(generation) }
    }

    /// iPadOS grants a lock only to a window that fills the screen. If it has
    /// not locked a second after asking, give up and say why.
    private func checkGranted(_ gen: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.generation == gen, self.isLocked else { return }
            let scene = Self.rootViewController()?.view.window?.windowScene
            if scene?.pointerLockState?.isLocked == true { return }
            self.set(false, client: nil)
            self.notice = "iPadOS did not lock the pointer. Try with the window filling the screen."
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.notice = nil
            }
        }
    }

    private func attachMouseHandlers() {
        for mouse in GCMouse.mice() {
            if isLocked {
                mouse.mouseInput?.mouseMovedHandler = { [weak self] _, dx, dy in
                    guard let d = PointerButtons.relativeDelta(dx: dx, dy: dy) else { return }
                    self?.client?.sendMouseRelative(dx: d.dx, dy: d.dy)
                }
            } else {
                mouse.mouseInput?.mouseMovedHandler = nil
            }
        }
    }

    private static func rootViewController() -> UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })?.rootViewController
    }

    private static var installedClasses = Set<ObjectIdentifier>()

    private static func installOverride() {
        guard let vc = rootViewController() else { return }
        let cls: AnyClass = type(of: vc)
        guard installedClasses.insert(ObjectIdentifier(cls)).inserted else { return }
        let block: @convention(block) (AnyObject) -> Bool = { _ in PointerLock.shared.isLocked }
        let imp = imp_implementationWithBlock(block)
        class_replaceMethod(cls, #selector(getter: UIViewController.prefersPointerLocked), imp, "B@:")
    }
}
