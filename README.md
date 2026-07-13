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

Download `Clamshell-<version>.dmg` from [Releases](https://github.com/frindle/clamshell/releases),
drag Clamshell.app to Applications. The app is ad-hoc signed (no Apple
Developer ID), so on first launch **right-click → Open**, or clear
quarantine: `xattr -dr com.apple.quarantine /Applications/Clamshell.app`.

Or build from source (no Xcode project needed):

```
swift build -c release
.build/release/Clamshell            # menu bar app
.build/release/Clamshell test-virtual-display   # 10s smoke test
.build/release/Clamshell test-detect            # print detection state
./package.sh 0.1.0                  # build .app + .dmg into dist/
```

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

Not yet: dual mode is a manual menu toggle only — remote connections
(including `Clamshell collapse` from Sunshine, which still sizes Display A)
don't switch it on or off automatically; there's no reliable Mac-side signal
for "iPad with an external monitor attached". The minimal viewer pages have
no on-screen-keyboard button yet — use a hardware keyboard.

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
