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

## Remote confirmation (ConfirmationBridge — standalone module, not yet on the wire)

The immurok-inspired design for gating privileged actions ("Future" above
mentions WS auth; this is the finer-grained piece): the host issues a fresh
32-byte nonce for a specific pending action, the client signs it with ECDSA
P-256, the host verifies against the enrolled public key, consumes the nonce
(replay protection), and expires it after 30 s. Each pending action gets its
own nonce, so a signature for action A can never confirm action B —
`confirmation-bridge-selftest` proves that negative along with replay,
expiry (real 31 s wait), wrong-key, and malformed-signature rejection.

**YubiKey-backed signing (2026-08-23):** the signature can now come from a
YubiKey 5 PIV slot instead of a software key. The core lives in
[immurok-yk](https://github.com/frindle/immurok-yk) (standalone,
transport-agnostic, tested without hardware); Clamshell consumes it as a
thin adapter (`Auth/YubiKeyConfirmation.swift`):

- `ConfirmationBridge` accepts DER-encoded signatures (what PIV GENERAL
  AUTHENTICATE emits) alongside the original 64-byte raw encoding.
- Enrollment reads the slot's public key off the card, preferring the F9
  attestation certificate (proves the key was generated on-device).
- The slot's touch policy (set at key generation, enforced on-card) makes
  every confirmation proof of a human hand at the key — that, plus key
  non-extractability, is exactly what the software path cannot provide.
- `clamshell confirmation-yubikey-selftest` runs the loop on real hardware
  (needs a YubiKey with an ECCP256 key in slot 9c). Unverified on real
  hardware so far: built and negative-tested on a machine with no YubiKey;
  the selftest fails fast and honestly when the card or entitlement is
  missing.
- **The smartcard entitlement is now applied by the build, not by hand.**
  `TKSmartCardSlotManager.default` is nil without
  `com.apple.security.smartcard`, so an unentitled Clamshell cannot see any
  card whatever is plugged in. `dev-build.sh` and `package.sh` both sign
  with `scripts/smartcard.entitlements` (the DMG re-sign included, or the
  shipped copy would lose it). Note `swift run` re-links and drops the
  signature — run `.build/debug/Clamshell` directly for anything touching a
  card.

**Menu-bar UI (2026-08-23):** the host side is now visible, which it had to
be before a remote trigger could mean anything — a confirmation the user
can't see is a confirmation they can't refuse.

- `ConfirmationCoordinator` (Auth/ConfirmationCoordinator.swift) holds the
  live state for one pending confirmation: `connecting → awaitingTouch →
  verifying → approved | rejected | expired`. It owns the expiry timer, so
  an unanswered challenge settles itself with no panel open and nothing
  driving it.
- `ConfirmationWindowController` (ConfirmationUI.swift) is a floating
  NSPanel — action name, live countdown against the *same* deadline the
  bridge enforces, state line, auto-dismiss on a terminal state. Same
  hand-laid NSStackView shape as the Diagnostics window; no SwiftUI. It is
  explicitly not `hidesOnDeactivate`, since focus moving away is exactly
  when the countdown matters.
- The status-item icon switches to `key.fill` while anything is pending, so
  a confirmation is visible with the panel behind another window.
- The panel is raised from the coordinator's state change rather than from
  the menu action. **That is the seam**: the WS handler, when it exists,
  calls `begin(action:clientId:)` for a nonce to send and `submit(signature:)`
  when the client answers — the same two calls the test path makes — and the
  panel and icon react with no UI change at all.
- Until then, "Test YubiKey Confirmation…" (System submenu) drives the whole
  loop locally against a real card: read slot 9c, enroll, issue a challenge,
  sign on the key, verify. No mock signer on that path — a green "Approved"
  means the hardware genuinely worked. The PIN is collected up front, before
  the challenge is issued, so typing it doesn't eat the 30 s.
- `clamshell confirmation-coordinator-selftest` covers the transitions and
  the real 30 s expiry (state machine only — it uses a software key for the
  one case needing a valid signature, and says so).

Still not wired into the streaming protocol — no message types are assigned
yet. When it is, the challenge/response rides the existing WS as two small
messages and the rest of this design is unchanged.

## Window Handoff v1 (IMPLEMENTED, Mac host side — explicit selection)

Stream a single macOS **window** (not a whole display) to a viewer, so it
shows up as its own native-feeling window on the other machine instead of a
fullscreen remote-desktop view. Built 2026-08-14 as the first real slice of
the fuller "drag a window across machines" vision below.

**Reuses v1's protocol/framing unchanged** — no new message types. Same
HELLO/HELLO_ACK handshake, same VIDEO_FRAME AVCC framing, same INPUT_* mouse
and keyboard messages, same `[type][len][payload]` wire format. The only
thing that's new is the *capture source*: `StreamServer` (Sources/Clamshell/
Streaming/StreamServer.swift) takes a `StreamSource` (`.display(id)` or
`.window(id)`) instead of a bare display ID, and for `.window` builds its
`SCContentFilter` with `desktopIndependentWindow:` instead of `display:`.
Everything downstream (VideoEncoder, adaptive bitrate, backpressure, the
send/receive loop) is identical code, unmodified.

**Why one fixed port, not `basePort + index` like displays:** the display
fleet is a small, predictable set (see "Displays" above); windows are
dynamic — opened, closed, reselected between runs — so a fixed port-per-window
scheme doesn't fit. `clamshell stream-window <windowId> [port]` serves one
window on one port (default **5920**, `windowStreamDefaultPort` in
StreamProtocol.swift) for the life of the process.

**No AX auto-hide, no drag-trigger UX (v1, deliberate):** this dev Mac has a
real system-wide Accessibility reporting failure (see
`WindowHandoff/WindowHideSelfTest.swift` / `WindowAtCursorSelfTest.swift` —
confirmed via three independent techniques, not fixable from inside this
codebase). So v1 skips AX entirely: no "hide the source window" and no
cursor-drag handoff trigger. Selection is explicit — `clamshell stream-window
<windowId>` (from `clamshell window-list`), or the menu bar's Streaming >
"Stream a Window…" submenu (added 2026-08-14, `StatusBarApp.swift`), which
lists the same `WindowList.listCapturable()` output and wraps the identical
`StreamServer(source: .window(id))` path the CLI command uses — no separate
logic. The window is captured wherever it currently sits and stays visible on
the Mac while also streamed out — not moved off-screen.

**Input mapping differs from a display:** a window can move mid-session (no
AX to pin it), so `InputInjector`'s target bounds are looked up live per
event via `CGWindowListCopyWindowInfo` keyed on the window ID, instead of the
fixed `CGDisplayBounds` a display uses — see `InputInjector.swift`. Normalized
0..1 coordinates now mean "within the window's current frame," not "within
the display."

**Skipped for v1 (ponytail — ponytail comments at each site):** audio (the
window server is never `isPrimary`, so no `AudioEncoder`/`ClipboardBridge`
attach — `SCContentFilter` does support per-window audio if this turns out to
matter later); cursor-follow auto-pan / CURSOR_POS (a display concept — no
"which display is the cursor on" question for a single window); native pixel
(Retina) resolution — capture is at the window's **points** size, not scaled
by its owning screen's `backingScaleFactor`, since `SCWindow` doesn't expose
that cheaply; upgrade if remoted windows look soft on a Retina Mac. Also:
window **resize** mid-session isn't handled — capture stays at the
connect-time dimensions, so a resized source window scales/distorts in the
stream until the client reconnects (input mapping stays correct regardless,
since `InputInjector` re-queries the window's live bounds per event).

**Proven live** (2026-08-14, this dev Mac, real HELLO→HELLO_ACK→VIDEO_FRAME
over a real WebSocket, not a unit test): `clamshell stream-window 105 5920`
against Calendar.app's window, connected with a throwaway Python
`websockets` client sending a real HELLO — got back `HELLO_ACK: version=1
codec=2(HEVC) 935x598 flags=1(hardware)`, then a real keyframe (28,926 bytes)
followed by real delta frames, matching the window's actual on-screen size.
INPUT_MOUSE_MOVE was sent and accepted with no Accessibility-permission
warning logged (the same warning path already proven for display streaming).

**Windows viewer client (IMPLEMENTED 2026-08-14, `WindowsViewer/`):** a WPF
app (`ClamshellWindowViewer.exe`) that connects to a host's window-stream (or
display-stream — same wire protocol either way) WebSocket endpoint, decodes
AVCC H.264/HEVC via a Media Foundation decoder MFT
(`WindowsViewer/VideoDecoder.cs`, the client-side mirror of the host's
`VideoEncoder.cs` — same architecture, sync MFT, literal GUIDs), renders into
a `WriteableBitmap`, and forwards INPUT_MOUSE_MOVE/INPUT_MOUSE_BUTTON/
INPUT_KEY/INPUT_SCROLL back over the same wire messages (Windows VK codes
translated to macOS virtual key codes via `WindowsViewer/MacKeyMap.cs`, the
inverse of the host's `MacKeyMap.cs`). The window is sized to HELLO_ACK's
widthPx/heightPx (clamped to the local screen) so a single streamed macOS
window shows up as its own native-sized window on Windows, not a fullscreen
view. `dotnet run --project WindowsViewer/ClamshellWindowViewer.csproj -- <host> <port> [h264|hevc]`.

**Proven live in CI** (`.github/workflows/windows-ci.yml`, real `windows-latest`
VM, no physical Windows machine involved), three separate pieces of real
evidence, none of them a unit test:

1. **Real protocol handshake against the real host.** `ClamshellServer.exe`
   is launched as a real display-stream source (Notepad open for real
   on-screen content); the viewer's headless `--verify` mode does a real
   WebSocket connect and gets back a real HELLO_ACK (`codec=H264 1024x768`).
2. **Real H.264 decode through the viewer's actual wire-payload code path.**
   A single-keyframe clip from an independent, known-good encoder
   (`ffmpeg`/libx264, not WindowsServer's) is converted to AVCC and fed
   through the exact same `Dispatch → Feed → Avcc.ToAnnexB → decode` route a
   live VIDEO_FRAME takes, decoding via the real (software — no GPU on the
   runner) Media Foundation H.264 decoder MFT. The CI log shows a real
   320×240 non-uniform decoded frame, not blank/garbage output.
3. **Real WPF construction on a real virtual display.** The GUI binary
   (`Application`/`Window`/`Image`/`WriteableBitmap`, no XAML) is launched
   for real and stays up for several seconds without crashing.

**What's NOT proven, and why:**
- **A real VIDEO_FRAME actually arriving over the wire and being decoded/
  rendered end-to-end.** Step 1 above never gets this far: WindowsServer's
  software H.264 *encoder* fails to initialize on this runner once a client
  connects and starts a session (`VideoEncoder.Create → Build →
  SetInputType/SetOutputType` throws `E_FAIL`) — a pre-existing
  WindowsServer bug this test discovered (the previous "Live smoke test"
  step never had a client connect, so it never exercised this path; only the
  encoder *probe*, which never builds a session, ran before). That's
  WindowsServer-side and out of scope for this change, so it wasn't fixed
  here. The CI step is written to auto-upgrade to a full live round-trip
  proof (`verify: PASS`) the moment that bug is fixed elsewhere — no viewer
  change would be needed.
- **Rendering a real decoded frame into the WPF window.** Step 3 constructs
  the window; step 2 proves the decoder in isolation from the network path.
  Nothing in CI currently feeds a network-decoded frame into `MainWindow`'s
  `WriteableBitmap`.
- **Input forwarding.** `MainWindow`'s mouse/keyboard handlers and
  `MacKeyMap` were checked against `WindowsServer/StreamServer.cs`'s
  `Dispatch` by reading both, matching wire offsets exactly, but never
  executed against a live host (no click/keystroke was ever sent and
  observed being received).
- **A real *window-cropped* source.** `WindowsServer` has no window-capture/
  streaming implementation — `WindowEnum.cs` is enumeration only, a stub for
  the still-`PROPOSED` v2 design below; only the Mac host can stream a
  single window today. So even once the encoder bug above is fixed, CI can
  only prove this viewer against a *display* stream, not a real
  `stream-window` source.
- **The Mac host and this viewer running against each other on real
  hardware.** No physical Windows machine was available in this
  environment.

**Superseded:** the control connection, drag-trigger detection, window
hiding and Windows-side window capture this section lists as missing are now
built — see "Peer link (v2)" below. The v1 window stream above is exactly the
video/input leg a handoff negotiates.

## Peer link (v2) — shared desk between two paired machines

Synergy-style: two machines (Mac↔Mac, Mac↔Windows, Windows↔Windows) share
one mouse and keyboard across a screen edge, sync the clipboard, move files by
drag-and-drop, and hand live windows back and forth. Both machines run every
role at once. Implemented in `Sources/Clamshell/Peer/` + `WindowHandoff/`
(Mac) and `WindowsServer/Peer/` (Windows); the byte layout below is pinned by
a shared golden table (`peer-protocol-selftest` / `peerselftest`) and a
Swift⇄C# interop run (`scripts/peer-interop.sh`, CI `peer-interop.yml`).

### Transport and discovery

- One **WebSocket on TCP 5910** per machine pair (`ws://host:5910/`, binary
  messages, the same `[type u8][len u32 BE][payload]` framing as v1; a WS
  message may carry several frames or part of one — receivers reassemble).
  Windows does the RFC 6455 upgrade by hand over a plain `TcpListener`, so no
  URL ACL / elevation, and both sides know the peer's real address.
- Discovery: DNS-SD **`_clamshell-peer._tcp`**, TXT `id=<peer id>`,
  `name=<display name>`, `v=2` (Bonjour on the Mac, `Makaretu.Dns.Multicast`
  on Windows). A machine ignores its own id. Connecting by address works
  without mDNS.
- Auto-reconnect: when two machines that trust each other see each other,
  only the one with the **smaller peer id** dials (so they never
  cross-connect); after a drop it retries every 3 s.
- One link at a time. **Known gap:** an incoming connection replaces the
  current link before it has authenticated, so a host on the LAN can drop a
  link (it cannot join it — every message before authentication is refused).

### Identity, pairing, authentication (0x40–0x42)

Each install has a P-256 ECDSA key (Mac: Application Support/Clamshell;
Windows: %LOCALAPPDATA%\Clamshell; `CLAMSHELL_PEER_DIR` overrides). Public key
on the wire = 65-byte X9.63 (`04‖X‖Y`); **peer id** = lowercase hex SHA-256 of
it. Signatures are raw `r‖s` (64 bytes) over `nonce ‖ own public key`. A
6-digit **pairing PIN** is shown on each machine (menu / tray); PIN proof =
HMAC-SHA256(key = SHA-256("clamshell-pair:" + PIN), data = nonce ‖ own public key).
Strings are `len u16 BE + UTF-8`, at most 128 bytes (truncated on a character
boundary).

| Type | Name | Dir | Payload |
|------|------|-----|---------|
| 0x40 | PEER_CHALLENGE | server → client | serverNonce (32) |
| 0x41 | PEER_HELLO | client → server | version u8 (=2), flags u8 (bit 0 = PIN proof present), publicKey (65), clientNonce (32), signature over serverNonce (64), [pinProof over serverNonce (32)], name str, screenW u32, screenH u32 |
| 0x42 | PEER_HELLO_ACK | server → client | version u8, status u8 (0 ok, 1 untrusted, 2 bad PIN, 3 bad signature, 4 busy, 5 version); if ok: publicKey (65), signature over clientNonce (64), proofFlag u8, [pinProof over clientNonce (32)], name str, screenW u32, screenH u32 |

Server: signature must verify; an untrusted key must carry a valid PIN proof
for the server's PIN (else `untrusted` / `bad PIN`), and is then trusted.
Client: signature must verify; if it doesn't already trust the server it must
have typed the server's PIN and the ACK must carry a matching proof — so
neither side trusts "whoever answered". Anything but these three before
authentication closes the connection. Screen sizes are each side's primary
display in its own input units (points on a Mac, pixels on Windows).

### Shared mouse and keyboard (0x44–0x45 + v1 INPUT_*)

| Type | Name | Payload |
|------|------|---------|
| 0x44 | EDGE_ENTER | edge u8 (edge of the **controlled** screen the cursor enters on: 0 left, 1 right, 2 top, 3 bottom), x f32, y f32 (normalized 0…1, top-left origin), leftButtonDown u8 |
| 0x45 | EDGE_LEAVE | empty — control goes back to the controller |

- Each machine configures which of its edges leads to the peer. Pushing the
  pointer out through that edge (of a display with nothing beyond it) sends
  EDGE_ENTER on the opposite edge; the controller freezes/hides its cursor,
  keeps a virtual cursor in the peer's screen units (speed scale =
  clamp(peerW / localW, 0.5, 3)) and sends v1 INPUT_MOUSE_MOVE /
  INPUT_MOUSE_BUTTON / INPUT_KEY / INPUT_SCROLL, all swallowed locally.
  Leaving the peer's screen by the entry edge sends EDGE_LEAVE and the local
  cursor reappears where it crossed.
- The controlled side honours input only between EDGE_ENTER and EDGE_LEAVE,
  maps it to its **primary display** (known gap: secondary displays of the
  controlled machine aren't reachable), and tags everything it injects so its
  own edge detection ignores it. Receiving EDGE_ENTER while controlling the
  other side abandons our crossing (last crossing wins).
- Keys are macOS virtual key codes + CGEventFlags bits (v1 INPUT_KEY). Windows
  maps Ctrl ⇄ Command, Win ⇄ Control, Alt ⇄ Option. Modifiers travel as their
  own key down/up; Caps Lock as a down+up tap.
- Scroll is macOS pixel deltas (positive y = up, positive x = left); Windows
  converts 120 wheel units ⇄ 40 px.
- Crossing with the left button held is allowed only when it carries
  something (below); EDGE_ENTER leftButtonDown = 1 means "carrying": the
  controlled side injects no press and treats the next left release as the
  end of the carry.
- Panic key while controlling: Mac Ctrl+Option+Command+L, Windows
  Ctrl+Alt+Shift+L — takes control back immediately.

### Clipboard (v1 0x30 + 0x46)

Text rides v1 CLIPBOARD (UTF-8). Images ride **0x46 CLIPBOARD_DATA**:
`kind u8` (1 = PNG) + bytes. Each side polls its clipboard (Mac change count,
Windows sequence number), sends new copies, and doesn't echo what it just
wrote. Limit 32 MiB. Copied files aren't synced — drag them or use Send Files.

### Files (0x50–0x55)

| Type | Name | Payload |
|------|------|---------|
| 0x50 | FILE_OFFER | transferId u32, size u64, name str |
| 0x51 | FILE_ACCEPT | transferId u32 |
| 0x52 | FILE_REJECT | transferId u32, reason u8 |
| 0x53 | FILE_CHUNK | transferId u32, offset u64, bytes (≤ 128 KiB) |
| 0x54 | FILE_DONE | transferId u32, sha256 (32) |
| 0x55 | FILE_CANCEL | transferId u32, reason u8 |

Outgoing files go one at a time (queued); up to 4 incoming at once;
auto-accepted from the paired peer into
Downloads (hidden `.part` file, renamed on a matching SHA-256; name sanitized,
unique-suffixed). Chunks strictly in order, ≤ 8 in flight; offer unanswered
for 60 s = failed; ≤ 8 GiB. Folders are sent as a `.zip`. Reject/cancel
reasons: 0 user, 1 error, 2 too large, 3 disk, 4 unsupported, 5 busy.

**Drag-and-drop:** files dragged across the edge are sent when the button is
released on the other machine (the controller drove the drag) or as soon as
the peer's cursor leaves (the peer drove a drag that started on this
machine); the local drag is cancelled (Esc) so nothing drops at the edge.
The Mac reads the drag pasteboard; Windows lines the edge with a 2-px,
nearly transparent drop target while the button is held.

### Window handoff (0x48–0x4C)

| Type | Name | Dir | Payload |
|------|------|-----|---------|
| 0x48 | HANDOFF_BEGIN | source → receiver | windowId u32, edge u8 (receiver's screen), position f32 (0…1 along it), grabX f32, grabY f32 (cursor within the window, 0…1), width u32, height u32, streamPort u16, title str, appName str |
| 0x49 | HANDOFF_ACCEPT | receiver → source | windowId u32 |
| 0x4A | HANDOFF_REJECT | receiver → source | windowId u32, reason u8 |
| 0x4B | HANDOFF_RETURN | receiver → source | windowId u32, edge u8 (0xFF = none: restore where it was), position f32 |
| 0x4C | WINDOW_CLOSED | source → receiver | windowId u32 — the real window closed, or the source took it back ("Bring Back") |

Flow: a window dragged by its title bar across the edge (the window under the
press has moved), or picked from the menu, is **served on a fresh v1 window
stream** on a port in **5921–5940** that accepts only the peer's address; the
real window is **parked** (hidden but still composited, so capture
continues; never minimized) and HANDOFF_BEGIN is sent. The Mac moves it
almost entirely off-screen. Windows leaves it in place as a layered,
alpha-0, click-through window, because a window moved off-screen stops
repainting and WGC stops delivering frames (measured by deskselftest's
park probe). An already-layered Windows window falls back to the
off-screen park, and its stream freezes until it repaints. The receiver
opens a borderless window (title strip + "↩ Send back"), dials
`ws://source:streamPort/` and speaks plain v1: HELLO → HELLO_ACK (codec,
captured size) → VIDEO_FRAME…, INPUT_* back normalized to the video. While
the carrying drag is still held the receiver window follows the cursor.
No HANDOFF_ACCEPT within 15 s → the window comes back. ↩, closing the
receiver, or dragging it back across the edge sends HANDOFF_RETURN; the
source restores the window (under the cursor if it was dragged home). The
source checks every second that the real window still exists (WINDOW_CLOSED
if not). A dropped link brings every window home and closes every receiver.

Capture: Mac ScreenCaptureKit (`desktopIndependentWindow`), Windows
Windows.Graphics.Capture (`IGraphicsCaptureItemInterop.CreateForWindow`, needs a
DispatcherQueue on the calling thread; the capture size is fixed at start —
a resized window is cropped/padded). Park/restore: Mac Accessibility
position; Windows `WS_EX_LAYERED | WS_EX_TRANSPARENT` + alpha 0 (the
extended style is put back on restore). Receiver codecs: the Mac asks for HEVC, the
Windows receiver for H.264; the source falls back to H.264 and says so in
HELLO_ACK.

Input into a parked window: the Mac posts events to the owning process
(window-targeted). Windows posts mouse messages to the child window under
the mapped point, and injects keys with SendInput when the window can be
brought to the foreground (else posted WM_KEYDOWN/WM_CHAR). **Known gaps
(Windows source):** clicks on the title bar / frame aren't delivered; apps
that read raw input or the async key state (games, some Chromium / UWP
surfaces) may ignore posted mouse input; Windows 11 may draw its yellow
capture border around the invisible window; the hidden window keeps its
taskbar button and can be Alt-Tabbed to (it stays invisible).

### What is proven, and how

- `clamshell peer-protocol-selftest` / `ClamshellServer peerselftest`: golden
  wire vectors, signatures and PIN proofs shared by Swift and C#.
- `scripts/peer-interop.sh` (CI: peer-interop.yml, macOS): Swift ↔ C# pair,
  link, clipboard and file transfer over loopback, both directions.
- `clamshell edge-selftest`, `peer-files-selftest`, `handoff-selftest` (Mac,
  local only: they need a logged-in session with Accessibility and Screen
  Recording).
- `ClamshellServer deskselftest` (CI: windows-ci.yml on windows-latest,
  real desktop session): LL hooks, crossing, key mapping, panic key,
  carry detection, WGC capture of a hidden window, a stranger's address
  refused, posted clicks while hidden, typing into Notepad, and a handoff
  round trip between two HandoffManagers (begin, accept, HELLO_ACK, return,
  WINDOW_CLOSED). Video frames WARN there: the runner's software H.264
  encoder doesn't start.
- Not proven: anything between two physical machines, and a video frame
  from a Windows source reaching a receiver.

