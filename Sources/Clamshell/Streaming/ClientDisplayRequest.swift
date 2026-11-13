import Foundation

/// What a client asks the Mac's virtual display to be, parsed from the
/// trailing bytes of HELLO or from CLIENT_DISPLAYS (PROTOCOL.md "Client
/// display reporting"). Pure, so `swift test` covers the wire format.
struct ClientDisplayRequest: Equatable {
    /// Largest size the host will build or encode. Bigger requests are
    /// clamped, not refused: the client's picker can offer sizes (5120x1440 at
    /// 2x) that no hardware encoder can take.
    static let maxWidthPx: UInt32 = 7680
    static let maxHeightPx: UInt32 = 4320
    static let minWidthPx: UInt32 = 640
    static let minHeightPx: UInt32 = 480

    var widthPx: UInt32
    var heightPx: UInt32
    /// flags bit 0: a second display surface is attached.
    var secondDisplay: Bool
    var secondWidthPx: UInt32?
    var secondHeightPx: UInt32?
    /// flags bit 1: the client wants a plain 1x display (pixels == points)
    /// instead of the default HiDPI one (pixels == 2 x points). It is how the
    /// browser's Retina toggle reaches the host. Hosts older than 0.9.22
    /// ignore the bit and build a HiDPI display of the same pixel size.
    var oneX: Bool

    /// nil when the payload is too short or the size is below the host's
    /// minimum (the same rule the host has always applied).
    static func parse(_ payload: Data, at offset: Int) -> ClientDisplayRequest? {
        guard payload.count >= offset + 9 else { return nil }
        let w = payload.beUInt32(at: offset), h = payload.beUInt32(at: offset + 4)
        let flags = payload[payload.startIndex + offset + 8]
        guard w >= minWidthPx, h >= minHeightPx else { return nil }
        var req = ClientDisplayRequest(
            widthPx: min(w, maxWidthPx), heightPx: min(h, maxHeightPx),
            secondDisplay: flags & 1 == 1, secondWidthPx: nil, secondHeightPx: nil,
            oneX: flags & 2 == 2)
        // Optional trailing Display B size, present only with a second display.
        if req.secondDisplay, payload.count >= offset + 17 {
            let bw = payload.beUInt32(at: offset + 9), bh = payload.beUInt32(at: offset + 13)
            if bw >= minWidthPx, bh >= minHeightPx {
                req.secondWidthPx = min(bw, maxWidthPx)
                req.secondHeightPx = min(bh, maxHeightPx)
            }
        }
        return req
    }

    /// The `collapse` notification's userInfo for this request.
    var userInfo: [String: String] {
        var info: [String: String] = [
            "width": String(widthPx), "height": String(heightPx),
            "external": secondDisplay ? "1" : "0", "source": "stream",
            "scale": oneX ? "1" : "2",
        ]
        if let bw = secondWidthPx, let bh = secondHeightPx {
            info["widthB"] = String(bw); info["heightB"] = String(bh)
        }
        return info
    }

    /// Virtual display preset for a pixel size. Odd sizes are floored to even
    /// so points * scale == pixels. `scale` is "1" for a plain display; any
    /// other value (or none) means HiDPI, as before 0.9.22.
    static func preset(name: String, widthPx: UInt32, heightPx: UInt32, scale: String?) -> DisplayPreset {
        let s: UInt32 = scale == "1" ? 1 : 2
        let ew = widthPx & ~1, eh = heightPx & ~1
        return DisplayPreset(name: name, pointsWide: ew / s, pointsHigh: eh / s, scale: s)
    }
}

/// Decides whether a live capture session must be rebuilt because the display
/// it captures changed pixel size (the browser picked another monitor size or
/// the window was resized). Pure so the rule is tested.
enum SessionResize {
    enum Action: Equatable {
        case keep
        case rebuild(widthPx: Int, heightPx: Int)
    }

    static func decide(sessionWidthPx: Int, sessionHeightPx: Int,
                       displayWidthPx: Int?, displayHeightPx: Int?) -> Action {
        guard let w = displayWidthPx, let h = displayHeightPx, w > 0, h > 0 else { return .keep }
        if w == sessionWidthPx && h == sessionHeightPx { return .keep }
        return .rebuild(widthPx: w, heightPx: h)
    }
}
