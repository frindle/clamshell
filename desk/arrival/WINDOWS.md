# Windows apps (E11 / phase 7): documentation only, no scripts

Nothing here is run on arrival day. It keeps the E11 and phase 7 path ready. Source: plan section 9.1.

## What is needed from Penn first
The list of Windows apps he wants. E11 cannot start without it.

## Routes, in order of preference (use the first that works per app)
1. Wine (or CrossOver) on the M5 Ultra. No Windows licence, no Microsoft account. Windows appear as ordinary Mac windows, so Clamshell streams them like any Mac app. Watch: stable CrossOver still relies on Rosetta, which Apple is retiring; check which macOS release drops it.
2. Windows 11 on Arm virtual machine on the M5 Ultra (Parallels is the authorised product; UTM works but is not authorised). Needs a Windows 11 Pro licence per machine, 8 to 16 GB reserved. Per-window options: Clamshell Windows server per-window capture (1.5 to 2 weeks to build), RDP RemoteApp (unsupported on Pro), or Parallels Coherence.
3. The x86 Windows machine already on the Unraid server, for anything x86-only, driver-dependent or graphics-heavy. No Mac memory used.

## E11 steps
- (a) Now, no new Mac: one app from the Unraid Windows machine as a single window on the operator (route 3, RDP RemoteApp), half a day.
- (b) After arrival, 1 day: each app under Wine on the M5 Ultra; for failures, a trial Windows 11 on Arm VM.
- Pass: each app has one route where it opens, prints, saves to the shared folders and appears as its own window. Fail: the app stays on the Unraid Windows machine.
- E11b also checks that Parallels Coherence windows are capturable one by one.

## Result record
Per app: route chosen, what failed on the others. Written to the plan's E11 row. The route table feeds the placer's rules file (kind per app) when phase 7 starts.

## Needs Penn
App list; Windows licence decision for route 2; whether to pay for CrossOver or Parallels.
