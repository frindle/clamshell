import DeskProtocol
import DeskStubs

/// What the stub must post. The stub process is the poster, so the banner shows the stub's icon and name.
public struct PostRequest: Equatable {
    public var hostedBundleId: String
    public var stubBundleId: String
    public var notificationId: String
    public var title: String
    public var subtitle: String
    public var body: String
    public var sound: Bool

    public init(hostedBundleId: String, stubBundleId: String, notificationId: String, title: String, subtitle: String, body: String, sound: Bool) {
        self.hostedBundleId = hostedBundleId; self.stubBundleId = stubBundleId; self.notificationId = notificationId
        self.title = title; self.subtitle = subtitle; self.body = body; self.sound = sound
    }
}

public enum DropReason: Equatable {
    /// The operator has no stub for this app.
    case notHosted
    /// The app id was never announced.
    case unknownApp
    case duplicate
    /// The app's window is already in front on the operator.
    case focused
    case doNotDisturb
    case rateLimited
}

public enum GateDecision: Equatable {
    case post(PostRequest)
    case drop(DropReason)
}

/// Posts under a stub's identity. The real one runs inside the stub process (see the PR notes).
public protocol NotificationPoster {
    func post(_ request: PostRequest) throws
}

/// Sets the Dock badge text of a stub. Empty text clears it.
public protocol BadgeSetter {
    func setBadge(stubBundleId: String, text: String) throws
}

/// What the operator knows about the screen right now.
public protocol OperatorContext {
    /// True when a window of this hosted app is the frontmost on the operator.
    func isFocused(hostedBundleId: String) -> Bool
    var doNotDisturb: Bool { get }
}

/// The host's app numbering as the operator learned it from APP_LIST.
public protocol HostedAppDirectory {
    func bundleId(forAppId appId: UInt32) -> String?
}

public struct GateConfig: Equatable {
    public var perAppLimit = 5
    public var perAppWindow = 10.0
    public var globalLimit = 20
    public var globalWindow = 10.0
    /// A notification id seen within this many seconds is a duplicate.
    public var idTTL = 600.0
    /// The same app, title, subtitle and body within this many seconds is a duplicate.
    public var contentWindow = 5.0
    /// Upper bound for the dedupe tables.
    public var maxRemembered = 2048
    public init() {}
}

/// Operator side, pure logic: should this NOTIFY be re-posted?
/// Order of checks: known app, hosted app, duplicate, focus, Do Not Disturb, rate limit.
/// Suppressed notifications still count as seen, so they are not posted later.
public final class NotificationGate {
    public var hosted: Set<String>
    private let directory: HostedAppDirectory
    private let context: OperatorContext
    private let config: GateConfig
    private var ids: [String: Double] = [:]
    private var contents: [String: Double] = [:]
    private var perApp: [String: [Double]] = [:]
    private var global: [Double] = []

    public init(hosted: Set<String>, directory: HostedAppDirectory, context: OperatorContext, config: GateConfig = GateConfig()) {
        self.hosted = hosted; self.directory = directory; self.context = context; self.config = config
    }

    /// The stub for a hosted app. Uses the generator's rule so the two never drift apart.
    public static func stubBundleId(for hostedBundleId: String) -> String {
        StubGenerator.stubBundleId(for: hostedBundleId)
    }

    public func decide(appId: UInt32, notificationId: String, title: String, subtitle: String, body: String,
                       sound: Bool, now: Double) -> GateDecision {
        guard let bundle = directory.bundleId(forAppId: appId) else { return .drop(.unknownApp) }
        guard hosted.contains(bundle) else { return .drop(.notHosted) }

        let idKey = bundle + "\n" + notificationId
        let contentKey = [bundle, title, subtitle, body].joined(separator: "\n")
        let dup = (ids[idKey].map { now - $0 <= config.idTTL } ?? false)
            || (contents[contentKey].map { now - $0 <= config.contentWindow } ?? false)
        ids[idKey] = now
        contents[contentKey] = now
        prune(now: now)
        if dup { return .drop(.duplicate) }

        if context.isFocused(hostedBundleId: bundle) { return .drop(.focused) }
        if context.doNotDisturb { return .drop(.doNotDisturb) }

        var appTimes = (perApp[bundle] ?? []).filter { now - $0 < config.perAppWindow }
        global = global.filter { now - $0 < config.globalWindow }
        if appTimes.count >= config.perAppLimit || global.count >= config.globalLimit {
            perApp[bundle] = appTimes
            return .drop(.rateLimited)
        }
        appTimes.append(now); global.append(now)
        perApp[bundle] = appTimes

        return .post(PostRequest(hostedBundleId: bundle, stubBundleId: Self.stubBundleId(for: bundle),
                                 notificationId: notificationId, title: title, subtitle: subtitle, body: body, sound: sound))
    }

    private func prune(now: Double) {
        guard ids.count > config.maxRemembered || contents.count > config.maxRemembered else { return }
        ids = trimmed(ids.filter { now - $0.value <= config.idTTL })
        contents = trimmed(contents.filter { now - $0.value <= config.contentWindow })
    }

    private func trimmed(_ d: [String: Double]) -> [String: Double] {
        guard d.count > config.maxRemembered else { return d }
        let keep = d.sorted { $0.value > $1.value }.prefix(config.maxRemembered / 2)
        var out: [String: Double] = [:]
        for (k, v) in keep { out[k] = v }
        return out
    }
}

public enum BridgeResult: Equatable {
    case posted(PostRequest)
    case dropped(DropReason)
    case badgeSet(stubBundleId: String, text: String)
    /// A message this bridge does not handle.
    case ignored
    /// The poster or badge setter threw.
    case failed
}

/// Operator side: feeds NOTIFY and BADGE messages through the gate to the poster and badge setter.
public final class OperatorBridge {
    public let gate: NotificationGate
    private let directory: HostedAppDirectory
    private let poster: NotificationPoster
    private let badges: BadgeSetter
    private let log: LogSink

    public init(gate: NotificationGate, directory: HostedAppDirectory, poster: NotificationPoster, badges: BadgeSetter,
                log: @escaping LogSink = { _ in }) {
        self.gate = gate; self.directory = directory; self.poster = poster; self.badges = badges; self.log = log
    }

    public func handle(_ message: DeskMessage, now: Double) -> BridgeResult {
        switch message {
        case .notify(let appId, let nid, let title, let sub, let body, let sound):
            switch gate.decide(appId: appId, notificationId: nid, title: title, subtitle: sub, body: body, sound: sound, now: now) {
            case .drop(let r): return .dropped(r)
            case .post(let req):
                do { try poster.post(req); return .posted(req) } catch {
                    log("notify: post failed for \(req.stubBundleId)")
                    return .failed
                }
            }
        case .badge(let appId, let text):
            guard let bundle = directory.bundleId(forAppId: appId) else { return .dropped(.unknownApp) }
            guard gate.hosted.contains(bundle) else { return .dropped(.notHosted) }
            let stub = NotificationGate.stubBundleId(for: bundle)
            do { try badges.setBadge(stubBundleId: stub, text: text); return .badgeSet(stubBundleId: stub, text: text) } catch {
                log("badge: set failed for \(stub)")
                return .failed
            }
        default:
            return .ignored
        }
    }
}
