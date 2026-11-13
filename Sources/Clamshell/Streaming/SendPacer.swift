import Foundation

/// Decides, per encoded video frame, whether to send it, drop it, or give up
/// on the connection. Pure state machine (no I/O, time is passed in) so the
/// rules are unit-tested; `StreamServer` owns one per session on its queue.
///
/// Rules:
/// - Above `softLimit` unsent frames, delta frames are dropped and a keyframe
///   is requested. Every later delta is dropped too until that keyframe goes
///   out: a delta that follows a dropped one refers to a picture the client
///   never received.
/// - Keyframes are let through up to `hardLimit`, then dropped as well, so a
///   stuck connection cannot queue video without bound.
/// - If frames are waiting and none has finished sending for `stallTimeout`
///   seconds, the connection is reported stalled so the session can be torn
///   down and the client can reconnect.
struct SendPacer {
    enum Decision: Equatable {
        case send
        /// Don't send. `requestKeyframe`: ask the encoder for a keyframe now.
        /// `congested`: the send queue was full (step the bitrate down).
        case drop(requestKeyframe: Bool, congested: Bool)
        case stalled
    }

    let softLimit: Int
    let hardLimit: Int
    let stallTimeout: TimeInterval
    /// How long to wait for a requested keyframe before asking again.
    let keyframeRetry: TimeInterval

    private(set) var inFlight = 0
    private(set) var awaitingKeyframe = false
    private var keyframeRequestedAt: TimeInterval?
    private var lastProgressAt: TimeInterval = 0

    init(softLimit: Int = 8, hardLimit: Int = 24,
         stallTimeout: TimeInterval = 15, keyframeRetry: TimeInterval = 1) {
        self.softLimit = softLimit
        self.hardLimit = max(hardLimit, softLimit)
        self.stallTimeout = stallTimeout
        self.keyframeRetry = keyframeRetry
    }

    /// Call for each encoded frame, before sending. On `.send` the frame is
    /// counted as in flight; pair it with one `completed(now:)`.
    mutating func offer(keyframe: Bool, now: TimeInterval) -> Decision {
        if inFlight == 0 {
            lastProgressAt = now
        } else if now - lastProgressAt >= stallTimeout {
            return .stalled
        }
        if keyframe {
            if inFlight >= hardLimit {
                awaitingKeyframe = true
                return .drop(requestKeyframe: markKeyframeRequest(now), congested: true)
            }
            awaitingKeyframe = false
            inFlight += 1
            return .send
        }
        if inFlight >= softLimit {
            let first = !awaitingKeyframe
            awaitingKeyframe = true
            return .drop(requestKeyframe: markKeyframeRequest(now, force: first), congested: true)
        }
        if awaitingKeyframe {
            return .drop(requestKeyframe: markKeyframeRequest(now), congested: false)
        }
        inFlight += 1
        return .send
    }

    /// Call when a frame counted by `.send` has been handed to the network.
    mutating func completed(now: TimeInterval) {
        inFlight = max(inFlight - 1, 0)
        lastProgressAt = now
    }

    mutating func reset() {
        inFlight = 0
        awaitingKeyframe = false
        keyframeRequestedAt = nil
        lastProgressAt = 0
    }

    /// True when a keyframe should be requested now: the first time, and
    /// again only if the last request is older than `keyframeRetry` (frames
    /// already in the encoder would otherwise each trigger another keyframe).
    private mutating func markKeyframeRequest(_ now: TimeInterval, force: Bool = false) -> Bool {
        if !force, let last = keyframeRequestedAt, now - last < keyframeRetry { return false }
        keyframeRequestedAt = now
        return true
    }
}
