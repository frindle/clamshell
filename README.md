# Clamshell

Make a multi-monitor Mac act like a laptop when you remote into it.

When a remote session connects (Apple Screen Sharing / VNC, or Jump Desktop),
Clamshell snapshots your window layout, creates a virtual display shaped for
your remote device, and mirrors every physical monitor onto it — so the remote
client sees one clean, correctly-sized screen with all your windows on it.
When you disconnect (or sit back down at the desk), it restores the physical
displays and puts every window back where it was.

Think of it as closing the lid on your desk setup from anywhere.

## Status

Early development. Built and smoke-tested; not yet exercised end-to-end
against a real multi-monitor remote setup.

## How it works

- **Virtual display** — created via the private `CGVirtualDisplay`
  CoreGraphics API (the same mechanism BetterDisplay and friends use).
  HiDPI, shaped to your remote device (default: iPad Air 13", 1366×1024 @2x).
- **Collapse** — physical displays are *mirrored* onto the virtual display
  using public `CGConfigureDisplayMirrorOfDisplay` APIs; macOS consolidates
  all windows onto the one logical display.
- **Window restore** — positions are snapshotted via the Accessibility API
  before collapsing and restored after the displays come back.
- **Trigger** — a poller watches for established connections on the Screen
  Sharing port (5900) and for active Jump Desktop Connect sessions. 10-second
  grace period on disconnect so a flaky connection doesn't thrash displays.

## Install

Download `Clamshell-<version>.dmg` from [Releases](https://github.com/frindle/clamshell/releases)
and, in the installer window that opens, drag **Clamshell.app** onto the
**Applications** shortcut. DMGs are built and code-signed by CI on every `v*`
tag, using a stable self-signed identity ("Clamshell Dev") so that TCC grants
(Accessibility) survive updates. It's *not* notarized (no Apple Developer ID),
so on first launch **right-click → Open**, or clear quarantine:
`xattr -dr com.apple.quarantine /Applications/Clamshell.app`.

Or build from source (no Xcode project needed):

```
swift build -c release
.build/release/Clamshell            # menu bar app
.build/release/Clamshell test-virtual-display   # 10s smoke test
.build/release/Clamshell test-detect            # print detection state
./package.sh 0.8.0                  # build signed .app + .dmg into dist/
```

**Stable signing for local builds (recommended).** Raw `swift build` produces an
ad-hoc/unsigned binary whose code signature changes every build, so macOS TCC
treats each rebuild as a new app and drops your Accessibility grant — you get
re-prompted on every launch. Create a stable identity once (Keychain Access →
Certificate Assistant → Create a Certificate → name **"Clamshell Dev"**, type
**Code Signing**), then build with `./dev-build.sh` instead of `swift build`: it
runs the debug build and re-signs `.build/debug/Clamshell` with that identity,
so the grant persists across rebuilds. `package.sh` (and CI) use the same
identity, so a DMG built locally can self-update a CI DMG and vice versa. No
identity present → both fall back to ad-hoc, exactly as before.

Menu bar: collapse/restore manually, toggle auto mode, pick the remote
screen size preset. Grant **Accessibility** permission when prompted —
without it the collapse still works but window positions can't be restored.

**Accessibility after updates:** releases from v0.6.0 onward are signed
with a stable identity, so grants survive updates. If you're coming from an
older (ad-hoc) build: remove Clamshell from the Accessibility list
(− button), relaunch, re-grant — once.

## Browser access

Enable **Web Access** in the menu and open `http://<mac-hostname>:5901`
from any browser on your network — a full remote desktop session (noVNC),
no client app needed. It bridges to the Mac's own Screen Sharing service,
so enable **"VNC viewers may control screen with password"** in
System Settings → General → Sharing → Screen Sharing options (browser
clients speak standard VNC auth, not Apple's). Browser sessions trigger
the collapse just like native clients.

**Remote access:** don't port-forward these ports raw (unencrypted
WebSocket). Two good options:

- **WireGuard/Tailscale VPN** — works as-is, nothing to configure.
- **Cloudflare Tunnel** — route both ports through one hostname; Clamshell
  detects the proxy (`X-Forwarded-Proto`) and switches the client to
  same-origin `wss://`. Example `config.yml` ingress:

  ```yaml
  ingress:
    - hostname: mac.example.com
      path: ^/websockify$
      service: http://localhost:5902
    - hostname: mac.example.com
      service: http://localhost:5901
    - service: http_status:404
  ```

  Put Cloudflare Access in front of the hostname — the VNC password is the
  only other lock on the door.

## Surviving an unattended reboot

If the Mac reboots while you're away — a power outage came back, or a macOS
update restarted it — you want it to power back up and become remotely
reachable **with nobody at the machine**. That's a chain of OS-level settings,
most of them privileged or physical decisions Clamshell can't make for you.
Run the pre-flight check before you travel:

```
.build/release/Clamshell reboot-readiness   # or menu: "Check Reboot Readiness…"
```

It reports go/no-go for the two real scenarios. Here's the honest picture.

### The hard constraints (what's actually true)

- **Clamshell itself cannot run before someone logs in.** "Start at Login" is
  a per-user launchd agent (`SMAppService`) — it fires *after* a GUI login, in
  that user's session. There is no way to run the menu-bar app, the virtual
  display, ScreenCaptureKit capture, or the native stream at the login window:
  those need a logged-in WindowServer session and per-user Screen Recording /
  Accessibility grants. A LaunchDaemon (true boot, session 0) has no
  WindowServer at all, so it can't help here. *This is by macOS design —
  confirmed by the platform architecture, not something to work around.*
- **Apple Screen Sharing (`screensharingd`) is different — it's a system
  daemon that runs at the login window.** When "Screen Sharing" is on in
  System Settings, macOS can show and control the **login window** remotely,
  before any user logs in, with **zero extra Clamshell code**. Connect with a
  native VNC client to port **5900** (the browser path at `:5901` won't work
  pre-login — that's Clamshell's bridge and Clamshell isn't running yet). Log
  in remotely, and *then* Clamshell's login item starts and you get the full
  collapse/stream experience.

So the achievable flow after an unattended reboot is: **Mac powers on → reaches
the login window → you connect to `:5900` and log in remotely → Clamshell
starts.** Three things gate whether that chain completes:

### 1. Does the Mac even power back on? (`pmset autorestart`)

After a **power outage**, a Mac stays *off* until this is set:

```
sudo pmset -a autorestart 1     # "Start up automatically after a power failure"
```

Needs admin, so it's a one-time manual step (Clamshell runs unprivileged and
can't set it for you — the readiness check copies the command for you). Not
needed for update reboots (macOS powers itself back on for those). Desktop Macs
like the Mac mini support it; the readiness check confirms it's on.

### 2. FileVault: the power-outage wall

If **FileVault** disk encryption is on, a cold boot stops at the **pre-boot
unlock screen** — an EFI environment *before* macOS, before the network stack,
before `screensharingd`. Nothing can reach it remotely; the FileVault password
has to be typed at the physical machine. This means:

- **macOS-update reboot → recovers unattended even with FileVault on.** The
  updater stores a one-shot *authenticated-restart* key so the Mac boots
  straight through FileVault to the login window. (`fdesetup supportsauthrestart`
  is true on modern hardware; the readiness check confirms it.)
- **Power outage → does NOT recover unattended while FileVault is on.** A real
  outage gives macOS no chance to stash that key, and a full power loss wipes
  it anyway. The Mac comes back up and sits at the pre-boot unlock screen until
  someone's physically there.

There is no software fix for this — it's the whole point of FileVault. If
unattended **power-outage** recovery matters more to you than at-rest disk
encryption, **turn FileVault off** (System Settings → Privacy & Security →
FileVault). That's a real security tradeoff (anyone who steals the Mac gets the
disk); only you can make it.

### 3. Getting in once it reaches the login window

- **Enable Apple Screen Sharing** (System Settings → General → Sharing → Screen
  Sharing) and set a VNC password. This is what lets you log in remotely at the
  login window. Already required for the browser/VNC path, so it's likely on.
- **Auto-login vs. remote-login:** you have two ways to end up on the desktop:
  - *Remote-login* (recommended, and the only option with FileVault on): sit at
    the login window over Screen Sharing and type your password. Then the
    Clamshell login item starts.
  - *Auto-login* (System Settings → Users & Groups → Automatically log in as):
    the Mac boots straight to the desktop and Clamshell starts with no remote
    step. Smoothest, but **macOS disables auto-login whenever FileVault is on**,
    and it means anyone with physical access lands on your desktop. Only worth
    it if FileVault is already off and physical security isn't a concern.

### Bottom line

| Scenario | FileVault ON | FileVault OFF |
|---|---|---|
| **macOS update reboot** | ✅ recovers to login window (authenticated restart) | ✅ recovers (auto-login optional) |
| **Power outage** | ❌ stuck at pre-boot unlock — needs a person | ✅ if `pmset autorestart 1` is set |

Make sure "Start at Login" is on so Clamshell comes back the moment you're
logged in either way. Everything above (autorestart, FileVault, Screen Sharing,
auto-login) is a setting only you can decide — the readiness check just tells
you where you stand.

## Dual Display Mode (UNTESTED on real hardware)

> **⚠ Untested** — built ahead of the target Mac mini being set up. The
> display positioning, mirroring, and crop geometry have only been verified
> by code review, not against real hardware. Expect to iterate.

For setups with two remote surfaces — e.g. an iPad (whose own screen is one
surface) with one external monitor attached (iPadOS caps at exactly one, but
Stage Manager extends to it as a real second screen). Toggle **Dual Display
Mode** in the menu: collapsing now creates *two* virtual displays side by
side — Display A (the "Remote Screen Size" preset) at the desktop origin and
Display B (**External Monitor Size**, default 1080p) immediately to its
right, as a genuinely empty extended display (like plugging in a fresh
monitor; nothing auto-populates it).

With Web Access on, `http://<mac>:5901/` becomes a picker linking to two
independent browser views, each cropped to one display's region of the
Screen Sharing framebuffer:

- `http://<mac>:5901/display-a` — Display A only
- `http://<mac>:5901/display-b` — Display B only

Open one in a Safari window on the iPad's screen and the other in a Safari
window on the external monitor: two real, independent Mac monitors. The
pages use noVNC's core API with a panned, clipped viewport, so mouse/touch
input maps correctly within each region.

Dual mode can be a manual menu toggle, but native-stream sessions drive it
automatically: an iPad viewer with an external monitor attached reports the
second surface in its stream handshake, and the Mac collapses in dual mode
for that session (single when unplugged) — the "Auto-Detect Dual Display
(native stream)" menu toggle (default on) controls this. The browser/VNC dual
path stays manual (a browser can't report an attached monitor), and Sunshine's
`Clamshell collapse` still sizes Display A only. The minimal browser viewer
pages have no on-screen-keyboard button yet — use a hardware keyboard.

## Native streaming (experimental)

A from-scratch replacement for the browser-VNC path: ScreenCaptureKit
capture → VideoToolbox HEVC/H.264 encode on the Mac → binary
WebSocket (`ws://` on LAN, `wss://` through a Cloudflare Tunnel) → hardware
decode on an iPad. Wire format is documented in [PROTOCOL.md](PROTOCOL.md).

Turn it on from the menu bar with **Native Streaming** (persists across
relaunches/reboots, same as Web Access and Start at Login), or run it from a
terminal for debugging:

```
.build/debug/Clamshell stream            # serve every active display from :5903
.build/debug/Clamshell stream-selftest   # encode → TCP loopback → decode check
```

`stream` needs **Screen Recording** permission. The iPad client is the
`ClamshellViewer/` Xcode project (SwiftUI, `AVSampleBufferDisplayLayer`,
touch → mouse forwarding) — open it in Xcode and run on an iPad on the same
LAN/Tailscale network. Every active display is served independently (one port
per display, main display first at the base port); hardware encode is strongly
preferred, but the host falls back to a **software** encoder rather than
refusing to start — the viewer shows a warning banner when it does.

The same project has a second target, **ClamshellControl** (iPhone): the
phone shows no video of its own — an external monitor plugged into the phone
over USB-C (or AR glasses, which enumerate as ordinary external screens) is
the only video output, showing whichever Mac display you pick, while the
phone's screen is a laptop-style trackpad (pan = pointer, tap = click,
two-finger tap = right click, two-finger pan = scroll) with a software
keyboard toggle. Hardware Bluetooth keyboards/mice work like on the iPad.

### Known limitation: the lock screen (idle auto-lock / screensaver)

This is **separate from the FileVault/no-login-session wall above** — here a real
user *is* logged in, but the screen has locked from inactivity (or a manual
Ctrl+Cmd+Q). The native streaming path very likely **does not survive a locked
screen**, for two independent reasons:

- **Capture stops.** Clamshell captures with ScreenCaptureKit from the ordinary
  logged-in user session (it runs unprivileged). When macOS locks, the secure
  `loginwindow` takes over the display in its own session and the user session's
  content stops compositing — screen-capture consumers see the frame stream
  freeze / go to an empty desktop, and `SCStream` may even end with
  `didStopWithError`. So the iPad would show a frozen or blank image.
- **Injected input can't unlock it.** Clamshell injects clicks/keys with
  `CGEventPost` from that same user session. The lock screen's password field is
  protected by secure event input in a *different* session, so synthetic events
  posted from a user process are ignored there — you can't type the password
  remotely to get back in. (Apple's own Screen Sharing / Remote Desktop *can*
  unlock a Mac only because `screensharingd` is a privileged system daemon wired
  into the console, not a user-session app posting synthetic events — Clamshell's
  native path is the latter.)

Confidence: **high on input, moderate-high on capture.** The input side is a
long-standing, well-documented macOS security boundary (secure event input at
`loginwindow`). The capture side is inferred from consistent third-party reports
that screen-capture frame updates stop at the lock screen plus the known
session/`loginwindow` architecture, rather than from a single definitive Apple
doc line — it has not been verified against a real locked Mac for this project.

Making native capture or input work *through* an active lock would mean defeating
a deliberate macOS security boundary, which Clamshell does not do. Instead, when
the Mac locks Clamshell now **hands you off to the browser VNC fallback
automatically**:

- The host watches the system `com.apple.screenIsLocked` /
  `com.apple.screenIsUnlocked` notifications and pushes the state to every
  connected native client (protocol message `HOST_LOCK_STATE`, see PROTOCOL.md).
- On lock, the iPad viewer and iPhone control app show a banner over the frozen
  video — *"Mac is locked — native video paused"* — with a one-tap button that
  opens the Mac's browser VNC bridge (noVNC on `http://<mac>:5901`) in Safari.
  That bridge fronts Apple's own privileged `screensharingd`, so — unlike the
  native path — it can reach the lock screen and let you type your password to
  unlock (real password auth, the same way Apple Screen Sharing does).
- On unlock, the banner clears itself and the native video resumes on its own
  through the client's existing auto-reconnect — no extra step.

The one-tap link is derived from the address you connected to, so it only
appears for a bare LAN host or `ws://` connection (where the web port can be
substituted); over a `wss://` Cloudflare Tunnel the banner still explains the
situation but you open the Mac's web access URL yourself. Note the browser
fallback requires **Web Access** to be enabled on the Mac (it serves noVNC on
port 5901) and Screen Sharing turned on in System Settings.

The display-sleep power assertion Clamshell holds during a session
(`kIOPMAssertionTypePreventUserIdleDisplaySleep`, see `SessionComfort`) keeps the
*display* awake but, like `caffeinate -d`, does **not** stop the screensaver or
idle lock. So if you'd rather never hit the lock at all, disabling the
screensaver / auto-lock (System Settings → Lock Screen → "Start Screen Saver when
inactive: Never" and "Require password after screen saver begins…: Never")
remains a **settings tradeoff you choose** — Clamshell won't change those for you.

## Remote client notes

- **Plain VNC (Screens, etc.) → Apple Screen Sharing**: works; no audio over
  VNC, and resolution comes from the preset (VNC can't negotiate it).
- **Jump Desktop (Fluid)**: pairs well — Jump provides fluid streaming,
  audio, and dynamic resolution; Clamshell provides the collapse + restore.
  Disable Jump's own virtual-display option so Clamshell owns the screen.

## Caveats

Uses one private API (`CGVirtualDisplay`) — behavior should be re-verified
after macOS updates. Not sandboxable / not App Store eligible in its current
form.

## Changelog

### Unreleased
- **Lock-screen fallback to browser VNC (automatic)**: the host now detects when
  the Mac's screen locks (`com.apple.screenIsLocked` / `...Unlocked`) and pushes
  it to native clients via a new `HOST_LOCK_STATE` protocol message. The iPad and
  iPhone apps show a banner over the paused video with a one-tap link to the
  browser VNC bridge (`http://<mac>:5901`), which fronts Apple's privileged
  `screensharingd` and *can* unlock a locked Mac. The banner and native video
  clear/resume automatically on unlock. See "Known limitation: the lock screen".
- **Mid-session settings (iPad + iPhone)**: a gear button beside the disconnect
  X on the streaming view opens a lightweight sheet — flip Nerd Mode live (also
  tap the quality dot to toggle it) with no reconnect, and switch to another
  saved machine without hunting through the connect form first. The connect
  screen now pre-selects and pre-fills the most-recently-used saved machine on
  launch (one Connect press reuses it; it does not auto-connect).
- **Known-limitation note — the lock screen**: documented that the native
  streaming path very likely does not survive an idle/auto-locked screen
  (capture freezes; `CGEventPost` can't type the unlock password past secure
  event input), a settings tradeoff like the FileVault one. See "Known
  limitation: the lock screen" under Native streaming.
- **Native streaming from the menu bar**: a new "Native Streaming" toggle runs
  the stream servers in-process (same `StreamFleet` the CLI `stream` command
  uses), persisted and auto-restored on launch like Web Access / Start at
  Login — no terminal needed. CLI `stream` / `stream-selftest` still work.
- **Diagnostics… window**: Screen Recording / Accessibility permission status,
  hardware-encoder availability, per-display native-stream client counts, and
  Disconnect All Clients / Restart Streaming actions.
- **QR pairing + saved machines** (⚠ untested on real hardware): "Show Pairing
  QR Code…" renders the Mac's connection info (host + optional Cloudflare
  Access token) as a `clamshell://pair` QR via Core Image; the iPad/iPhone
  connect screens gain a "Scan QR to Pair" button (AVFoundation, no third-party
  library) and a "Saved Machines" list (select / add / delete). Format is
  documented in PROTOCOL.md.
- **Connection-quality indicator + Nerd Mode**: the host reports its live
  adaptive bitrate (new STREAM_STATUS message); the clients show an
  unobtrusive colored dot (green/yellow/orange) beside the software-encoding
  banner, expandable via an opt-in "Nerd Mode" toggle into a codec /
  resolution / HW-SW / Mbps readout.
- **Human-readable connection errors**: dropped/rejected connections now
  surface a specific on-screen reason (unreachable host vs. Cloudflare Access
  rejection vs. wrong URL vs. timeout) while auto-reconnect keeps retrying,
  instead of spinning silently on "connecting".
- **Display B sized to the real external monitor**: the iPad viewer now reports
  its attached monitor's pixel size on the primary stream connection, so the
  Mac sizes Display B to it instead of the fixed preset.
- **Auto-sized virtual display for native streaming** (⚠ untested on real
  hardware): the iPad/iPhone client reports its actual pixel resolution in
  the stream HELLO handshake (and mid-session via a new CLIENT_DISPLAYS
  message), and the Mac auto-collapses to a virtual display of exactly that
  size — no manual "Remote Screen Size" pick needed for native-stream
  sessions. The menu preset remains the fallback/override for the VNC/browser
  path (which can't report resolution) and for Sunshine (which keeps its
  prep-command env-var sizing). The collapse restores 15s after the last
  client disconnects; `Clamshell stream` now re-enumerates displays on
  topology changes so the collapse-created virtual display(s) take over the
  stream ports.
- **Auto-detect dual display** (⚠ untested on real hardware): an iPad viewer
  with an external monitor attached reports the second surface, and the Mac
  automatically collapses in dual display mode (single when it's unplugged) —
  new "Auto-Detect Dual Display (native stream)" menu toggle, default on;
  turning it off restores the purely manual Dual Display Mode behavior. The
  browser/VNC dual path stays manual (a browser can't report this).
- **Multi-select "Listen On"**: the Web Access interface picker is now a real
  multi-select — check any set of interfaces (e.g. Ethernet + Tailscale but
  not Wi-Fi), one listener per selected address; "All Interfaces" clears the
  selection. The old single-choice setting migrates automatically.
- **CI-built signed releases restored**: pushing a `v*` tag again builds and
  code-signs the DMG in GitHub Actions, using the stable "Clamshell Dev"
  identity from repo secrets (imported into a temp keychain — no
  trust-settings step, which blocks headlessly on macOS 15 runners), verifies
  `Authority=Clamshell Dev` before publishing, and attaches the DMG to the
  release. Same identity as local builds, so self-update across CI/local DMGs
  keeps TCC grants.
- **Drag-to-Applications DMG**: the DMG now opens to a laid-out Finder window
  with Clamshell.app next to an Applications shortcut. The app is re-signed
  inside the DMG after layout (Finder metadata otherwise breaks
  `codesign --verify --strict`, which the self-updater runs).
- **Stable local dev signing**: `./dev-build.sh` runs the debug build and
  signs `.build/debug/Clamshell` with "Clamshell Dev" when present, so TCC
  (Accessibility) grants survive rebuilds instead of re-prompting every launch.
- **Self-updater fix**: signing-identity check now reads `codesign -dvv`
  (the `Authority=` line isn't emitted at `-dv`), so self-signed builds match
  correctly instead of always reading as ad-hoc.
- **Adaptive bitrate** (⚠ untested on real networks): the stream host now
  reacts to send-queue congestion by halving the encoder bitrate (floor
  2 Mbps) and stepping back up 25% after 5 s healthy (ceiling 20 Mbps), so a
  constrained link (tunnel, hotel wifi, cellular) degrades quality instead of
  stuttering. Scheme documented in PROTOCOL.md.
- **Software-encode fallback, loudly surfaced**: with no hardware HEVC/H.264
  encoder the host now falls back to software encoding instead of refusing to
  start. The state is logged, carried in HELLO_ACK (new trailing flags byte),
  and both iOS clients show a persistent warning banner while streaming from
  a software-encoding host.
- **Unattended-reboot readiness**: new "Check Reboot Readiness…" menu item
  (and `Clamshell reboot-readiness` CLI, usable over SSH) reports whether the
  Mac will power back on and be remotely reachable after a power outage or
  update reboot — checks `pmset autorestart`, FileVault, Screen Sharing, and
  the login item, with a go/no-go verdict per scenario. New README section
  "Surviving an unattended reboot" documents the FileVault power-outage wall
  and the settings only the user can change. No new automation — these are all
  privileged/physical decisions Clamshell surfaces rather than makes.
- **ClamshellControl** (⚠ untested on real hardware): new iPhone target —
  external monitor is the only video output (user-picked Mac display),
  phone screen is a relative-movement trackpad + software-keyboard toggle.
  Shares the entire protocol client with the iPad viewer.

### 0.8.0
- **Virtual display robustness**: HiDPI mode is now verified and enforced
  after creation (re-asserted every second for 6s in case macOS reverts to
  1x or restores a stale saved mode); creation retries up to 8 times when
  WindowServer still holds a stale display registration (quick relaunch
  after a crash); a termination handler logs system-side display death and
  keeps internal state accurate.
- **Clipboard bridge** (⚠ untested on real hardware): `GET`/`POST
  /clipboard` on the web server sync the Mac clipboard with the browser —
  pulled on page focus, pushed when the page is hidden. Requires a secure
  context (HTTPS tunnel or localhost); over plain LAN HTTP the browser
  clipboard API is unavailable and the script no-ops. Same trust boundary
  as the rest of the web server by default; if the server is exposed
  through a tunnel, gate the endpoint with a token —
  `defaults write com.frindle.clamshell clipboardToken <secret>` (then
  relaunch Clamshell). Requests must then carry `?token=<secret>` or an
  `Authorization: Bearer <secret>` header; the served pages embed the
  token automatically so browser sync keeps working.
- **Sunshine disconnect fix** (⚠ untested on real hardware): Sunshine's
  `serverinfo` BUSY state only means the streaming app is running, not
  that a client is attached, so it kept Clamshell collapsed forever after
  a normal Moonlight disconnect. It's now arm-only: a rising edge still
  triggers collapse, but sustained BUSY no longer holds the session open.
  Prep-command collapses now suppress the poll-driven restore until the
  matching restore command, so event-driven Sunshine setups keep their
  full-stream collapse.

### 0.7.0
- **Dual Display Mode** (⚠ untested — built ahead of the target Mac mini
  being set up): a second virtual display positioned side-by-side with the
  first, plus per-display browser views at `/display-a` and `/display-b`
  (noVNC core with a cropped viewport; `/` becomes a picker while dual mode
  is on). New menu items: "Dual Display Mode (two virtual screens)" toggle
  and "External Monitor Size (Display B)" preset picker. Manual toggle only
  for now — not auto-triggered by remote sessions.

### 0.6.1
- `Clamshell collapse` accepts client pixel dimensions — wire Sunshine's
  env vars into the prep command for automatic per-device resolution:
  `sh -c '/Applications/Clamshell.app/Contents/MacOS/Clamshell collapse "$SUNSHINE_CLIENT_WIDTH" "$SUNSHINE_CLIENT_HEIGHT"'`
  (undo stays `... restore`). Falls back to the menu preset when absent.

### 0.6.0
- **Automatic updates**: releases are signed with a stable identity
  (local `Clamshell Dev` certificate; built/released from a trusted Mac —
  macOS 15 CI runners can't trust self-signed certs), and the app
  self-updates — downloads the latest
  DMG, verifies the signing identity matches (so TCC grants survive),
  swaps the bundle, and relaunches. Auto-installs only when idle (never
  mid-session); otherwise the menu shows "Install Update".


### 0.5.1
- `Clamshell collapse` / `Clamshell restore` CLI commands signal the running
  app — wire them into Sunshine's per-app prep commands (do/undo) for
  instant, event-driven collapse instead of the 2s detection poll:
  `do: /Applications/Clamshell.app/Contents/MacOS/Clamshell collapse`,
  `undo: ... restore`.


### 0.5.0
- Sunshine (Moonlight) session detection via the unauthenticated
  `serverinfo` endpoint — streaming sessions trigger collapse/restore like
  VNC/Jump/browser sessions.
- `package.sh` signs with a local `Clamshell Dev` certificate when present,
  keeping TCC grants (Accessibility) stable across updates; falls back to
  ad-hoc.


### 0.4.1
- Cloudflare Tunnel support: behind an HTTPS proxy the client uses
  same-origin `wss://` (path `/websockify`) instead of the raw :5902 port.
  README documents the ingress config.


### 0.4.0
- Web Access URLs show the Mac's LAN IP instead of its hostname.
- "Listen On" picker when the Mac has multiple LAN IPs — bind the web
  server to a specific interface or all of them.


### 0.3.0
- App icon (laptop).
- Update-available check against GitHub releases (menu item when newer).
- iPad mini screen-size preset.
- Menu re-checks Accessibility permission on every open, with a hint that
  macOS requires quitting/reopening after granting.


### 0.2.0
- Browser-based remote desktop: vendored noVNC served at `http://<mac>:5901`
  with a WebSocket→VNC bridge; browser sessions trigger collapse/restore.
- Menu toggle for Web Access (persisted).

### 0.1.0
- Initial release: virtual display creation, mirror-based collapse,
  AX window snapshot/restore, VNC + Jump Desktop detection, menu bar app
  with auto mode and resolution presets.
- Display-sleep prevention while a remote session is active.
- Optional "mute speakers while remote" toggle.
- Start at Login toggle (when running as .app).
- File log at `~/Library/Logs/Clamshell.log` (menu: Open Log File).
- `package.sh` + tag-triggered release workflow building the .app/.dmg.
