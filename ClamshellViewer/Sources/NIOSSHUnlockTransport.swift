import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// The SSH side of "Unlock disk" on iOS, on SwiftNIO SSH (pinned in the project).
///
/// It connects to the Mac's pre-boot sshd, hands the server's host key to
/// `acceptHostKey` BEFORE any credential is offered, then offers the password once. macOS
/// ends the session by itself after a good password ("System successfully unlocked."), so
/// "the connection closed after we offered the password and it was not refused" counts as
/// signed in; a second request for credentials means the password was refused.
/// The password lives only in the auth delegate and is cleared when this returns.
final class NIOSSHUnlockTransport: SSHUnlockTransport {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<SSHAttempt, Never>?
        private var done = false
        var offered = false
        var declined = false
        var keySeen = false
        func set(_ c: CheckedContinuation<SSHAttempt, Never>) { lock.lock(); cont = c; lock.unlock() }
        func finish(_ r: SSHAttempt) {
            lock.lock(); defer { lock.unlock() }
            guard !done, let c = cont else { return }
            done = true; cont = nil; c.resume(returning: r)
        }
    }

    private final class PasswordDelegate: NIOSSHClientUserAuthenticationDelegate {
        let username: String
        var password: String?
        let state: State
        init(username: String, password: String, state: State) { self.username = username; self.password = password; self.state = state }
        func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                    nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
            guard !state.offered, let pw = password, availableMethods.contains(.password) else {
                nextChallengePromise.succeed(nil)
                state.finish(state.offered ? .authFailed : .failed)
                return
            }
            state.offered = true
            password = nil
            nextChallengePromise.succeed(.init(username: username, serviceName: "ssh-connection", offer: .password(.init(password: pw))))
        }
    }

    private final class KeyDelegate: NIOSSHClientServerAuthenticationDelegate {
        struct Declined: Error {}
        let state: State
        let accept: (String) async -> Bool
        init(state: State, accept: @escaping (String) async -> Bool) { self.state = state; self.accept = accept }
        func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
            let parts = String(openSSHPublicKey: hostKey).split(separator: " ")
            guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else {
                state.declined = true
                validationCompletePromise.fail(Declined())
                state.finish(.hostKeyRefused)
                return
            }
            state.keySeen = true
            let fingerprint = SSHFingerprint.sha256(ofKeyBlob: blob)
            let state = self.state, accept = self.accept
            Task {
                if await accept(fingerprint) {
                    validationCompletePromise.succeed(())
                } else {
                    state.declined = true
                    validationCompletePromise.fail(Declined())
                    state.finish(.hostKeyRefused)
                }
            }
        }
    }

    func attempt(host: String, port: Int, username: String, password: String,
                 connectTimeout: TimeInterval, acceptHostKey: @escaping (String) async -> Bool) async -> SSHAttempt {
        let state = State()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let auth = PasswordDelegate(username: username, password: password, state: state)
        let keys = KeyDelegate(state: state, accept: acceptHostKey)
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.milliseconds(Int64(connectTimeout * 1000)))
            .channelInitializer { channel in
                channel.pipeline.addHandler(NIOSSHHandler(
                    role: .client(.init(userAuthDelegate: auth, serverAuthDelegate: keys)),
                    allocator: channel.allocator, inboundChildChannelInitializer: nil))
            }
        let channel: Channel
        do { channel = try await bootstrap.connect(host: host, port: port).get() } catch {
            try? await group.shutdownGracefully()
            return .connectFailed
        }
        let result: SSHAttempt = await withCheckedContinuation { (cont: CheckedContinuation<SSHAttempt, Never>) in
            state.set(cont)
            channel.closeFuture.whenComplete { _ in
                // Closed: declined key or refused password were reported already (first call wins).
                state.finish(state.declined ? .hostKeyRefused : state.offered ? .authenticated : state.keySeen ? .failed : .connectFailed)
            }
            // A normal sshd (the Mac is already up) keeps the session open: opening a channel
            // proves the password worked.
            channel.pipeline.handler(type: NIOSSHHandler.self).whenSuccess { handler in
                let promise = channel.eventLoop.makePromise(of: Channel.self)
                handler.createChannel(promise) { child, _ in child.eventLoop.makeSucceededVoidFuture() }
                promise.futureResult.whenSuccess { _ in state.finish(.authenticated) }
            }
        }
        try? await channel.close()
        try? await group.shutdownGracefully()
        return result
    }
}
