# Clamshell Stream Protocol (v1)

Custom LAN streaming protocol replacing browser VNC: ScreenCaptureKit capture →
VideoToolbox hardware encode on the Mac → TCP → VideoToolbox hardware decode on
the iPad. Phase 1 is a single-display walking skeleton.

## Displays

The host serves one WebSocket endpoint **per display**, at `basePort + index`
(main display = index 0 = base port). Each is an independent
capture→encode→stream pipeline with its own `SCStream` + `VTCompressionSession`.
Only the primary (index 0) endpoint carries audio and clipboard. The iPad
client connects Display A (index 0) to its own screen and, when a physical
external screen is attached, connects Display B (index 1) to that screen — see
"External display" in ViewerApp.

## Transport

One WebSocket connection per display, client-initiated, default base port
**5903** (plain `ws://`
on LAN/Tailscale; `wss://` through a Cloudflare Tunnel for remote use — WS was
chosen over raw TCP precisely so the tunnel's zero-config HTTP path carries it,
matching how Clamshell's noVNC web access is already tunneled). No NAT
traversal, no custom TLS. TCP head-of-line blocking is an accepted tradeoff
for simplicity. One client at a time; a new connection replaces the old one.

Host side is an `NWListener` with `NWProtocolWebSocket`; client side is
`URLSessionWebSocketTask`. Every protocol message is sent as one **binary**
WebSocket message.

## Message framing

Every message, both directions, inside binary WebSocket frames:

```
[1 byte type] [4-byte big-endian payload length] [payload]
```

(The explicit length is redundant with WS message boundaries but kept so the
framing survives any transport — the parser accepts arbitrary byte chunks.)

## Message types

| Type | Name             | Direction     | Payload |
|------|------------------|---------------|---------|
| 0x01 | HELLO            | client → host | version(1)=1, requestedCodec(1) |
| 0x02 | HELLO_ACK        | host → client | version(1)=1, codec(1), widthPx(4 BE), heightPx(4 BE) |
| 0x10 | VIDEO_FRAME      | host → client | flags(1), ptsMicros(8 BE), NAL data (see below) |
| 0x11 | KEYFRAME_REQUEST | client → host | empty |
| 0x13 | AUDIO_FRAME      | host → client | one AAC-LC access unit (fixed 48 kHz stereo, no ADTS/cookie) |
| 0x20 | INPUT_MOUSE_MOVE | client → host | x(Float32 BE), y(Float32 BE) — normalized 0..1 in display space |
| 0x21 | INPUT_MOUSE_BUTTON | client → host | button(1: 0=left, 1=right), down(1: 0/1), x(Float32 BE), y(Float32 BE) |
| 0x22 | INPUT_KEY        | client → host | macKeyCode(2 BE), down(1), cgEventFlags(8 BE) |
| 0x23 | INPUT_SCROLL     | client → host | dx(Float32 BE), dy(Float32 BE) — pixel wheel deltas |
| 0x30 | CLIPBOARD        | both          | UTF-8 plain text |

Codec byte: 1 = H.264, 2 = HEVC. The client *requests* a codec in HELLO; the
host picks what its hardware encoder actually supports (HEVC preferred on
Apple Silicon) and states the final choice in HELLO_ACK. Width/height in
HELLO_ACK are the encoded pixel dimensions (capture is at the display's
native pixel resolution, no scaling).

## VIDEO_FRAME payload

- `flags` bit 0 = keyframe (sync sample).
- NAL data is **AVCC style**: a sequence of `[4-byte BE NAL length][NAL bytes]`.
  No Annex-B start codes on the wire — AVCC feeds `CMBlockBuffer` /
  `CMSampleBuffer` directly on the decode side with zero rewriting.
- Keyframes carry their parameter sets **in-band**, prepended as ordinary
  length-prefixed NALs (H.264: SPS, PPS; HEVC: VPS, SPS, PPS) before the IDR
  slices. The client builds/refreshes its `CMVideoFormatDescription` from
  these, so a mid-stream join or resolution change only needs a keyframe.
- Host sends a keyframe immediately after HELLO_ACK, on KEYFRAME_REQUEST, and
  at most every 2 s / 120 frames otherwise.

## Input mapping

Coordinates are normalized (0..1, origin top-left) so the client never needs
the Mac's coordinate space; the host maps them into `CGDisplayBounds` of the
streamed display and injects with `CGEventPost`. Key codes are macOS virtual
key codes (client is responsible for any translation).

## Encoder contract (host)

Hardware encode is **required**, not preferred: the `VTCompressionSession` is
created with `kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder`
and verified via `kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder`.
HEVC hardware is tried first (Apple Silicon media engine), falling back to
H.264 hardware with a loud log; if neither hardware path exists, the stream
refuses to start rather than silently burning CPU. Low-latency tuning:
real-time mode, frame reordering (B-frames) disabled, zero frame delay,
speed prioritized over quality, ~20 Mbps.

## Audio (AUDIO_FRAME)

System audio is captured by the primary display's SCStream
(`SCStreamConfiguration.capturesAudio`), transcoded to AAC-LC 48 kHz stereo
with `AVAudioConverter`, and sent one access unit per message. The format is
fixed on both ends, so no magic cookie / ADTS header is transmitted — the iPad
rebuilds the same `AVAudioFormat` and decodes to PCM for `AVAudioEngine`.
Only the primary connection carries audio; secondary displays are video+input.

## Future (not in v1)

Adaptive bitrate, H.264/HEVC negotiation beyond the single byte, multi-touch
gestures, auth on the WS endpoint (currently: VPN, trusted LAN, or Cloudflare
Access in front of the tunnel). Also on the roadmap, explicitly
deferred: Apache Guacamole (guacd) support — Guacamole natively speaks only
VNC/RDP/SSH, so real support means a custom guacd protocol plugin.
