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

### 0.1.0
- Initial release: virtual display creation, mirror-based collapse,
  AX window snapshot/restore, VNC + Jump Desktop detection, menu bar app
  with auto mode and resolution presets.
- Display-sleep prevention while a remote session is active.
- Optional "mute speakers while remote" toggle.
- Start at Login toggle (when running as .app).
- File log at `~/Library/Logs/Clamshell.log` (menu: Open Log File).
- `package.sh` + tag-triggered release workflow building the .app/.dmg.
