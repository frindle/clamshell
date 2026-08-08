# Clamshell Stream Protocol (v1)

Custom LAN streaming protocol replacing browser VNC: ScreenCaptureKit capture →
VideoToolbox hardware encode on the Mac → TCP → VideoToolbox hardware decode on
the iPad. Every active display is served independently (one endpoint per
display, see below); hardware encode is strongly preferred but the host falls
back to a software encoder rather than refusing to start.

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
| 0x01 | HELLO            | client → host | version(1)=1, requestedCodec(1) [, clientWidthPx(4 BE), clientHeightPx(4 BE), flags(1: bit 0 = second display surface attached) [, secondWidthPx(4 BE), secondHeightPx(4 BE) — only when bit 0 set]] |
| 0x02 | HELLO_ACK        | host → client | version(1)=1, codec(1), widthPx(4 BE), heightPx(4 BE), flags(1: bit 0 = hardware encoder) |
| 0x03 | CLIENT_DISPLAYS  | client → host | clientWidthPx(4 BE), clientHeightPx(4 BE), flags(1: bit 0 = second display surface attached) [, secondWidthPx(4 BE), secondHeightPx(4 BE) — only when bit 0 set] |
| 0x04 | STREAM_STATUS    | host → client | currentBitrateKbps(2 BE) — see "Connection quality" |
| 0x05 | HOST_LOCK_STATE  | host → client | locked(1: 0/1) — see "Lock screen fallback" |
| 0x06 | CURSOR_POS       | host → client | x(Float32 BE), y(Float32 BE) — normalized 0..1 in this display's source-frame space; see "Cursor-follow auto-pan" |
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
native pixel resolution, no scaling). The trailing flags byte's bit 0 is 1
when the host encoder is hardware-accelerated, 0 for the software fallback;
the byte is trailing so clients that predate it parse unchanged (and a
missing byte from an older host implies hardware, matching its
refuse-to-start contract).

**Flags byte, refined semantics (Windows host).** On Windows the single bit 0
is treated strictly as *"should the client show the software-encoding
warning?"* rather than literally *"is it hardware?"* — because a machine with
**no** hardware encoder at all (e.g. a VM with no GPU passthrough) is an
expected, non-alarming state, not a fallback. The Windows host therefore sets
bit 0 = 1 (no warning) both when a hardware encoder is active **and** when no
hardware encoder exists on the system; it clears bit 0 (warn) only when a
hardware encoder was enumerated but could not be instantiated/driven — a real
fallback. The iOS client needs **no change**: it already shows the banner iff
bit 0 == 0. The Mac host keeps its existing bit 0 = isHardware meaning; the two
hosts differ only in the no-hardware-present case, which the client renders
identically either way.

*Proposed, not yet implemented on Mac/iOS:* bit 1 = "encoder is genuinely
hardware" (the Windows host already sets it: 1 only for HardwareActive). It's
backward compatible because existing clients mask only bit 0. If a future
"Nerd Mode" wants an accurate hardware-vs-software label in the
no-hardware-present case (where bit 0 alone can't distinguish it from real
hardware), it can read bit 1; the Mac host would then also set bit 1 =
isHardware. No client change is required until that label is wanted.

## Client display reporting (HELLO trailing bytes / CLIENT_DISPLAYS)

The client optionally reports its real display situation: its video surface
size in pixels (landscape-normalized — Mac virtual displays are landscape)
and whether a *second* display surface is attached (flags bit 0). When the
flag is set the second surface's own pixel size follows (secondWidthPx,
secondHeightPx), so the host sizes Display B to the real external monitor
instead of a fixed preset. The iPad viewer reports its own screen, sets the
flag while an external monitor is attached, and appends that monitor's size;
the iPhone control app reports the external monitor's size (its only video
surface) as the primary size and never sets the flag. The trailing HELLO
bytes are optional both ways: an old client omits them, an old host ignores
them. CLIENT_DISPLAYS carries the same fields mid-session (monitor plugged or
unplugged after connecting).

Only the **primary** connection's report is honored. The host forwards it to
the Clamshell menu bar app (same distributed-notification channel as the
Sunshine prep-command), which auto-sizes the virtual display to the client
and auto-enables/disables dual display mode ("Auto-Detect Dual Display",
default on). The collapse is restored 15 s after the last reporting client
disconnects; reconnects within the grace period keep it. Sizes below 640×480
are ignored.

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

Hardware encode is strongly preferred: the `VTCompressionSession` is first
created with `kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder`
and verified via `kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder`.
HEVC hardware is tried first (Apple Silicon media engine), falling back to
H.264 hardware with a loud log. If neither hardware path exists, the host
falls back to a **software** session (same codec order, no Require flag)
rather than refusing to start — but never silently: the fallback is logged
loudly, reported in HELLO_ACK's flags byte, and the viewer shows a persistent
warning banner ("Software encoding — expect higher CPU/battery use and
possibly worse latency"). Low-latency tuning: real-time mode, frame
reordering (B-frames) disabled, zero frame delay, speed prioritized over
quality, 20 Mbps starting bitrate (adapted live, below).

## Adaptive bitrate

Reactive, host-side only — no bandwidth estimation, no client feedback
channel. The congestion signal is the existing WebSocket send backpressure:
the host caps unacknowledged in-flight video frames at 8; when the cap is hit
it already drops delta frames and resyncs on a keyframe. Each such drop now
also steps `kVTCompressionPropertyKey_AverageBitRate` on the live session
(a dynamic VT property — no session recreation):

- **Down**: halve the bitrate on congestion, at most once per second,
  floor **2 Mbps**.
- **Up**: after 5 s with no congestion, +25%, at most once per 5 s,
  ceiling **20 Mbps**.

Bitrate resets to the 20 Mbps ceiling on every new connection. Hardware
encoders track the new target within a GOP or two; on a constrained link
(hotel wifi, cellular through the Cloudflare Tunnel) the stream converges to
what the path drains instead of stuttering at a fixed 20 Mbps.

## Connection quality (STREAM_STATUS)

The adaptive bitrate above is otherwise invisible to the user, so the host
sends STREAM_STATUS (host → client) carrying the current encoder target in
kbps: once right after HELLO_ACK, then again on every up/down step. The client
turns it into an unobtrusive quality dot alongside the software-encoding
banner (green near the 20 Mbps ceiling, yellow reduced, orange near the 2 Mbps
floor) — a status light, not a stats overlay. An optional client-side "Nerd
Mode" expands the dot into a one-line readout (codec, resolution, hardware vs.
software, current Mbps) built from HELLO_ACK plus this message. Pre-status
hosts simply never send it; the client shows no dot until the first one
arrives.

## Lock screen fallback (HOST_LOCK_STATE)

Native ScreenCaptureKit capture runs in the logged-in user session and stops
delivering frames at the macOS lock screen; `CGEventPost`-injected input can't
cross it either (both are deliberate security boundaries, not bugs). The host
therefore reports lock state so the client can fall back to the browser VNC
bridge (noVNC on `http://<mac>:5901` → Apple's privileged `screensharingd`),
which *can* reach and unlock a locked Mac.

The host observes the system `com.apple.screenIsLocked` /
`com.apple.screenIsUnlocked` distributed notifications (seeding initial state
from the login session's `CGSSessionScreenIsLocked`) and sends HOST_LOCK_STATE
(1-byte boolean, `1` = locked) on every change, to every connected display, and
once right after HELLO_ACK — so a client connecting to an already-locked Mac
knows immediately. On `locked = 1` the client shows a prominent banner over the
video/trackpad ("Mac is locked — native video paused") with a one-tap link to
the browser fallback. On `locked = 0` the banner clears and the native video
resumes on its own through the existing reconnect/keyframe flow — no separate
resume message. Pre-lock-state hosts simply never send it; the client shows no
banner.

## Cursor-follow auto-pan (CURSOR_POS)

Built for viewing a large/ultrawide Mac display on a smaller/differently-shaped
portable monitor plugged into an iPad in External Display Only mode (see the
README): the client can render a zoomed-in crop of the frame instead of
shrinking the whole thing to fit, and auto-pan that crop to keep the remote
mouse cursor in view as it moves. The cursor is baked into the captured frame
pixels like any normal screen capture — it isn't otherwise available to the
client — so the host reports it out-of-band.

Each display's `StreamServer`/`StreamServer` (Mac/Windows) independently polls
the *global* cursor position at **20 Hz** (Mac: `CGEvent(source: nil)?.location`,
matching the coordinate space `CGDisplayBounds`/`InputInjector` already use;
Windows: `GetCursorPos`, matching `InputInjector`'s virtual-desktop mapping),
normalizes it against that display's own bounds, and sends CURSOR_POS — but
only when the client-facing socket is connected, and skipped (no message)
when the position hasn't moved by more than a small epsilon since the last
send, so an idle mouse costs nothing. 20 Hz is deliberately much lower than
the video frame rate: it's plenty for a smooth-feeling auto-pan and the
payload is 8 bytes versus a full video frame.

Because each display server reports independently and un-clamped, a value
outside `0...1` on a given connection means the cursor is currently on a
*different* display than that connection streams — clients use that to know
whether auto-pan should apply on this screen at all. Only clients that opted
into a pan/zoom viewport act on it; a client with no viewport (the plain
aspect-fit render path) simply ignores CURSOR_POS.

Client-side, manual pan/zoom and cursor-follow share one small piece of state
(`Viewport` in `ClamshellViewer/Sources/VideoView.swift`): a two-finger drag
pans, a pinch zooms, and either one immediately turns auto-follow off (rather
than blending with it or resuming after an idle timeout) — the user re-enables
it with a toggle. Pre-CURSOR_POS hosts simply never send it; the client's
viewport just never auto-pans.

## Audio (AUDIO_FRAME)

System audio is captured by the primary display's SCStream
(`SCStreamConfiguration.capturesAudio`), transcoded to AAC-LC 48 kHz stereo
with `AVAudioConverter`, and sent one access unit per message. The format is
fixed on both ends, so no magic cookie / ADTS header is transmitted — the iPad
rebuilds the same `AVAudioFormat` and decodes to PCM for `AVAudioEngine`.
Only the primary connection carries audio; secondary displays are video+input.

## Future (not in v1)

H.264/HEVC negotiation beyond the single byte, multi-touch
gestures, auth on the WS endpoint (currently: VPN, trusted LAN, or Cloudflare
Access in front of the tunnel). Cloudflare Access, if used, is enforced at the
edge — via WARP-enrolled devices or an Access policy that trusts the
connection at the network layer — not by app-level Service Token headers (the
apps send no `CF-Access-*` headers). Also on the roadmap, explicitly
deferred: Apache Guacamole (guacd) support — Guacamole natively speaks only
VNC/RDP/SSH, so real support means a custom guacd protocol plugin.

## Window Handoff (v2, PROPOSED — not implemented, not a contract yet)

Drag an app window off the edge of one machine's screen and have it reappear,
live and interactive, as a native-feeling floating window on a *second*
machine's screen — and back again. Started 2026-08-08: Mac + a Windows VM
(hosted on Unraid, GPU-passthrough to its own physical monitor — the Mac has
zero OS-level awareness that monitor exists). Keyboard/mouse continuity is
out of scope here — solved separately (Synergy-style software KVM, planned as
a later phase, or hardware IP-KVM). This section is capture/stream/handoff
only, and unlike v1's host-serves/client-connects asymmetry, **both machines
run every role**: each is a sender (owns real windows, can stream one out) and
a receiver (can render an incoming stream as a local floating window) at once.

**Why not v1's per-display-port model:** v1 serves a small, fixed set of
displays at predictable ports (`basePort + index`). Windows are dynamic —
opened, closed, dragged, ID reused — so a fixed port per window doesn't work.
Instead: one persistent **control connection** per machine pair (new fixed
port, proposed **5910**), multiplexing window list/handoff control messages
*and* tagged video/input for however many windows are actively remoted
between that pair at once.

**Pairing:** reuses the existing QR/saved-machines model (README "QR pairing
+ saved machines") rather than inventing discovery — pair the Mac and the
Windows-VM agent once, each saves the other's address.

### Proposed message types (control connection, same `[type][len][payload]` framing)

| Type | Name | Direction | Payload |
|------|------|-----------|---------|
| 0x40 | WINDOW_LIST_REQUEST | peer → peer | empty |
| 0x41 | WINDOW_LIST_RESPONSE | peer → peer | count(2 BE), then per window: windowId(4 BE), titleLen(1)+title(UTF-8), appNameLen(1)+appName(UTF-8), widthPx(4 BE), heightPx(4 BE) |
| 0x42 | HANDOFF_BEGIN | source → dest | windowId(4 BE), crossX/crossY (Float32 BE ×2, normalized 0..1 position where the drag crossed the trigger edge), titleLen+title, appNameLen+appName, widthPx(4 BE), heightPx(4 BE) |
| 0x43 | HANDOFF_ACCEPT | dest → source | windowId(4 BE) — dest opened a receiver window, ready for frames |
| 0x44 | HANDOFF_REJECT | dest → source | windowId(4 BE), reasonLen(1)+reason(UTF-8) |
| 0x45 | WINDOW_STREAM_START | dest → source | windowId(4 BE) — begin encoding/sending |
| 0x46 | WINDOW_STREAM_FRAME | source → dest | windowId(4 BE) + v1's VIDEO_FRAME payload shape (flags, ptsMicros, AVCC NALs) |
| 0x47 | WINDOW_INPUT_MOUSE_MOVE / _BUTTON / _KEY / _SCROLL | dest → source | windowId(4 BE) + v1's matching INPUT_* payload, coordinates normalized to *this window's* bounds, not display bounds |
| 0x48 | HANDOFF_RETURN | dest → source | windowId(4 BE) — dragged back across the edge; source un-hides the real window, dest tears down its receiver |
| 0x49 | WINDOW_CLOSED | source → dest | windowId(4 BE) — real window closed while remoted; dest closes its receiver too |

### Capture

- **Mac**: `SCContentFilter(desktopIndependentWindow:)` — works on a window
  that's off-screen/occluded, not on one that's minimized.
- **Windows**: `Windows.Graphics.Capture`'s `GraphicsCaptureItem.CreateFromWindowId`
  — same off-screen-ok/minimized-not-ok constraint, needs verifying against a
  real VM (no GPU passthrough inside the VM itself for the *capture* side,
  since the VM captures its own windows before the passthrough GPU scans them
  out — capture path doesn't touch the passthrough hardware).

  **This is a new capture technology for this codebase, not a port of the
  existing one.** `WindowsServer`'s current display capture (`DisplayCapture.cs`)
  is DXGI Desktop Duplication (`IDXGIOutputDuplication`, via Vortice) — a
  whole-display API with no per-window filter concept. The alternatives that
  stay within DXGI/Win32 (`PrintWindow`, `BitBlt` from a window's DC) were
  considered and rejected: `BitBlt` only works for on-screen, unoccluded
  windows, which breaks the moment the source window is hidden off-screen
  (the whole mechanism this feature depends on); `PrintWindow` is
  unreliable for GPU-composited windows (Chrome, video, anything DirectX)
  even with `PW_RENDERFULLCONTENT`. `Windows.Graphics.Capture` is the only
  Windows API that reliably captures off-screen, GPU-composited windows —
  matching what ScreenCaptureKit already does on Mac — so it coexists
  alongside DXGI Desktop Duplication as a second capture path used only for
  window handoff, not a replacement for display streaming.

  Practically: needs the project's `TargetFramework` bumped from
  `net8.0-windows` to a versioned moniker (`net8.0-windows10.0.19041.0`,
  the floor for reliable per-window `GraphicsCaptureItem` creation) to get
  WinRT projections for free from the C#/WinRT source generator — no manual
  CsWinRT NuGet package needed for the standard projected surface. The one
  piece that *does* need manual COM interop is turning an `HWND` into a
  `GraphicsCaptureItem`: `IGraphicsCaptureItemInterop.CreateForWindow`
  isn't part of the standard projection (Microsoft's own WGC samples
  P/Invoke-declare this interface directly). Also needs a
  `DispatcherQueueController` running on the calling thread before any WGC
  call — the Windows analog of the Mac's `NSApplication.shared` fix for
  `CGS_REQUIRE_INIT` (both are "this capture API needs a real windowing
  session, not just a bare process" quirks). Bumping the TFM to a versioned
  Windows moniker also raises the minimum Windows version this app runs on
  — worth flagging explicitly when this lands, not a silent side effect.

### Hiding the source window without minimizing it

Capture requires the window to not be minimized, so "hide" means **move it
off-screen** (large negative coordinate), not `AXUIElement`/`SetWindowPos`
minimize. Mac: Accessibility API (`AXUIElementSetAttributeValue` on
`kAXPositionAttribute`). Windows: `SetWindowPos`. Restored to its original
position on HANDOFF_RETURN or disconnect.

### Drag-trigger detection (per machine, watches its own windows only)

- **Mac**: global `CGEventTap` on left-mouse-drag; `AXUIElementCopyAttributeValue`
  identifies the window under the cursor at drag-start and polls its live
  frame during the drag. On mouse-up, if the window's frame center has crossed
  the configured trigger edge (top, since the portable monitor is mounted
  above), fire HANDOFF_BEGIN.
- **Windows**: `SetWinEventHook` on `EVENT_SYSTEM_MOVESIZESTART/END` +
  `EVENT_OBJECT_LOCATIONCHANGE`, `GetWindowRect` for the live frame, same
  edge-threshold logic against whichever edge is configured for that side.
- Trigger edge is a **per-machine config value**, not something either side
  can infer — there's no shared physical-layout API since these are two
  independent OS instances with no compositor in common.

### Open questions before implementation starts

1. Exact edge-threshold heuristic (drag must *end* past the edge, vs. cross
   it and pause, vs. a dedicated modifier-key-drag) — needs to feel
   intentional, not accidental.
2. Multi-monitor on the Mac side: which of the Mac's own displays (if more
   than one) has the "hot edge" active.
3. Auth on the control connection — same open item as v1 (currently trusted
   LAN/VPN only), but this one also injects input and moves windows, a bigger
   blast radius if it's ever exposed off-LAN.
4. Focus/activation semantics when a receiver window is clicked — does it
   need to feel like a truly local window (Spaces, Mission Control, Alt-Tab)
   or is a plain floating window enough for v1 of this feature.

Latency target (estimate, not yet measured): same-LAN hardware capture →
encode → decode pipeline as v1's display streaming, 15–35ms glass-to-glass is
realistic (comparable to Moonlight/Sunshine on LAN); window content is
typically smaller than a full display so should land at the favorable end.
Real number needs a glass-to-glass test once both ends exist — extend
`stream-selftest`/`SelfTest.cs` with per-stage timing rather than guessing.
