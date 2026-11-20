#!/bin/bash
# Preflight for the new Studio (M5 Ultra): lists what is present and what is missing before arrival-day steps.
# Read-only. Run it on the new Mac BEFORE Darkbloom is installed there. It changes nothing and installs nothing;
# for each missing piece it prints the exact source to download (versions checked on 2026-11-20).
#
#   preflight-new-studio.sh [--out DIR] [--label NAME]     report; exit 1 if a required piece is missing
#   preflight-new-studio.sh --check                        only verify the commands this script itself uses
#   preflight-new-studio.sh --dry-run                      print the commands it would run
#   preflight-new-studio.sh --help

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$DIR/lib.sh"

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; }

# macOS version compare: true when $1 >= $2 (dotted numbers).
version_ge() { awk -v a="$1" -v b="$2" 'BEGIN { na = split(a, x, "."); nb = split(b, y, "."); n = (na > nb) ? na : nb; for (i = 1; i <= n; i++) { if ((x[i]+0) > (y[i]+0)) exit 0; if ((x[i]+0) < (y[i]+0)) exit 1 } exit 0 }'; }

missing() { desk_say "MISSING  $1"; DESK_FAILED=1; }
ok() { desk_say "ok       $1"; }

report() {
  local ver chip mem disk
  ver=$(desk_capture sw_vers -productVersion); chip=$(desk_capture sysctl -n machdep.cpu.brand_string)
  mem=$(( $(desk_capture sysctl -n hw.memsize) / 1073741824 ))
  desk_say "== machine (no serial, name or address is recorded) =="
  desk_say "macOS $ver, $chip, ${mem} GB memory"
  if version_ge "${ver:-0}" 26.2; then ok "macOS 26.2 or later (RDMA over Thunderbolt needs it)"; else missing "macOS 26.2 or later for RDMA (this is $ver)"; fi
  case "$chip" in *Apple*) ok "Apple silicon" ;; *) missing "Apple silicon" ;; esac
  disk=$(df -g / | awk 'NR==2 {print $4}')
  if [ "${disk:-0}" -ge 200 ]; then ok "free disk on the system volume: ${disk} GB"; else missing "free disk 200 GB or more for test files (have ${disk:-?} GB)"; fi

  desk_say ""; desk_say "== Thunderbolt =="
  if system_profiler SPThunderboltDataType 2>/dev/null | grep -qi '80 Gb/s'; then ok "Thunderbolt 5 ports present (80 Gb/s)"; else missing "Thunderbolt 5 ports (no 80 Gb/s port reported)"; fi
  if command -v ibv_devices >/dev/null 2>&1 && ibv_devices 2>/dev/null | grep -qi 'rdma\|thunderbolt\|rdma_en'; then ok "RDMA devices listed (enabled)"
  else desk_todo "RDMA not enabled yet: Recovery > Terminal > 'rdma_ctl enable', reboot, check with 'ibv_devices' (Apple TN3205). Penn's hands."; fi

  desk_say ""; desk_say "== security and session =="
  case "$(fdesetup status 2>/dev/null)" in *"is On"*) ok "FileVault on" ;; *) desk_todo "FileVault not on (plan assumes disk encryption on; decide before Darkbloom)" ;; esac
  if nc -z 127.0.0.1 22 >/dev/null 2>&1; then ok "Remote Login on"; else missing "Remote Login on (needed for E4 and the fab agent)"; fi
  case "$(stat -f%Su /dev/console 2>/dev/null)" in ""|root|loginwindow) missing "a logged-in user session at the console (create the user, log in)" ;; *) ok "a user is logged in at the console" ;; esac
  desk_todo "By hand: Screen Recording and Accessibility for Clamshell (System Settings > Privacy & Security). Cannot be read without Full Disk Access."

  desk_say ""; desk_say "== test tools (installs are Penn's go, one at a time) =="
  if command -v iperf3 >/dev/null 2>&1; then ok "iperf3 $(iperf3 --version 2>/dev/null | head -1 | awk '{print $2}')"; else missing "iperf3 3.x: brew install iperf3, or https://github.com/esnet/iperf/releases (3.22.1 checked)"; fi
  if command -v rclone >/dev/null 2>&1; then ok "rclone present"; else missing "rclone: https://github.com/rclone/rclone/releases (v1.76.0 checked) or brew install rclone"; fi
  if [ -d /Library/Filesystems/macfuse.fs ] || [ -e /usr/local/lib/libfuse-t.dylib ] || [ -d "/Library/Application Support/fuse-t" ]; then ok "a FUSE backend is installed (macFUSE or FUSE-T)"
  else missing "FUSE backend, one of: FUSE-T 1.2.9 https://github.com/macos-fuse-t/fuse-t/releases ; macFUSE 5.5.0 https://github.com/macfuse/macfuse/releases"; fi
  if ls /Library/Audio/Plug-Ins/HAL/BlackHole*.driver >/dev/null 2>&1; then ok "BlackHole audio driver"; else missing "BlackHole 0.7.1 (2ch): https://github.com/ExistentialAudio/BlackHole/releases (E8b)"; fi
  if [ -d "/Applications/Firefox.app" ]; then ok "Firefox"; else missing "Firefox: https://www.mozilla.org/firefox/new/ (E1, E10, E12)"; fi
  if [ -d "/Applications/Beam.app" ] || [ -d "/Applications/Mirage.app" ]; then ok "a trial viewer (Beam or Mirage)"; else missing "trial viewer for E1: Beam (https://beam.win, free tier 20 min a day) or Mirage (https://github.com/EthanLipnik/MirageKit)"; fi
  if [ -x /usr/local/bin/clamshell ] || command -v clamshell >/dev/null 2>&1; then ok "clamshell on PATH"; else missing "clamshell (the repo's own build; ARRIVAL.md step 'Clamshell')"; fi
  if command -v syncthing >/dev/null 2>&1 || [ -d /Applications/Syncthing.app ]; then ok "Syncthing"; else desk_todo "Syncthing 2.1.7 is needed for phase 1, not for arrival day: https://github.com/syncthing/syncthing/releases"; fi
  if xcode-select -p >/dev/null 2>&1; then ok "Xcode command line tools"; else desk_todo "Xcode command line tools absent (needed for codesign and swift only if building here)"; fi

  desk_say ""; desk_say "== Darkbloom must be absent for the 'before' census =="
  if pgrep -il darkbloom >/dev/null 2>&1; then missing "Darkbloom is already running: the 'before' memory census is no longer possible on this Mac"; else ok "Darkbloom not running"; fi
}

while [ $# -gt 0 ]; do
  if desk_common_arg "$@"; then shift "$DESK_SHIFT"; continue; fi
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

main() {
  case "$DESK_MODE" in
    check)
      desk_is_macos && desk_pass "macOS" || desk_fail "not macOS"
      for t in sw_vers sysctl system_profiler df fdesetup nc stat pgrep awk; do desk_need "$t"; done
      desk_finish ;;
    dry)
      for c in "sw_vers -productVersion" "sysctl -n machdep.cpu.brand_string" "sysctl -n hw.memsize" "df -g /" \
               "system_profiler SPThunderboltDataType" "ibv_devices" "fdesetup status" "nc -z 127.0.0.1 22" \
               "stat -f%Su /dev/console" "pgrep -il darkbloom" "command -v iperf3 rclone syncthing"; do
        desk_say "would run: $c"
      done
      exit 0 ;;
  esac
  local f
  if f=$(desk_result_path "preflight.txt"); then report > "$f"; cat "$f"; else report; fi
  desk_finish
}

if [ "${DESK_SOURCE_ONLY:-}" != 1 ]; then main; fi
