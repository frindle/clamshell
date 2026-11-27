# Clamshell Stream Protocol (v1)

Custom LAN streaming protocol: ScreenCaptureKit capture →
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
matching how Clamshell's web client is already tunneled). No NAT
traversal, no custom TLS. TCP head-of-line blocking is an accepted tradeoff
for simplicity. One client at a time; a new connection replaces the old one
(from host 0.12 on, only a connection that has passed "Device authentication
and encrypted session" below does).

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
| 0x01 | HELLO            | client → host | version(1)=1, requestedCodec(1) [, clientWidthPx(4 BE), clientHeightPx(4 BE), flags(1: bit 0 = second display surface attached, bit 1 = plain 1x display) [, secondWidthPx(4 BE), secondHeightPx(4 BE) — only when bit 0 set]] |
| 0x02 | HELLO_ACK        | host → client | version(1)=1, codec(1), widthPx(4 BE), heightPx(4 BE), flags(1: bit 0 = hardware encoder) |
| 0x03 | CLIENT_DISPLAYS  | client → host | clientWidthPx(4 BE), clientHeightPx(4 BE), flags(1: bit 0 = second display surface attached, bit 1 = plain 1x display) [, secondWidthPx(4 BE), secondHeightPx(4 BE) — only when bit 0 set] |
| 0x04 | STREAM_STATUS    | host → client | currentBitrateKbps(2 BE) — see "Connection quality" |
| 0x05 | HOST_LOCK_STATE  | host → client | locked(1: 0/1) [, native(1: 0/1)] — see "Lock screen fallback" |
| 0x06 | CURSOR_POS       | host → client | x(Float32 BE), y(Float32 BE) — normalized 0..1 in this display's source-frame space; see "Cursor-follow auto-pan" |
| 0x07 | PING             | both | empty. Keepalive: the browser client sends one after 20 s of sending nothing; the host echoes it. Hosts older than 0.9.23 skip it as an unknown type |
| 0x08 | AUTH_CHALLENGE   | host → client | first message on every connection — see "Device authentication and encrypted session" |
| 0x09 | AUTH_RESPONSE    | client → host | device key, device name, signature |
| 0x0A | AUTH_RESULT      | host → client | status(1) and the host's signature; repeats while the device waits for approval |
| 0x0B | HOST_INFO        | host → client | UTF-8 JSON — host name, kind, displays, known endpoints |
| 0x0C | CLIENT_INFO      | client → host | UTF-8 JSON — the URL the client connected to, app, version |
| 0x0D | DEVICE_PENDING   | host → client | UTF-8 JSON — devices waiting for approval |
| 0x0E | DEVICE_DECISION  | client → host | UTF-8 JSON — approve or deny one waiting device |
| 0x0F | SECURE           | both | AES-256-GCM ciphertext of exactly one inner message, then the 16-byte tag |
| 0x10 | VIDEO_FRAME      | host → client | flags(1), ptsMicros(8 BE), NAL data (see below) |
| 0x11 | KEYFRAME_REQUEST | client → host | empty |
| 0x12 | VIDEO_STATE      | host → client | state(1): 0 running, 1 encoder rebuilding (video paused, host retries), 2 host gave up (no video until a KEYFRAME_REQUEST or reconnect). Sent only on a change. Older clients skip it as an unknown type |
| 0x13 | AUDIO_FRAME      | host → client | one AAC-LC access unit (fixed 48 kHz stereo, no ADTS/cookie) |
| 0x20 | INPUT_MOUSE_MOVE | client → host | x(Float32 BE), y(Float32 BE) — normalized 0..1 in display space |
| 0x21 | INPUT_MOUSE_BUTTON | client → host | button(1: 0=left, 1=right, 2=middle, 3=back, 4=forward), down(1: 0/1), x(Float32 BE), y(Float32 BE). Buttons 2–4 only to a host that advertises `extraButtons`; older hosts treat every button other than 1 as left |
| 0x22 | INPUT_KEY        | client → host | macKeyCode(2 BE), down(1), cgEventFlags(8 BE) |
| 0x23 | INPUT_SCROLL     | client → host | dx(Float32 BE), dy(Float32 BE) — pixel wheel deltas |
| 0x24 | INPUT_MOUSE_RELATIVE | client → host | dx(Float32 BE), dy(Float32 BE) — pointer movement in points, for a captured pointer. Only to a host that advertises `relativeMouse` |
| 0x25 | INPUT_TEXT       | client → host | UTF-8 text to type as-is (dictation, input-method text, emoji), at most 16 KB. Only to a host that advertises `textInput` |
| 0x26 | INPUT_MOUSE_BUTTON_AT_CURSOR | client → host | button(1: as INPUT_MOUSE_BUTTON), down(1: 0/1) — a press or release where the host cursor is now, for a captured pointer. Only to a host that advertises `relativeMouse` |
| 0x30 | CLIPBOARD        | both          | UTF-8 plain text, at most 1 MB (1,048,576 bytes); a host from 0.12 on ignores more and sends no more |
| 0x50 | PERIPHERAL_ATTACH | client → host | UTF-8 JSON — one peripheral the client offers; see "Peripherals attached to the client" |
| 0x51 | PERIPHERAL_STATUS | host → client | id(4 BE), status(1) |
| 0x52 | PERIPHERAL_DETACH | client → host | id(4 BE) |
| 0x53 | PERIPHERAL_INPUT  | client → host | id(4 BE), then a report whose layout depends on the peripheral's kind |
| 0x54 | PERIPHERAL_OUTPUT | host → client | id(4 BE), then a report for the peripheral (rumble, MIDI) |
| 0x60 | RESTART_REQUEST  | client → host | UTF-8 JSON `{"username","password"}` (inside the encrypted session); host runs `fdesetup authrestart`; needs capability bit 7 |
| 0x61 | RESTART_RESULT   | host → client | status(1): 0 restarting, 1 refused, 2 unsupported, 3 failed |
| 0x58 | FILE_OFFER       | both          | UTF-8 JSON — one file the sender wants to transfer; see "File transfer" |
| 0x59 | FILE_ANSWER      | both          | id(4 BE), status(1) |
| 0x5A | FILE_DATA        | both          | id(4 BE), then the next bytes of the file, at most 64 KB |
| 0x5B | FILE_END         | both          | id(4 BE), status(1) |
| 0x5C | LOGIN_CREDENTIALS | client → host | UTF-8 JSON — a saved login for the login window; see "Login window". Only to a host that advertises `loginCredentials` |

Reserved, not specified yet: 0x55–0x57 (further peripheral messages).
0x40–0x4C (Window Handoff v2, adopted by v3) and 0x70–0x85 (v3, app-host) are
specified in "Window Handoff v3" at the end of this file.

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

**flags bit 1 (0.9.22): plain 1x display.** Set, the host builds the virtual
display with pixels == points instead of the default HiDPI (pixels == 2 x
points). The browser's Retina 2x/1x toggle uses it (1x quarters the pixels for
slow links). Hosts older than 0.9.22 ignore the bit and build a HiDPI display
of the same pixel size, so the picture is still correct. Sizes above
7680x4320 are clamped.

**Resizing mid-session does not reconnect.** A CLIENT_DISPLAYS with a new size
resizes the virtual display, then the host rebuilds only its encoder, updates
the capture size and sends a fresh HELLO_ACK with the new width and height
followed by a keyframe. The client rebuilds its decoder and canvas from that
HELLO_ACK. If the resize cannot be done in place the host closes the
connection and the client reconnects, as before 0.9.22.

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

From host 0.12 (each gated by a capability bit, see "Capabilities"):

- **Non-finite numbers are dropped.** A move, button or relative-move message
  with a NaN or infinite value is ignored. In INPUT_SCROLL a NaN or infinite
  delta counts as 0 and the other axis still scrolls.
- **Deltas are capped.** Each INPUT_SCROLL and INPUT_MOUSE_RELATIVE delta is
  cut to ±10 000.
- **Short messages are ignored, extra bytes skipped.** A message shorter than
  its layout does nothing. Bytes after the layout are skipped, so a later
  version can add fields. A button above 4 or a key code above 0xFF is
  ignored.
- **Buttons 2–4** (middle, back, forward) are posted as "other" mouse buttons
  with that button number.
- **Clicks carry a click count.** Two presses of the same button within the
  system double-click interval and a few points of each other are posted as a
  double-click (then triple, and so on), so double-click-to-select works for
  every client without the client sending anything extra.
- **INPUT_MOUSE_RELATIVE** moves the host cursor by (dx, dy) points from where
  it is now. A move that would leave every display is clamped to the display
  the cursor is on. While a button is held the move is posted as a drag, like
  an absolute move. Clients use it when they capture the pointer (pointer
  lock), where there is no absolute position to send.
- **INPUT_MOUSE_BUTTON_AT_CURSOR** presses or releases a button where the host
  cursor is now, without moving it. Button numbers and click counts work as
  for INPUT_MOUSE_BUTTON. A client that has captured the pointer sends this
  for every button event and never an absolute INPUT_MOUSE_BUTTON: it has no
  position of its own, and the last CURSOR_POS it saw can be behind the moves
  it has already sent, so an absolute press would pull the cursor back.
  Example, left button down: `26 00000002 00 01`.
- **Input is applied in the order it arrived.** Mouse, scroll, key and text
  events from one connection are posted one after another in arrival order,
  also while a long INPUT_TEXT is still being typed: a click sent after text
  lands after that text, and a modifier key sent before a click is down
  before the click.
- **Only the modifier bits of cgEventFlags are used.** The host keeps bits
  16–23 (caps lock, shift, control, option, command, numeric pad, help, fn)
  and ignores every other bit.
- **Modifier keys are also sent as keys.** A client sends each modifier's own
  INPUT_KEY down and up, as a hardware keyboard does, and sets the modifier's
  bit in the flags of every key pressed while it is down. A Mac host applies
  the flags. A host on another system uses only the key events and ignores
  the flags, so a client that sent flags alone would lose its modifiers
  there.
- **The backlog is bounded.** When more input is waiting than the host is
  willing to hold, it drops new events, but never the release of a key or
  button it has already taken as down.
- **INPUT_TEXT** types the text through keyboard events that carry the
  characters themselves, in pieces of at most 20 UTF-16 units that never
  split a code point. A line feed, a carriage return, or the pair CR LF
  becomes one press of the Return key, and a tab one press of the Tab key.
  Other control characters (U+0000–U+001F, U+007F–U+009F) are left out. It is
  for text that has no key code. A payload that is not valid UTF-8, or is
  longer than 16 KB, is ignored as a whole: use CLIPBOARD and paste for long
  text.
- **Held input is released when the session ends.** The host tracks which
  buttons and keys a client has down and posts the matching "up" events when
  the connection drops or another client takes over, so a lost connection
  cannot leave a key or a drag stuck on the Mac. Text and other input still
  waiting at that moment is abandoned, so the host does not keep typing for
  a client that has gone.

**Reference vectors.** `tests/vectors/input-v1.json` holds the exact bytes of
every input message, the messages a host must ignore, the deltas and flag
bits it uses, and what it types for a range of INPUT_TEXT payloads. Every
encoder must reproduce the bytes, and every host the outcomes.

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

## Lock state (HOST_LOCK_STATE)

Native ScreenCaptureKit capture runs in the logged-in user session and may stop
delivering frames at the macOS lock screen; `CGEventPost`-injected input may not
cross it either (both are deliberate security boundaries, not bugs). The host
therefore reports lock state so the client can show that the Mac is locked. The
lock screen and login window themselves are served by the login-window helper,
which speaks this same protocol from the login-window session.

The host observes the system `com.apple.screenIsLocked` /
`com.apple.screenIsUnlocked` distributed notifications (seeding initial state
from the login session's `CGSSessionScreenIsLocked`) and sends HOST_LOCK_STATE
(1-byte boolean, `1` = locked) on every change, to every connected display, and
once right after HELLO_ACK — so a client connecting to an already-locked Mac
knows immediately. On `locked = 1` the client shows a prominent banner over the
video/trackpad ("Mac is locked — native video paused"). On `locked = 0` the banner clears and the native video
resumes on its own through the existing reconnect/keyframe flow — no separate
resume message. Pre-lock-state hosts simply never send it; the client shows no
banner.

### Native lock screen (optional trailing byte)

The host setting `nativeLockScreen` is on unless set otherwise (an unset value
means on; `defaults write <bundle id> nativeLockScreen -bool false` turns it
off). HOST_LOCK_STATE carries `native = 1` as a second payload byte when it is
on. The host then keeps streaming and injecting while locked, so the client
must keep showing the native stream, show a banner only ("Mac is locked, type
the password to unlock"). A payload with no second byte comes from an older
host; treat the lock as not carried by the stream there. Clients ignore bytes
past the second.

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

## Device authentication and encrypted session (host 0.12+)

*Status: specified here, implementation in progress. Hosts before 0.12 send no
challenge and serve any connection that reaches them.*

Where a connection comes from (LAN, VPN, loopback, Cloudflare Access) is not
what lets it control the host. Every client device holds a long-term P-256
key, every host holds a long-term P-256 identity key, and each connection
opens with a signed key exchange. The host does nothing for a connection — no
collapse, no capture, no input — until its device key is one the user has
approved. From then on every message is encrypted, so plain `ws://` on a LAN
cannot be read or injected into, and a tunnel's edge sees only ciphertext.

There are no pairing codes. A new device asks; the user approves it once, on
the host or from a device that is already trusted.

### Keys, ids and names

- P-256 throughout. Public keys travel as the 65-byte X9.63 uncompressed point
  (`0x04 ‖ X ‖ Y`). Signatures are ECDSA over SHA-256 in the 64-byte raw
  `r ‖ s` form (IEEE P1363, not DER). These are the native formats of
  CryptoKit, browser WebCrypto and .NET, so no client needs an ASN.1 codec.
- A **device id** is the lowercase hex SHA-256 of the 65-byte public key (64
  characters). The **fingerprint** people compare is its first 16 characters
  in upper case, grouped in fours: `AB12-CD34-EF56-7890`. A host's id and
  fingerprint come from its identity key the same way.
- Names are for display and prove nothing. Both sides drop control characters
  and invisible formatting characters (the bidirectional overrides, for
  example) before showing one. A host also drops the characters that draw
  nothing (the default-ignorable code points and U+115F, U+1160, U+3164,
  U+FFA0 and U+2800) from a name before it stores or shows it. A device waiting
  for approval keeps the name it was first listed with, whatever it calls
  itself on later connections, until it is approved. When a device waiting for
  approval has the same name as a trusted device, the host's approval window
  says so. "The same" is judged on a skeleton of the name: Unicode NFKD without
  combining marks or invisible characters, case folded, Cyrillic and Greek
  letters that look like a Latin letter written as that letter, every
  apostrophe and quote as `'`, `i`, `1`, `|` and dotless i as `l`, `0` as `o`,
  and runs of white space as one space. That is a hint and never a check. In
  the approval window, any change to what is shown about the device in question
  turns the buttons off again for the full delay.

### Handshake

```
host   → client   AUTH_CHALLENGE   as soon as the WebSocket opens
client → host     AUTH_RESPONSE
host   → client   AUTH_RESULT      repeated while the device waits for approval
```

All three travel in the clear in the normal `[type][len][payload]` frame, so
names and public keys are visible to anyone on the path. Nothing else is.

**AUTH_CHALLENGE payload**

| Field | Bytes | Meaning |
|---|---|---|
| version | 1 | 1 |
| caps | 4 BE | host capability bits — see "Capabilities" |
| hostNonce | 32 | random, new for every connection |
| hostEphemeral | 65 | key-exchange public key, new for every connection |
| hostIdentity | 65 | the host's long-term public key |
| nameLen, name | 1 + n | UTF-8 host name, n ≤ 64 |
| extLen, ext | 2 BE + n | extension records |

**AUTH_RESPONSE payload**

| Field | Bytes | Meaning |
|---|---|---|
| version | 1 | 1 |
| caps | 4 BE | client capability bits |
| clientNonce | 32 | random, new for every connection |
| clientEphemeral | 65 | key-exchange public key, new for every connection |
| deviceKey | 65 | the device's long-term public key |
| nameLen, name | 1 + n | UTF-8 device name, n ≤ 64 |
| extLen, ext | 2 BE + n | extension records |
| signature | 64 | by the device key |

**AUTH_RESULT payload**

| Field | Bytes | Meaning |
|---|---|---|
| status | 1 | see below |
| extLen, ext | 2 BE + n | extension records |
| signature | 64 | by the host identity key |

Extension records are `type(1) len(2 BE) value`, repeated to fill `extLen`. A
record of an unknown type is skipped. Type 0x01 is reserved for an
account-signed device certificate. Type 0x02, in an AUTH_RESULT with status
`busy` only, is a one-byte reason: 1 = the Mac needs someone to approve
Clamshell's Keychain access, 2 = remote access is switched off on that Mac. A
client shows it ("The Mac needs Keychain approval", "Remote access is off") and
keeps its busy back-off; a missing record or an unknown value is plain busy.

**What is signed.** Write `L(x)` for `u32be(length of x) ‖ x`, and call a
message's payload without its trailing 64 signature bytes its *body*.

```
client signs   "clamshell-auth-v1/client" ‖ 0x00 ‖ L(challenge) ‖ L(response body)
host signs     "clamshell-auth-v1/host"   ‖ 0x00 ‖ L(challenge) ‖ L(response) ‖ L(result body)
```

`challenge` and `response` are the whole payloads exactly as they crossed the
wire. Each signature therefore covers both long-term keys, both key-exchange
keys, both nonces and both capability sets, so nobody in the middle can swap a
key or strip a capability. For status 4 and 5 the host may never have seen a
response, so there `response` is always the empty string.

**Status**

| Status | Name | Then |
|---|---|---|
| 0 | accepted | the encrypted session starts |
| 1 | pending | the device is waiting for approval. The host keeps the socket open and repeats this result every 20 s (which also keeps a tunnel from idling the socket out) |
| 2 | denied | the device was denied or revoked. The client stops retrying and says so |
| 3 | invalid | malformed response, unsupported version or bad signature |
| 4 | busy | too many connections or devices are already waiting; try again later |
| 5 | timeout | no response within 10 s, or no approval within 10 minutes. The device stays on the waiting list, so the client reconnects and keeps waiting |

After any status other than 0 or 1 the host closes the connection.

**Host rules**

- Before `accepted`, the host accepts one message from the connection: an
  AUTH_RESPONSE of at most 4 KB, within 10 s. Anything else is ignored and
  starts nothing; anything larger closes the connection.
- The host checks the version, that both client keys are valid curve points,
  and the signature, then looks the device id up: trusted → `accepted`,
  denied → `denied`, unknown → added to the waiting list → `pending`.
- Room in three small tables is shared out by the address the connection
  came from, reduced to a group: an IPv4 address as it is, an IPv4-mapped
  IPv6 address as its IPv4 address, any other IPv6 address as its first 64
  bits, and "unknown" when there is no usable address. The group is used only
  for this, and is never a reason to trust a device. Connections that come
  through the web relay or a tunnel reach the host from 127.0.0.1, so the host
  looks at their upgrade request when the TCP peer is a trusted proxy: this
  Mac itself always, and any address or CIDR range listed in the host's
  `trustedProxies` setting (empty by default). The reported address is
  `CF-Connecting-IP`, or else the right-most `X-Forwarded-For` entry that is
  not itself a trusted proxy; with neither, or nothing that reads as an
  address, there is none. The upgrade handler cannot tell which connection a
  request belongs to, so the headers are used only when no doubt is possible:
  when a connection reaches ready, exactly one request is outstanding and this
  is the only connection not yet ready. Otherwise, and whenever a connection
  closes before it is ready, the outstanding requests are dropped and the
  connection keeps the TCP peer. The web relay applies the same rule to its
  browser and passes the result to the host in `X-Forwarded-For`.
  The TCP peer is the address the host shows and stores. A reported address
  is the client's own header, believed only far enough to pick the group, and
  the host shows it only as "the proxy reported ...; not verified". For a
  loopback peer the host says it came through a local proxy. Groups are not
  a security boundary: a process on the Mac itself can choose any group.

  | Table | Size | Share per group | May be replaced | First to go |
  |---|---|---|---|---|
  | Connections that have not answered the challenge | 32 | 8 | all | oldest |
  | Connections waiting for approval | 8 | 3 | all | oldest |
  | Devices on the waiting list | 16 | 4 | no open connection, and not seen in the last 5 minutes | least recently seen |

  An arrival is let in when there is room and its group is under its share.
  When its group is at its share, it takes the place of that group's first
  replaceable entry, or is turned away if it has none. When the table is full,
  the group holding the most entries (the one listed first on a tie) is picked:
  if the arrival's group holds fewer, the arrival takes the place of the picked
  group's first replaceable entry, or is turned away if it has none;
  otherwise it is turned away. An unanswered connection that loses its place
  is closed; a waiting connection that loses its place gets `busy` and is
  closed; a new device that is turned away gets `busy`.
- A device has one waiting connection per listener: when it connects again
  on a listener where it already waits, the earlier connection gets `busy`
  and is closed and the new one takes its place (both proved they hold the
  key).
- At most 10 new devices are listed per minute, and at most 3 per minute from
  one group; the rest get `busy`. Every verified handshake from a device
  that is already on the waiting list counts as seeing it, also when the
  answer is `busy`. A waiting device nobody approves is dropped after 24
  hours.
- The host changes its device list only while it holds the list's file lock.
  If it cannot take the lock within 2 s, or cannot open the lock file, nothing
  is changed or written and every device that asks gets `busy`. The same goes
  for a list written by a newer Clamshell (a higher list `version`, which goes
  up whenever a build changes what a field or a state means): that file is left
  exactly as it is, nobody is let in, nothing is decided, and the host's log
  and `clamshell` commands say the list was written by a newer Clamshell.
- Someone with as many addresses as a table has room, or who shares the real
  device's address, can still keep a new device off the list for as long as
  they keep trying. Devices that are already trusted are not kept out by
  that.
- Approval while the device's connection is still open sends `accepted` on
  that connection, so the session starts without a reconnect.
- Nothing a waiting connection sends is read. One that sends more than 64 KB
  while it waits is closed; its device stays on the waiting list.
- A connection that is let in replaces the session its listener was serving,
  as a new connection always has. One that is waiting, or has not answered,
  does not disturb that session.

**Client rules**

- The client waits for AUTH_CHALLENGE before sending anything. It checks the
  version and that both host keys are valid curve points; a challenge that
  fails either check is a failed connection.
- It keeps the host identity key from the first handshake that ends in a
  verified `accepted` (trust on first use) together with that host's saved
  addresses. From then on, for that host:
  - a challenge carrying a different identity key is refused and shown as a
    changed identity, with both fingerprints. Replacing the saved key takes a
    deliberate action by the user; it is never automatic;
  - no challenge within 2 s is refused too. A host that has spoken this
    protocol once never falls back to an open connection.
- For a host it has no key for, no challenge within 2 s means a host older
  than 0.12 (which sends nothing until HELLO). The client may then send HELLO
  in the clear and carry on as before 0.12, with every capability bit taken
  as 0, and it shows the session as unverified. If a challenge arrives after
  the client has sent HELLO (a slow link, not an old host), the client closes
  the connection and connects again, this time waiting up to 10 s for the
  challenge.
- Every AUTH_RESULT's signature is checked against the `hostIdentity` from the
  challenge. A result that does not verify is treated as a failed connection,
  whatever its status says.
  The repeats sent while a device waits are the same signed bytes each time;
  the client verifies every one and does not treat a repeat as a replay.
- While `pending`, the client shows the host's name and both fingerprints so
  the user can compare them with what the host shows before approving.

### Session keys and SECURE

```
th    = SHA-256( L(challenge) ‖ L(response) )
Z     = ECDH on P-256 between the two key-exchange keys: the shared point's X coordinate, 32 bytes
okm   = HKDF-SHA256( ikm = Z, salt = hostNonce ‖ clientNonce,
                     info = "clamshell-session-v1" ‖ th, length = 64 )
k_h2c = okm[0 ..< 32]     host → client
k_c2h = okm[32 ..< 64]    client → host
```

After `accepted`, every message in both directions is one SECURE message:

```
SECURE payload = AES-256-GCM( key, nonce, plaintext, no additional data ) ‖ tag(16)
plaintext      = one whole inner message: [type][4-byte BE length][payload]
nonce          = 0x00000000 ‖ u64be(counter)
```

Each direction has its own key and its own counter. The counter starts at 0,
goes up by one per SECURE message and is not sent; the WebSocket keeps
messages in order. A side closes the connection when a SECURE message fails to
decrypt, when the inner message is itself SECURE or an AUTH message, when any
message other than SECURE arrives after `accepted`, or before its counter
could pass 2^48. Reconnecting runs the handshake again and gives fresh keys.

HELLO and everything after it are unchanged; they simply travel inside SECURE.
The first inner message from the host is HOST_INFO.

The host reads SECURE payloads of at most 4 MB (4,194,304 bytes) from a
client; a larger one closes the connection. Nothing a client sends comes near
that: the largest are CLIPBOARD at 1 MB and FILE_DATA at 64 KB.

**Reference vectors.** `tests/vectors/auth-v1.json` holds one complete
exchange from fixed test keys: the three handshake payloads, both signature
inputs, the ids and fingerprints, the transcript hash, the shared secret, both
session keys and four SECURE frames. ECDSA signatures are randomized, so an
implementation checks that the recorded ones verify; every other value must
come out byte for byte. Each client and host is tested against this file.

### Hosts that do not require approval

Approval is on by default (capability bit 0 in the challenge). A host with it
turned off still sends the challenge. A client that answers is accepted
whatever its key and gets the encrypted session; a client that sends HELLO in
the clear instead is served the way hosts before 0.12 served it. Such a host
is only as safe as its network, as before.

With approval off, a clear HELLO is accepted in place of the AUTH_RESPONSE, and
a device that is denied is let in like any other; the denial is kept and counts
again when approval is turned back on. The AUTH_RESPONSE may be at most 4096
bytes; a connection that is waiting for approval may send up to 64 KB, which is
ignored, before it is closed. Approval is on unless the stored setting
`requireDeviceApproval` is the boolean false or the integer 0: any other value
or type, or none, leaves it on. A change made from outside (`defaults write`) is
noticed within 5 s; the switch in the host's Devices menu takes effect at once.

A host with approval on never answers a HELLO in the clear: the connection is
closed when the 10 s response deadline passes. Clients older than this section
therefore cannot use it.

### Approving a device

A waiting device is approved or denied in one of four ways: on the host's own
screen, on the host's command line (`clamshell approve <id or fingerprint>`,
usable over SSH), from a connected trusted device with the two messages
below, or from the owner's phone (see "Approval from a phone"). Revoking a trusted device makes it `denied` and closes its live
connections; forgetting a device removes it, so it may ask again.

A device that is denied can be approved after all in two places only: the
Devices menu's "Approve…" on the host and `clamshell approve`. A
DEVICE_DECISION acts on waiting devices only.

Both messages travel inside SECURE and only when both sides set capability bit
4. The host sets bit 4 in every challenge, so the bit does not say who may
decide; the rule that counts is that the host acts on a DEVICE_DECISION only
from a device that is trusted at that moment (see below).

- **DEVICE_PENDING** (host → trusted client), UTF-8 JSON, sent after
  `accepted` when devices are waiting and again whenever the list changes
  (an empty list means none are):
  `{"devices":[{"id":"<64 hex>","name":"iPhone","fingerprint":"AB12-CD34-EF56-7890","firstSeen":1794000000,"address":"192.168.1.23"}]}`
  `address` is the TCP peer as the host saw it. `reportedAddress` is added
  only when a proxy on the host claimed another one (see "Host rules"); it is
  not verified and a client shows it only as the proxy's claim.
- **DEVICE_DECISION** (trusted client → host), UTF-8 JSON:
  `{"id":"<64 hex>","decision":"approve"}` or `"deny"`. The client sends it
  only after showing the name and fingerprint and getting an explicit answer
  from the user. The host replies with a fresh DEVICE_PENDING and shows on its
  own screen which device made the decision.

A trusted device can already type and click on the host, so letting it approve
another device gives it nothing it could not do through the host's own
approval window.

The host applies a DEVICE_DECISION only if the device that sent it is trusted in
the device list as it is read for that same change. A device that was revoked a
moment earlier, by the host's own menu or by `clamshell revoke` in another
process, therefore changes nothing: the decision is dropped and the host closes
that device's session, as it does for any revoked device. The host notices a
change another process made to the list within moments; if it cannot watch the
folder it says so once in its log and reads the list again every 5 s.

The host's approval window does not come back as fast as devices can ask. When
a question it raised by itself ends (approved, denied or closed), it stays away
for the shorter of 15 minutes and 20 s times 2 to the power n, and n goes up by
one; n starts over after an hour in which the window raised no question. Closing
also sets every waiting device aside; approving or denying does not, and the
others come up when the quiet time is over. Three such questions in a row that
end in Deny or closing, the third within 10 minutes of the first, keep the
window away for 12 hours. A device the user picks in the host's menu is shown
at once, and its answer changes neither n nor the quiet time. While the window
stays away, waiting devices stay in the Devices menu and the menu-bar icon shows
that devices are waiting.

### Approval from a phone

Off unless set up. When a new device starts waiting, the Mac sends one Pushover
notification to the owner: the device name, where it came from (worded as the
Devices list words it) and its fingerprint, with a link
`<base URL>/approve/<token>` as the notification's URL. The notification asks
Pushover to drop it after 10 minutes.

Settings (`defaults`, domain `com.frindle.clamshell`; the host's Devices menu
has the switch):

- `phoneApprovalEnabled` (bool): the switch "Approve New Devices from a Phone
  (Pushover)".
- `phoneApprovalBaseURL` (string): the public `https://host[:port]` the web
  server is reachable at, with no path. Nothing is built in.
- `phoneApprovalKeychainService` (string, optional): the Keychain service name,
  `clamshell-phone-approval` if unset. Two generic-password items under it hold
  the secrets, never the preferences, the log or the diagnostics: account
  `pushover-app-token` (the Pushover application token) and account
  `pushover-user-key` (the owner's user key).

  `security add-generic-password -s clamshell-phone-approval -a pushover-app-token -w`

If any setting or item is missing, nothing is sent.

The token is 32 bytes from `SecRandomCopyBytes` (64 hex digits), bound to one
device id, good for one decision and for 10 minutes, and void as soon as that
device is decided any other way. Only its SHA-256 is held, in memory, compared
in constant time; a restart voids every token.

`GET /approve/<token>` shows the device name, address and fingerprint in large
type, "Compare with the fingerprint the device shows", and Approve and Deny
buttons. It never decides anything. The buttons POST
`decision=approve|deny` (form-encoded) to the same path; the POST is refused
unless it is a form post whose `Origin` and `Sec-Fetch-Site`, when present,
say same-origin. Pages carry `Cache-Control: no-store` and
`Referrer-Policy: no-referrer`. A wrong, used, expired or voided token, a
refused POST and a client that has failed 10 times in 10 minutes all get the
same `404` page. The decision is applied with the store's own decide path,
recorded as decided by `phone`; the Devices list, the notification and the
approval window say "from a phone", as they say "from the command line".

### The Windows host

A Windows host (`WindowsServer/`) takes part in the handshake above and reports
`kind` `windows` in HOST_INFO. Devices are approved on the host only: in its
approval window, in the Devices section of its Settings, or with its command
line (`ClamshellServer approve <id or fingerprint>`, also `devices`, `deny`,
`revoke` and `forget`). It does not accept DEVICE_DECISION, so it sets
capability bit 4 to 0 in every challenge and sends no DEVICE_PENDING.

Its host identity key is a P-256 key in the current user's Windows CNG key
store (software provider, key name `Clamshell.Host.IdentityKey.v1`, not
exportable). Its device list is the file `devices.dat` under
`%LOCALAPPDATA%\Clamshell` (or the folder in `CLAMSHELL_STATE_DIR`), protected
with the current user's DPAPI, with a lock file `devices.lock` beside it; the
host and the command line take that lock for every change, and a running host
notices a change made by the command line. Both are tied to the Windows user
the host runs as: another process of the same user can use that user's key and
read that user's list, as on the Mac. If either cannot be opened the host
serves nothing. Approval is on unless the value `RequireDeviceApproval` under
`HKEY_CURRENT_USER\Software\Clamshell` is the DWORD 0; when it is off the tray
tooltip and menu say so and the host logs it at start. A host behind a reverse
proxy lists the proxies it trusts in the multi-string value `TrustedProxies`
there (loopback is always trusted); the address a proxy reports is used to
group connections and is shown only as "the proxy reported X; not verified"
next to the TCP peer, never as the address.

Same-user risk. Approval protects against other machines and other users, not
against code already running as the same Windows user. Any process of that user
can approve a waiting device itself (the `approve` command, or by writing the
device list), and can set `RequireDeviceApproval` to 0 in that user's registry
hive, after which the unapproved HELLO path is open on every interface the host
listens on. An administrator can do the same. Other non-administrator users
cannot. The off state is made visible (tooltip, menu, log) but not prevented.

### Browser client

The browser client reaches the stream through the web server's WebSocket
relay. The handshake runs end to end through the relay, which is trusted no
more than any other network hop. Browsers offer WebCrypto only to pages loaded
over HTTPS (or from `localhost`), so the browser client needs the tunnel
hostname or the host's own LAN certificate; it cannot authenticate from a
plain `http://` page.

The browser client keeps the host's identity key in the browser's own storage,
the same trust on first use as any other client. That key protects a saved
Mac against a changed host or a relay that tampers with the handshake after
the first connection. It does not protect against whoever serves the page and
its scripts (`auth.js` included): they can skip the check or read what the
page can read. The first connection to a Mac is not protected either.

## Capabilities

The `caps` field of AUTH_CHALLENGE says what the host does; the same field in
AUTH_RESPONSE says what the client does. A side uses a feature only when the
other side set its bit. Both fields are covered by both signatures. A host
that sent no challenge has every bit 0.

| Bit | Name | Meaning |
|---|---|---|
| 0 | `approvalRequired` | host only: unknown devices must be approved |
| 1 | `relativeMouse` | host accepts INPUT_MOUSE_RELATIVE |
| 2 | `textInput` | host accepts INPUT_TEXT |
| 3 | `extraButtons` | host accepts mouse buttons 2–4 |
| 4 | `deviceApproval` | host: trusted devices may approve others. Client: can show the approval prompt |
| 5 | `fileTransfer` | both: can send and receive files — see "File transfer" |
| 6 | `peripherals` | host: accepts peripherals attached to the client. Client: can send them — see "Peripherals attached to the client" |
| 7 | `restart` | host: accepts RESTART_REQUEST. Client: can send one |
| 8 | `loginCredentials` | host: this host is the login-window agent and types a saved login for a client. Client: can send one — see "Login window" |
| 9 | `appHost` | both: speaks Window Handoff v3 (app-host) on the control connection — see "Window Handoff v3" |

Unassigned bits are sent as 0 and ignored on receipt.

## Login window (LOGIN_CREDENTIALS)

While nobody is logged in, the host is the login-window agent
(`clamshell loginwindow install`). It sets capability bit 8 in AUTH_CHALLENGE,
which is how a client knows the host is at the login window; the normal app
never sets it. The agent always requires device approval.

A client that holds a saved login for this Mac and sets bit 8 itself may send
one LOGIN_CREDENTIALS message, as a SECURE inner message:

```
{"v":1,"kind":"login","user":"<account name>","password":"<password>"}
```

The host types the name, Tab, the password and Return into the login window,
the same way as INPUT_TEXT. Rules:

- Accepted only from a trusted device on its encrypted session (phase
  accepted). A session in the clear never types a password.
- `user` and `password` are 1 to 512 bytes of UTF-8 each, with no control
  characters (a tab or line break would be typed as a key press); the payload
  is at most 2048 bytes. Anything else is ignored.
- At most one message every 3 seconds per listener; extra messages are ignored.
- The host never logs, stores or echoes the contents.
- No reply. The client sees the result in the video.

The web client sets bit 8 and, when the host advertises it, offers a "Log in"
form (a real username/password form, so a password manager can fill it). It
sends one message per submit, waits at least 3 seconds between sends, checks
the field rules above before sending, never stores the password, and removes
the form after sending.

## Host and client info (HOST_INFO / CLIENT_INFO)

Both are UTF-8 JSON inside SECURE. Unknown fields are ignored.

**HOST_INFO** (host → client) is the first message of the encrypted session:

```json
{
  "name": "Studio",
  "kind": "mac",
  "version": "0.12.0",
  "hostId": "<64 hex>",
  "display": 0,
  "displays": [
    {"index": 0, "name": "Display A", "primary": true,
     "urls": ["ws://192.168.1.20:5903", "wss://mac.example.com/ws/a"]},
    {"index": 1, "name": "Display B",
     "urls": ["ws://192.168.1.20:5904", "wss://mac.example.com/ws/b"]}
  ]
}
```

`kind` is `mac`, `windows` or `kvm`. `display` is the index this connection
serves. `urls` lists every address the host knows for a display: its own LAN
and VPN addresses, then the ones clients have reported. With this a client
that reached Display A by any route can open Display B without the user typing
a second address, and can keep a host's LAN, VPN and tunnel addresses together
under one saved entry, trying them in turn. Every address still has to pass
the handshake with the saved identity key, so a wrong or hostile entry can
waste a connection attempt but cannot stand in for the host.

An optional `peripherals` array, for example `["gamepad","midi"]`, lists the
kinds of peripheral the host accepts (see "Peripherals attached to the
client"). A client leaves the other kinds out of what it offers the user.

**CLIENT_INFO** (client → host), sent once after `accepted`:

```json
{"url": "wss://mac.example.com/ws/a", "app": "ios", "version": "1.5.0"}
```

`url` is the address the client actually connected to. That is how a host
learns the tunnel or VPN names it is reachable under, which it cannot see for
itself. The host keeps a reported URL only if it is `ws://` or `wss://`, at
most 256 bytes, with no user info, query or fragment; it keeps at most 16 per
display, dropping the one unused longest; and it hands reported URLs only to
devices the user approved.

## Discovery (Bonjour)

The host advertises `_clamshell._tcp` on the primary display's port, with TXT
records `v` (the handshake version, `1`), `id` (the first 16 characters of the
host id), `name` and `kind`. These are hints for building a list of nearby
hosts. They prove nothing: a discovered host still has to pass the handshake,
and one whose `id` matches a saved host must present that host's saved key.

A host can be told not to advertise. Advertising is also separate from
listening: a host that is not advertising, by choice or because the system
refused it, still answers a client that has its address.

Off the LAN there is nothing to browse, so a client reaches a host through an
address saved from an earlier HOST_INFO, or one typed in once.

## File transfer (FILE_OFFER / FILE_ANSWER / FILE_DATA / FILE_END)

*Status: built in one direction. The Mac host receives files (it sets bit 5,
and stores what it is sent in `~/Downloads/Clamshell`, with a switch in its
menu to turn receiving off) and the iOS app sends them (it sets bit 5 and
answers any offer from the host with "declined"). Not built yet: the web and
Windows clients and the Windows host, and files from the Mac to the iPad.*

Either side can send the other a file. This is how something on a drive
plugged into the client reaches the host: the client's file picker can open
it, so the client can send it. All four messages travel only inside SECURE and
only when both sides set capability bit 5. A session without the handshake
never transfers files.

```
sender   → receiver   FILE_OFFER    {"id":7,"name":"scan.pdf","size":1048576,"modified":1794000000}
receiver → sender     FILE_ANSWER   id, status
sender   → receiver   FILE_DATA     id, bytes      repeated, in order
sender   → receiver   FILE_END      id, 0          every byte sent
receiver → sender     FILE_END      id, 0          stored
```

- `id` is chosen by the sender (below 2^32) and is unique among the transfers
  it has open on this connection. The two directions number separately.
- `name` is a file name, at most 255 bytes of UTF-8. `size` is the exact
  length in bytes, a whole number from 0 to 2^53 − 1. `modified` (seconds
  since 1970) is optional, and left out by the receiver when it is not a
  whole number. Fields the receiver does not know are skipped.
- An offer that is not a JSON object, or has no usable `id`, is ignored, and
  so is one that reuses an id still open. An offer with a usable `id` but a
  missing or wrong `name` or `size` is answered with status 1.
- FILE_ANSWER status: 0 accept, 1 declined, 2 too large or no room, 3 too many
  transfers open, 4 transfers are turned off.
- FILE_DATA carries the next bytes of the file, at most 64 KB per message.
  There is no offset: messages arrive in order. The sender hands the network
  one FILE_DATA at a time and lets waiting input and video go first, so a
  large file never holds them up by more than one message. On a slow link it
  uses smaller pieces. A FILE_DATA with no bytes is ignored. One with more
  than 64 KB fails the transfer.
- FILE_END status: 0 complete (from the sender: every byte was sent; from the
  receiver: the file is stored), 1 cancelled, 2 failed. Either side may send 1
  or 2 at any time; the transfer is then over and the receiver discards what
  it has. FILE_DATA for a transfer that is no longer open is ignored.
- Closing the connection ends every transfer on it. Nothing resumes in this
  version.

**Receiver rules.** They matter most on the host, where the sender is a remote
device.

- The name is never used as a path. The receiver keeps what follows the last
  `/` or `\`, removes control characters, `:` and invisible format
  characters (including U+2028, U+2029 and U+3164), replaces look-alike dots
  and slashes (such as U+FF0E, U+FF61, U+3002 and U+2215) with `_`, then
  removes dots and blanks from the start and from the end, and uses `file` if nothing
  is left. A receiver also changes whatever its own file system refuses (on
  Windows the characters `< > " | ? *`, trailing dots, and device names such
  as `CON`).
- The receiver never overwrites. A name already taken gets ` 2`, ` 3`, …
  before its extension (the part from the last dot on, unless that dot is the
  first or last character), and the final name is claimed in one step that
  cannot replace an existing file.
- The host stores received files in one folder (`~/Downloads/Clamshell` by
  default). It writes each file under a temporary name and renames it only
  after the sender's FILE_END 0, with exactly `size` bytes received. More
  bytes than `size`, or a FILE_END 0 after fewer, fails the transfer and
  removes the partial file.
- The host marks a received file as downloaded (the quarantine attribute on
  macOS, the zone identifier on Windows), so the system's usual checks apply
  when someone opens it. The host never opens or runs a received file.
- At most 4 transfers are open per connection. An offer larger than the free
  space, less a reserve, is answered with status 2. A transfer that receives
  nothing for 60 s fails.
- A client that receives a file asks the user where to save it before it
  answers 0.

**Reference vectors.** `tests/vectors/file-transfer-v1.json` holds the message
bytes, offers a receiver must accept, decline or ignore, the stored name for a
range of offered names, and the receiver's handling of one transfer step by
step (complete, too many bytes, ended early, cancelled).

## Peripherals attached to the client (PERIPHERAL_*)

*Status: built for game controllers from the iOS app to the Mac host. The Mac
host sets bit 6, lists `gamepad` in HOST_INFO's `peripherals`, and maps a
controller to keys and the pointer, answering status 1 (it has no virtual
controller to offer, so it never answers status 0). The iOS app sets bit 6 and
sends its controllers. Not built yet: MIDI instruments, a virtual controller on
the host, rumble from the host to the controller, the web and Windows clients
and the Windows host, and sending a peripheral from the Mac to the iPad.*

A game controller or MIDI instrument plugged into the client, or paired with
it, can be used on the host as though it were attached there. This is not USB
passthrough: the client reads the peripheral through its own system and sends
what it reads, and the host builds a matching virtual device of a kind it
already knows. A peripheral the client's system gives an app no way to read
cannot be sent.

"Peripheral" never means the client itself, which is the *device* of the
handshake above. Keyboards, mice and trackpads are not peripherals in this
sense either: what they do travels as INPUT_* messages. Files on an attached
drive travel by file transfer. A security key is used through remote
confirmation (below), not sent as a peripheral.

All five messages travel only inside SECURE and only when both sides set
capability bit 6. A session without the handshake never carries a peripheral.

```
client → host     PERIPHERAL_ATTACH   {"id":1,"kind":"gamepad","name":"DualSense Wireless Controller","rumble":true}
host   → client   PERIPHERAL_STATUS   id, status
client → host     PERIPHERAL_INPUT    id, report      whenever its state changes
host   → client   PERIPHERAL_OUTPUT   id, report      when the host has something for it
client → host     PERIPHERAL_DETACH   id
```

- `id` is chosen by the client, from 1 to 2^32 − 1, and is never used twice on
  one connection, so a late message about a peripheral that has gone cannot be
  taken for one about its replacement.
- `kind` is `gamepad` or `midi`. More kinds will follow. HOST_INFO's
  `peripherals` array says which ones a host accepts.
- `name` is for display only: at most 64 bytes of UTF-8, cleaned the way
  device names are.
- A client with several connections to one host attaches a peripheral on only
  one of them.
- PERIPHERAL_STATUS answers every PERIPHERAL_ATTACH and is sent again if the
  answer changes later:

  | Status | Meaning |
  |---|---|
  | 0 | attached: the host presents a device of this kind |
  | 1 | attached as keys and pointer (`gamepad` only): the host cannot present a game controller and turns its reports into key presses and pointer movement instead |
  | 2 | this host does not accept this kind |
  | 3 | too many peripherals |
  | 4 | peripherals are turned off |
  | 5 | removed: the host could not create it, or has taken it away |

- The client sends PERIPHERAL_INPUT only after status 0 or 1. After any other
  status the id is finished. A message for an id that is not attached is
  ignored.

### Game controllers (`gamepad`)

A PERIPHERAL_INPUT report is the controller's whole state, not a change:

```
id(4 BE), buttons(4 BE), leftTrigger(1), rightTrigger(1),
leftX(2 BE), leftY(2 BE), rightX(2 BE), rightY(2 BE)          18 bytes
```

`buttons` is a bit field, bit 0 the least significant. The numbering is that
of the W3C "standard gamepad", which goes by where a button sits, not by what
is printed on it:

| Bit | Button |
|---|---|
| 0–3 | face buttons: bottom, right, left, top (A, B, X, Y on an Xbox controller; Cross, Circle, Square, Triangle on a PlayStation one) |
| 4, 5 | left and right shoulder |
| 6, 7 | always 0: the triggers travel as values |
| 8, 9 | the centre pair: left (View, Share, Select) and right (Menu, Options, Start) |
| 10, 11 | left and right stick pressed in |
| 12–15 | d-pad up, down, left, right |
| 16 | Home / Guide |
| 17–31 | 0 until assigned |

- Triggers run from 0 (released) to 255 (fully pressed). A trigger that is
  only a switch sends 0 or 255.
- Stick values are signed 16-bit, −32767 to 32767, 0 at the centre. Positive X
  is right and positive Y is **down**, as in the W3C layout. GameController
  and XInput count up as positive, so clients built on them negate Y. −32768
  is not used.
- The client sends a report when the state changes, at most 250 a second for
  one controller, and always finishes with the latest state. A host that is
  sent more may skip some, but always applies the last.
- The client also sends a report at least once a second while nothing changes.
  A host that receives none for 3 s puts the controller at rest (no buttons,
  triggers 0, sticks centred) until the next one arrives, so a client that
  froze with a stick held over cannot keep it there. A client about to stop
  reading a controller for a while (its app leaves the foreground) sends the
  at-rest report first.
- A report longer than 18 bytes is accepted and the extra bytes ignored, which
  leaves room for later fields. A shorter one is ignored.

Example: the bottom face button and d-pad left held, the right trigger half
pressed and the left stick fully right, for peripheral 1. The whole message,
before SECURE wraps it:

```
53 00000012  00000001 00004001 00 80 7FFF 0000 0000 0000
```

**Rumble.** When PERIPHERAL_ATTACH carried `"rumble": true`, the host may send
PERIPHERAL_OUTPUT: `id(4 BE), strong(1), weak(1), durationMs(2 BE)`. `strong`
is the low-frequency motor and `weak` the high-frequency one, each 0–255. The
client runs them for the duration and then stops by itself. A new report
replaces the one before, and 0, 0 stops at once. The client never runs longer
than 5 s on one report, so a stop that never arrives cannot leave the motors
on.

### MIDI instruments (`midi`)

PERIPHERAL_ATTACH adds two fields: `"sends": true` when the instrument
produces MIDI (carried to the host by PERIPHERAL_INPUT) and `"receives": true`
when it accepts MIDI (carried from the host by PERIPHERAL_OUTPUT). At least
one is true. The host shows a virtual MIDI source, destination or both under
the peripheral's name.

A report in either direction is `id(4 BE)` followed by MIDI 1.0 bytes: one or
more whole messages, each with its own status byte (no running status), at
most 64 KB in all. A System Exclusive message has to fit in one report. A
report that does not parse as whole MIDI messages is dropped.

Reports are played as they arrive. There are no timestamps in this version, so
timing carries the network's jitter: fine for playing and controlling, not for
recording that has to be sample-accurate.

When a MIDI peripheral detaches or its connection ends, the host ends any note
it left sounding and releases the sustain pedal. The client does the same
toward the instrument.

### Host rules

They matter because a remote device is asking the host to create an input
device.

- The host builds only the kinds it implements, each from a description fixed
  in the host. A client never supplies a HID report descriptor, raw HID
  reports, or vendor and product numbers for the host to adopt. A virtual game
  controller has buttons, triggers and sticks and nothing else: it cannot type
  or move the pointer.
- With status 1 the host itself turns reports into the key and pointer events
  that INPUT_* messages produce, under every rule that applies to those. Which
  control does what is a host setting.
- At most 4 game controllers and 8 peripherals in all per connection. Beyond
  that the answer is status 3.
- A peripheral never outlives its connection. On PERIPHERAL_DETACH, and when
  the connection or the session ends for any reason, the host puts the
  peripheral at rest and removes the virtual device.
- The host shows which peripherals are attached and which device brought each
  one. The user can remove one there (status 5) or turn peripherals off
  (status 4).
- On macOS a virtual game controller needs Apple's
  `com.apple.developer.hid.virtual.device` entitlement in the host's
  signature. A host without it answers a game controller with status 1 or 2.
  MIDI needs no entitlement.

**Reference vectors.** `tests/vectors/peripheral-v1.json` holds game
controller states with the exact message bytes for each, plus rumble and
status messages. Every encoder and decoder must reproduce them byte for byte.

## Future (not in v1)

H.264/HEVC negotiation beyond the single byte, multi-touch
gestures. Cloudflare Access, if used, is enforced at the
edge — via WARP-enrolled devices or an Access policy that trusts the
connection at the network layer — not by app-level Service Token headers (the
apps send no `CF-Access-*` headers); it is a second gate in front of the
device authentication above, not a replacement for it. Also on the roadmap, explicitly
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

**Not implemented:** the control-connection / HANDOFF_* multiplexed protocol
below, drag-trigger detection, and AX-based window hiding on the Mac side
(blocked, see above). Windows-side window capture (the
`Windows.Graphics.Capture` path described in v2 below) — needed before this
viewer can be tested against a real Windows-hosted window stream, or before
Windows can be a window-handoff *source* at all.

## Window Handoff v2 (PROPOSED — not implemented, not a contract yet)

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
The single-window streaming pipeline above (fixed port, explicit selection)
is the capture/encode/stream leg this whole design will eventually reuse; the
control-connection/HANDOFF_* messages below are the still-unbuilt multiplexed
discovery/trigger layer on top of it.

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

## Window Handoff v3 (app-host) (SPECIFIED — wire format implemented in `DeskProtocol/`, nothing on the wire yet)

Goal: an app that runs on another Mac shows up on the operator as its own
windows, Dock icon and menu bar (the "Desk" viewer, see the execution plan,
section 3.1). v3 keeps v1 framing and adopts the v2 proposal's messages
0x40–0x49, then adds the app-level messages below. The reference encoder and
decoder is the Swift package `DeskProtocol/` (pure logic, tested on Linux);
this section and that package must change together, and its golden-byte tests
pin the layouts below.

**Connection.** One control connection per operator–host pair on port 5910
(the v2 proposal's port), v1 framing: `[type 1][length 4 BE][payload]`, inside
the same device authentication and `SECURE` envelope as v1 (so the open v2
question about control-connection auth is answered: it is authenticated and
encrypted exactly like a stream connection). A side sends v3 messages only
after the other set the `appHost` capability bit (bit 9). Video, audio and
input for a window ride the same connection, tagged by window id. Every Mac
runs both roles (host service and viewer), so either side may send any
message whose direction below says "both".

**Conventions.** Integers and Float32 are big-endian. `str8` is a 1-byte length
then UTF-8 (v2 messages); `str16` is a 2-byte length then UTF-8 (v3 messages).
An encoder refuses an over-long string, a list over its limit and a cursor image
over 64 KB; it never cuts. Decoders reject non-finite floats and values outside
the ranges below, never read past the payload, and cap list sizes (4096
entries), menu depth (16) and menu nodes (4096). Bytes after the last
defined field of a fixed-layout message are ignored (room for later fields).
A type byte a side does not know is skipped, never fatal. `appId` is assigned by
the host and is stable for the life of the connection; `windowId` is the host's
window number, never 0, and is not reused while the connection lasts: a
WINDOW_ADDED for an id that was added before, even if it has closed, is a
protocol error. Coordinates in
v3 geometry messages are points on the host's hosted display with the backing
`scale` alongside; input coordinates are normalized 0..1 in the window's own
bounds, as in v2.

### Adopted from v2 (payloads unchanged except where noted)

| Type | Name | Direction | Payload |
|------|------|-----------|---------|
| 0x40 | WINDOW_LIST_REQUEST | both | empty |
| 0x41 | WINDOW_LIST_RESPONSE | both | count(2 BE), then per window: windowId(4), title(str8), appName(str8), widthPx(4), heightPx(4) |
| 0x42 | HANDOFF_BEGIN | source → dest | windowId(4), crossX(F32), crossY(F32), title(str8), appName(str8), widthPx(4), heightPx(4) |
| 0x43 | HANDOFF_ACCEPT | dest → source | windowId(4) |
| 0x44 | HANDOFF_REJECT | dest → source | windowId(4), reason(str8) |
| 0x45 | WINDOW_STREAM_START | dest → source | windowId(4) |
| 0x46 | WINDOW_STREAM_FRAME | source → dest | windowId(4), then v1 VIDEO_FRAME payload: flags(1), ptsMicros(8), NAL data |
| 0x47 | WINDOW_INPUT_MOUSE_MOVE | dest → source | windowId(4), x(F32), y(F32) |
| 0x48 | HANDOFF_RETURN | dest → source | windowId(4) |
| 0x49 | WINDOW_CLOSED | source → dest | windowId(4) |
| 0x4A | WINDOW_INPUT_MOUSE_BUTTON | dest → source | windowId(4), button(1), down(1), x(F32), y(F32) |
| 0x4B | WINDOW_INPUT_KEY | dest → source | windowId(4), macKeyCode(2), down(1), cgEventFlags(8) |
| 0x4C | WINDOW_INPUT_SCROLL | dest → source | windowId(4), dx(F32), dy(F32) |

The v2 table gave one type (0x47) to four input messages. v3 gives each its own
byte: 0x47 is the move, 0x4A–0x4C the other three.

### New in v3

| Type | Name | Direction | Payload |
|------|------|-----------|---------|
| 0x70 | APP_LAUNCH | operator → host | requestId(4), bundleId(str16), activate(1), count(2), then per target: str16 (a URL or a path on shared storage) |
| 0x84 | APP_LAUNCH_RESULT | host → operator | requestId(4), status(1: 0 started or already running, 1 not installed, 2 refused, 3 failed), appId(4) |
| 0x82 | APP_LIST_REQUEST | both | empty |
| 0x71 | APP_LIST | both | count(2), then per app: appId(4), bundleId(str16), name(str16), pid(4, signed, −1 if not running), windowCount(2), residentMB(4), running(1). Sent on request and whenever the set changes |
| 0x72 | WINDOW_ADDED | host → operator | windowId(4), appId(4), kind(1: 0 main, 1 sheet, 2 popover, 3 menu, 4 tooltip, 255 other; unknown values read as other), parentId(4, 0 none), title(str16), x, y, width, height, scale (F32 ×5) |
| 0x73 | WINDOW_MOVED | host → operator | windowId(4), x(F32), y(F32) |
| 0x74 | WINDOW_RESIZED | host → operator | windowId(4), width(F32), height(F32), scale(F32) |
| 0x75 | WINDOW_TITLE | host → operator | windowId(4), title(str16) |
| 0x76 | WINDOW_RESIZE_REQUEST | operator → host | windowId(4), width(F32), height(F32) |
| 0x77 | CHILD_WINDOW | host → operator | windowId(4), parentId(4), offsetX(F32), offsetY(F32), kind(1) — a sheet, popover, menu or tooltip, positioned relative to its parent |
| 0x78 | MENU_TREE | host → operator | appId(4), generation(4), then a list: count(2), per item: itemId(4), title(str16), flags(1: bit 0 enabled, bit 1 checked, bit 2 separator), keyCode(2, 0xFFFF none), modifiers(4, low CGEventFlags), then the item's child list in the same form |
| 0x79 | MENU_INVOKE | operator → host | appId(4), generation(4), itemId(4). The host ignores it if its generation is older than the menu it last sent |
| 0x7A | CURSOR_SHAPE | host → operator | windowId(4), shape(1: 0 arrow, 1 I-beam, 2 pointing hand, 3 crosshair, 4 resize left-right, 5 resize up-down, 6 open hand, 7 closed hand, 8 not allowed, 255 custom); for custom only: hotspotX(2), hotspotY(2), PNG bytes (at most 64 KB). A shape byte the receiver does not know is drawn as the arrow and the session stays open |
| 0x7B | PASTEBOARD_OFFER | both | generation(4), count(1), per entry: uti(str16), size(8). The pasteboard changed; nothing is copied yet |
| 0x7C | PASTEBOARD_FETCH | both | generation(4), uti(str16) — the receiving side pastes and asks for the bytes |
| 0x83 | PASTEBOARD_DATA | both | generation(4), uti(str16), offset(8), total(8), bytes. One chunk of the answer to a fetch: bytes `offset ..< offset+n` of an item of `total` bytes, n at most 65,536. The sender sends the chunks in order, with other traffic allowed between them. An empty item is one chunk with total 0 |
| 0x7D | FILE_PUSH | operator → host | requestId(4), windowId(4, drop target or 0), dropX(F32), dropY(F32), name(str16). `name` is the file's name in the host inbox, a bare file name and never a path. It is not empty, at most 255 bytes, has no `/`, `\`, `:`, `< > " | ? *`, no control character (C0, DEL or C1, so no NUL), no invisible, bidirectional or line-separator character (U+00AD, U+200B–U+200F, U+2028–U+202E, U+2060–U+206F, U+FEFF, U+3164 and similar), no look-alike dot or slash (U+FF0E, U+3002, U+2215 and similar), does not start with `.` or a blank, does not end with `.` or a blank, and is not a Windows device name (`CON`, `NUL`, `COM1`…). A receiver that gets a name breaking the rule closes the connection (see "known type fails to decode" below); it does not drop just that message. The rule is at least as strict as the v1 receiver's name clean-up (every Unicode format character, any Unicode blank at either end, the look-alike slashes U+2571, U+2216, U+FF3C, U+FE68, U+29F5 as well), so that clean-up has nothing to change. The bytes follow as v1 FILE_OFFER / FILE_DATA / FILE_END; that offer's `name` must equal this `name` byte for byte (the receiver uses the FILE_PUSH name and answers any other offer with status 1), so the v1 receiver sanitising has nothing to change |
| 0x7E | FILE_PULL | operator → host | requestId(4), fileId(4) — fetch a file the host promised in FILE_PROMISE; the host answers with a v1 FILE_OFFER. The host looks the id up in its own table and ignores an id it did not issue; no path ever crosses the wire in this direction |
| 0x85 | FILE_PROMISE | host → operator | count(2), then per file: fileId(4), name(str16, same rule as FILE_PUSH), size(8). The host issues a fresh opaque fileId for each file it offers and keeps the real location to itself |
| 0x7F | AUDIO_FRAME (per app) | host → operator | appId(4), ptsMicros(8), one AAC-LC access unit as v1 AUDIO_FRAME |
| 0x80 | BADGE | host → operator | appId(4), text(str16); empty text clears the badge |
| 0x81 | NOTIFY | host → operator | appId(4), notificationId(str16), title(str16), subtitle(str16), body(str16), sound(1) |

Rules:

- A frame whose length field is over 4,000,000 bytes is a protocol error: the receiver closes the connection and does not try to resynchronise. A sender never builds such a frame. The limit sits under the 4,194,304-byte cap on a SECURE payload ("The host reads SECURE payloads of at most 4 MB"), so no v3 frame can close the session by size. Anything bigger is split: clipboard data into PASTEBOARD_DATA chunks, files into the v1 64 KB FILE_DATA pieces. A video frame that would not fit is dropped by the sender and the next keyframe replaces it.
- Value ranges. Mouse and button coordinates are 0..1 (the sender clamps). Positions, offsets, drop points and scroll deltas are within ±1,000,000. Width and height in points are 0..100,000; in pixels 0..65,536. Scale is 0.1..16. Anything else is a decode error and an encoder refuses to send it.
- Window ids. Both sides track the ids announced on the connection. The host ignores input, WINDOW_STREAM_START, resize requests and handoff messages for an id it has not announced (a WINDOW_ADDED, or a WINDOW_LIST_RESPONSE it sent) or that has closed, and the viewer ignores geometry, title and child messages for an id it was never told about. `WindowRegistry` in the package implements the check.
- When a message of a known type fails to decode (short payload, bad value, out-of-range number, unsafe name), the receiver closes the connection: it cannot tell which earlier state the peer thinks is true, and the framing check cannot catch it. An unknown type byte is still skipped. The receiver logs the type and the reason, never the payload.
- A type byte is never reused across versions. The v3 types sit in 0x70–0x85 because 0x60 and 0x61 are already RESTART_REQUEST and RESTART_RESULT in v1. The test suite compares them against the real v1 enum in `StreamProtocol.swift`.
- A window's lifecycle is WINDOW_ADDED, any number of MOVED / RESIZED / TITLE,
  then WINDOW_CLOSED. A CHILD_WINDOW follows the WINDOW_ADDED of the same id.
- The operator draws a window only between those messages. A resize request is
  advisory: the host answers with WINDOW_RESIZED for the size it actually got.
- A menu generation is a counter per app that goes up each time the host sends a
  new MENU_TREE. The operator sends only the newest generation's item ids back.
- Stopping a window stream. v3 has no stop message. The operator stops watching a window by sending HANDOFF_RETURN
  for it; the host stops capture when the last operator on that window has done so. A stream also ends on
  WINDOW_CLOSED and when the connection closes. Streams do not resume after a reconnect: the operator sends
  WINDOW_STREAM_START again for each window it wants. On a new connection the host sends APP_LIST, then a
  WINDOW_ADDED for every open window (ordinary windows before their children), as if all were new.
- Pasteboard and file messages never carry more than one in-flight request id
  per kind that the other side has not answered; a side may refuse by ignoring.
- A receiver accepts PASTEBOARD_DATA only for a fetch it sent: the generation and uti match, `total` equals the offered size, and each chunk's `offset` is the number of bytes already received. Any other chunk closes the item (and the connection if it repeats). An item over 256 MiB is refused at the offer.

### What is not yet decided

Mouse-move rate limits, back-pressure for pasteboard data, and the
notification action buttons are left to the implementation PRs; the types above
leave room (trailing bytes are ignored).
