import Foundation
import Network

// Finds Clamshell hosts on the local network by browsing Bonjour
// `_clamshell._tcp` (PROTOCOL.md "Discovery"). Everything learned here is a
// hint: a discovered host still has to pass the handshake once that exists.

final class NearbyHostBrowser: ObservableObject {
    struct Host: Identifiable, Equatable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
    }

    @Published private(set) var hosts: [Host] = []
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: NearbyHost.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found: [Host] = results.compactMap { result in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                var hint: String?
                if case let .bonjour(txt) = result.metadata { hint = txt["name"] }
                return Host(id: "\(result.endpoint)",
                            name: NearbyHost.label(hint: hint, serviceName: name),
                            endpoint: result.endpoint)
            }
            self?.hosts = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        b.stateUpdateHandler = { state in
            if case let .failed(error) = state { clogViewer("nearby browse failed: \(error)") }
        }
        browser = b
        b.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        hosts = []
    }

    /// Resolves a service to `ws://<ipv4>:<port>` by opening (and at once
    /// closing) a TCP connection to it. Completion runs on the main queue,
    /// with nil if the host did not answer within 5 s.
    func resolve(_ host: Host, completion: @escaping (String?) -> Void) {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let conn = NWConnection(to: host.endpoint, using: params)
        var finished = false
        func finish(_ url: String?) {
            guard !finished else { return }
            finished = true
            conn.cancel()
            completion(url)
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if case let .hostPort(h, p)? = conn.currentPath?.remoteEndpoint {
                    finish(NearbyHost.url(host: "\(h)", port: p.rawValue))
                } else {
                    finish(nil)
                }
            case .failed, .cancelled:
                finish(nil)
            default:
                break
            }
        }
        conn.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { finish(nil) }
    }
}
