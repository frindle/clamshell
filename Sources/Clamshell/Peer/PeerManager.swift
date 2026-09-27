import AppKit

// Wires the peer link to the shared-desk features on this Mac: the edge tap
// (this Mac controls the peer), the input sink (the peer controls this Mac),
// clipboard sync, file transfer and window handoff. PeerLink owns transport
// and identity only; everything feature-specific is routed from here.
//
// Used by both the menu bar app (Shared Desk submenu) and the headless
// `clamshell peer` command. Main-thread confined; PeerLink callbacks hop here.

final class PeerManager {
    let identity: PeerIdentity
    let trust: PeerTrustStore
    let link: PeerLink
    let edgeController: EdgeController
    let sink = RemoteInputSink()
    private(set) var state: PeerLinkState = .idle
    private(set) var discovered: [DiscoveredPeer] = []
    /// Linked peer's primary screen, in its input units.
    private(set) var peerScreen: CGSize?
    private(set) var peerHost: String?
    private(set) var peerName: String?
    /// Any UI (menu, CLI) re-reads state from here.
    var onChange: () -> Void = {}
    /// Feature modules, attached by PeerFeatures.install.
    var clipboard: PeerClipboard?
    var files: FileTransfer?
    var handoff: HandoffManager?
    private var autoConnect = true
    private var reconnectWork: DispatchWorkItem?

    static var configuredEdge: PeerEdge {
        get {
            guard let raw = UserDefaults.standard.object(forKey: "peerEdgeRaw") as? Int else { return .right }
            return PeerEdge(rawValue: UInt8(clamping: raw)) ?? .right
        }
        set { UserDefaults.standard.set(Int(newValue.rawValue), forKey: "peerEdgeRaw") }
    }

    init(identity: PeerIdentity, trust: PeerTrustStore, name: String,
         port: UInt16 = peerLinkDefaultPort, edge: PeerEdge = PeerManager.configuredEdge) {
        self.identity = identity
        self.trust = trust
        self.link = PeerLink(identity: identity, trust: trust, localName: name, port: port) {
            let b = CGDisplayBounds(CGMainDisplayID())
            return (UInt32(max(b.width, 1)), UInt32(max(b.height, 1)))
        }
        self.edgeController = EdgeController(edge: edge)
        wire()
    }

    /// The per-install identity and trust store in Application Support.
    /// CLAMSHELL_PEER_DIR overrides the directory (tests, or a second
    /// identity on one machine).
    static func makeDefault(port: UInt16 = peerLinkDefaultPort) throws -> PeerManager {
        let dir = ProcessInfo.processInfo.environment["CLAMSHELL_PEER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? PeerIdentity.defaultDirectory
        let identity = try PeerIdentity(fileURL: dir.appendingPathComponent("peer-identity.key"))
        let trust = PeerTrustStore(fileURL: dir.appendingPathComponent("peer-trust.json"))
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return PeerManager(identity: identity, trust: trust, name: name, port: port)
    }

    private func wire() {
        link.onStateChange = { [weak self] s in
            let host = self?.link.remoteHost
            DispatchQueue.main.async { self?.linkStateChanged(s, host: host) }
        }
        link.onDiscoveredChange = { [weak self] list in
            DispatchQueue.main.async {
                self?.discovered = list
                self?.maybeAutoConnect()
                self?.onChange()
            }
        }
        link.onMessage = { [weak self] type, payload in
            DispatchQueue.main.async { self?.route(type: type, payload: payload) }
        }
        edgeController.send = { [weak self] data in self?.link.send(data) }
        edgeController.peerSize = { [weak self] in self?.peerScreen }
        edgeController.onControlChange = { [weak self] _ in self?.onChange() }
        sink.onActiveChange = { [weak self] _ in self?.onChange() }
    }

    func start(advertise: Bool = true) throws {
        try link.startListening(advertise: advertise)
        if advertise { link.startBrowsing() }
        if !edgeController.start() {
            clog("PEER: edge tap unavailable — this Mac can be controlled but can't control the peer until Accessibility is granted")
        }
        clog("PEER: pairing PIN for this Mac: \(link.pairingPIN)")
    }

    func stop(completion: @escaping () -> Void = {}) {
        reconnectWork?.cancel()
        edgeController.stop()
        sink.reset()
        link.stop(completion: completion)
    }

    func connect(to peer: DiscoveredPeer, pin: String?) {
        autoConnect = true
        link.connect(to: peer, pin: pin)
    }

    func connect(host: String, port: UInt16, pin: String?) {
        autoConnect = true
        link.connect(host: host, port: port, pin: pin)
    }

    func disconnect() {
        autoConnect = false
        link.disconnect()
    }

    func setEdge(_ e: PeerEdge) {
        PeerManager.configuredEdge = e
        edgeController.edge = e
        onChange()
    }

    // MARK: - Link state

    private func linkStateChanged(_ s: PeerLinkState, host: String?) {
        let wasLinked = state.isLinked
        state = s
        if case .linked(let info, let w, let h) = s {
            peerScreen = CGSize(width: CGFloat(w), height: CGFloat(h))
            peerHost = host
            peerName = info.name
            linked()
        } else if wasLinked {
            peerScreen = nil
            peerName = nil
            unlinked()
            scheduleReconnect()
        } else if case .failed = s {
            scheduleReconnect()
        }
        onChange()
    }

    /// Hooks for the features added in later slices (clipboard, files,
    /// handoff) — kept as overridable closures so each lives in its own file.
    var featureLinked: [() -> Void] = []
    var featureUnlinked: [() -> Void] = []
    var featureRoutes: [(StreamMessageType, Data) -> Bool] = []

    private func linked() {
        featureLinked.forEach { $0() }
    }

    private func unlinked() {
        edgeController.returnHome(fraction: 0.5, notifyPeer: false)
        sink.reset()
        featureUnlinked.forEach { $0() }
    }

    // MARK: - Auto (re)connect to trusted peers

    /// Only the side with the smaller peer id dials, so two Macs that both
    /// see each other don't cross-connect and knock each other's link down.
    private func maybeAutoConnect() {
        guard autoConnect, !state.isLinked else { return }
        if case .connecting = state { return }
        if case .handshaking = state { return }
        for p in discovered {
            guard let id = p.id, trust.peer(id: id) != nil, identity.id < id else { continue }
            clog("PEER: auto-connecting to trusted \(p.name)")
            link.connect(to: p, pin: nil)
            return
        }
    }

    private func scheduleReconnect() {
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.maybeAutoConnect() }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    // MARK: - Message routing

    private func route(type: StreamMessageType, payload: Data) {
        switch type {
        case .edgeEnter:
            guard let e = PeerParse.edgeEnter(payload) else { return }
            // Both sides can't drive each other at once: whoever crossed
            // last wins, and our own crossing (if any) is abandoned.
            edgeController.returnHome(fraction: 0.5, notifyPeer: false)
            sink.enter(e)
        case .edgeLeave:
            let (carry, fraction) = sink.leave()
            if let carry { onPeerLeftCarrying?(carry, sink.entryEdge.opposite, fraction) }
        case .mouseMove, .mouseButton, .key, .scroll:
            sink.handle(type: type, payload: payload)
        default:
            for r in featureRoutes where r(type, payload) { return }
        }
    }

    /// The peer's cursor left this Mac while its (injected) button was
    /// carrying something here — hand it over (files / window handoff).
    var onPeerLeftCarrying: ((Carry, _ peerEdge: PeerEdge, _ fraction: CGFloat) -> Void)?

    var statusLine: String {
        switch state {
        case .idle: return "Not linked"
        case .connecting(let n): return "Connecting to \(n)…"
        case .handshaking(let n): return "Pairing with \(n)…"
        case .linked(let info, _, _):
            if edgeController.isControllingPeer { return "Controlling \(info.name)" }
            if sink.active { return "\(info.name) is controlling this Mac" }
            return "Linked with \(info.name)"
        case .failed(let why): return "Link failed: \(why)"
        }
    }
}
