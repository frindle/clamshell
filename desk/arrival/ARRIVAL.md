# Arrival day: M5 Ultra Studio

Source: plan "Macs as one unit", section 6 ("Arrival day, before Darkbloom is installed"), section 9.4, experiments E2, E5, E8, E10.
Goal: do every restart and install now, while it costs Darkbloom nothing. **Do not install Darkbloom until step 7 says so.** About half a day.

Legend: **Penn's hands** = only Penn can do it (Recovery, passwords, permission dialogs). **Needs Penn's go** = Claude may run it once Penn says go for that step. **Claude can run (read-only)** = observation only, changes nothing.

Scripts live in `desk/arrival/scripts/`. All take `--help`, `--dry-run` (prints the commands, runs nothing) and `--check` (prerequisites only). Default mode reads only. Anything that installs, mounts, writes big files or starts a server needs an explicit `--run`. Output uses generic labels (no host names, addresses, serials, user names, emails). Results go in a folder Penn keeps outside the repo (pass `--out DIR`).

| # | Step | Who | Time | Rollback |
|---|---|---|---|---|
| 1 | Preflight: list what is missing | Claude can run (read-only) | 5 min | none needed |
| 2 | Enable RDMA in Recovery | Penn's hands | 15 min | `rdma_ctl disable` in Recovery Terminal, reboot |
| 3 | Create the user, log in at the console, Remote Login on | Penn's hands | 15 min | delete the user in System Settings |
| 4 | Screen Recording and Accessibility for Clamshell | Penn's hands | 10 min | remove the entries in Privacy & Security |
| 5 | Install test tools, one at a time | Needs Penn's go | 30 min | uninstall each (below) |
| 6 | E2 first half: memory with nothing running | Claude can run (read-only) | 10 min | none needed |
| 7 | Install and load Darkbloom, E2 second half | Penn's hands, then read-only | 30 min | none (this is the point of no return for restarts) |
| 8 | E8: pooled volume at Full Security | Needs Penn's go (`--run`) | 2 to 4 h | `--hold` mount is unmounted by the script's trap; uninstall the FUSE package |

Order matters: steps 1 to 6 before 7. E8 (step 8) can run before step 7 too, and should if it needs a restart for a system extension.

## 1. Preflight (Claude can run, read-only, 5 min)
`scripts/preflight-new-studio.sh --out DIR` prints `ok`, `MISSING` and `TODO` lines: macOS 26.2 or later, Apple silicon, free disk, Thunderbolt 5 ports, RDMA enabled, FileVault, Remote Login, console user, each tool below, and whether Darkbloom is already running. Re-run after each step. Exit status 1 means something required is missing.

## 2. RDMA (Penn's hands, 15 min)
Needs macOS 26.2 or later and Thunderbolt 5 (Apple TN3205).
1. Shut down. Hold the power button until startup options appear, choose Options, then Utilities > Terminal.
2. `rdma_ctl enable`
3. Restart. In Terminal: `ibv_devices` should list a device.
Rollback: same Recovery Terminal, `rdma_ctl disable`, restart.

## 3. User session (Penn's hands, 15 min)
Create the user, log in at the screen (not just over SSH: E3 and E4 need a logged-in console session). System Settings > General > Sharing > Remote Login on. Decide FileVault now (the preflight reports it).

## 4. Clamshell permissions (Penn's hands, 10 min)
Install Clamshell from the repo's release dmg or `./dev-build.sh` (README). Open it; grant Screen Recording and Accessibility in System Settings > Privacy & Security. These cannot be read by a script without Full Disk Access, so the preflight only reminds. Check by hand: Clamshell is toggled on in both lists.

## 5. Test tools (needs Penn's go for each; versions checked 2026-11-20)
Download only from these pages; compare the checksum file where one is published.

| Tool | Version | Source | Used by | Uninstall |
|---|---|---|---|---|
| FUSE-T | 1.2.9 | https://github.com/macos-fuse-t/fuse-t/releases (`fuse-t-macos-installer-1.2.9.pkg`) | E8 | uninstaller script in the FUSE-T release page |
| macFUSE (alternative) | 5.5.0 | https://github.com/macfuse/macfuse/releases (`macfuse-5.5.0.dmg`, `.sha256`) | E8 | the Uninstall item inside the dmg; needs Recovery approval of the system extension, which E8 asks about |
| rclone | v1.76.0 | https://github.com/rclone/rclone/releases | E8 | delete the binary |
| BlackHole (2ch) | v0.7.1 | https://github.com/ExistentialAudio/BlackHole/releases | E8b | delete the `.driver` from `/Library/Audio/Plug-Ins/HAL`, restart coreaudiod |
| iperf3 | 3.22.1 | https://github.com/esnet/iperf/releases or `brew install iperf3` | E5 | delete / `brew uninstall` |
| Syncthing | v2.1.7 | https://github.com/syncthing/syncthing/releases | phase 1, not today | delete the app |
| Trial viewer | current | Beam https://beam.win (free tier 20 min a day) or Mirage https://github.com/EthanLipnik/MirageKit | E1 | delete the app |
| Firefox | current | https://www.mozilla.org/firefox/new/ | E1, E10 | delete the app |

Pick FUSE-T first (no system extension). Try macFUSE only if FUSE-T fails E8.

## 6. E2 first half (Claude can run, read-only, 10 min)
Quit everything except the login session. Then:
`scripts/e2-memory-census.sh --phase before --out DIR --label new-studio`
Writes `census-before.kv`. Nothing else is touched. (`--dry-run` shows the commands.)

## 7. Darkbloom, then E2 second half (Penn's hands, then read-only)
Penn installs Darkbloom and loads its model. Wait until the model is resident (5 minutes of settled memory), then:
`scripts/e2-memory-census.sh --phase after --out DIR --label new-studio`
`scripts/e2-memory-census.sh --compare DIR/census-before.kv DIR/census-after.kv`
The compare step prints `darkbloom_footprint_mb`, a TOML snippet for the placer (reserve = footprint + 8 GB, plan section 6 / E2) and the headroom verdict. Pass: more than 20 GB of headroom beside Darkbloom. Write the snippet into the placer's `placement.toml` and the number into the plan's E2 row.

## 8. E8 pooled volume (needs Penn's go, 2 to 4 h)
Inventory first: `scripts/e8-pool-test.sh` (reads only: FUSE backends, rclone, BlackHole, SIP state, system extensions). Then, with a NEW EMPTY work folder on a volume with 50 GB free (the script refuses a non-empty one, and deletes only the m1/m2/pool folders it makes):
`scripts/e8-pool-test.sh --run --work DIR --backend fuse-t --size-gb 50 --hold`
It mounts an rclone union over two folders, writes and reads the file, prints MB/s, and holds the mount so Penn can sleep and wake the Mac, then re-run to check the file still reads. Pass (plan): mounts with no Recovery step, survives sleep, above 500 MB/s. (b) Install BlackHole and note what the system asks; pass is that it asks nothing that lowers security.

## Stop conditions
- Preflight says Darkbloom is running before step 6: skip the "before" half, tell Penn (the first-week runbook has the fallback: compare to the operator Studio's number).
- Any dialog asking to lower security or approve a kernel-level extension: stop, note it, ask Penn. That is a result for E8, not a problem to click through.
