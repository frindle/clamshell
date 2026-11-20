#!/bin/bash
# E8: does a user-space pooled volume work at Full Security? (plan 6 E8, 3.4 layer 3)
#   (a) macFUSE FSKit backend or FUSE-T, rclone union over two folders, copy 50 GB, sleep and wake.
#   (b) the open-source audio loopback driver (BlackHole) installs without lowering security.
# Pass: mounts with no Recovery step; survives sleep; above 500 MB/s.
#
#   e8-pool-test.sh                       read-only: which pieces are installed, security state
#   e8-pool-test.sh --run --work DIR [--size-gb 50] [--backend fuse-t|macfuse]
#                                         makes DIR/m1 and DIR/m2, mounts an rclone union of them at DIR/pool,
#                                         writes SIZE GB through it, reports MB/s and where the data landed,
#                                         unmounts and deletes everything it made. Needs the pieces installed.
#   e8-pool-test.sh --check | --dry-run | --help
# The work directory must be empty and is the only place anything is created. Cache is off, so the MB/s
# figures are the pool's own (a write cache would time the local disk, not the pool).
# Sleep and wake is NOT scripted (it would put the Mac to sleep): do it by hand while the pool is mounted,
# using --run ... --hold, which leaves the mount up until you press Return.

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$DIR/lib.sh"

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }

WORK=""; SIZE_GB=50; BACKEND=fuse-t; DO_RUN=0; HOLD=0

have_fuse() {
  case "$BACKEND" in
    fuse-t) [ -e /usr/local/lib/libfuse-t.dylib ] || [ -d "/Library/Application Support/fuse-t" ] ;;
    macfuse) [ -d /Library/Filesystems/macfuse.fs ] ;;
  esac
}

inventory() {
  desk_say "pieces (installs are manual steps in ARRIVAL.md; this only looks):"
  if [ -d /Library/Filesystems/macfuse.fs ]; then desk_pass "macFUSE present"; else desk_info "macFUSE not installed"; fi
  if [ -e /usr/local/lib/libfuse-t.dylib ] || [ -d "/Library/Application Support/fuse-t" ]; then desk_pass "FUSE-T present"; else desk_info "FUSE-T not installed"; fi
  if command -v rclone >/dev/null 2>&1; then desk_pass "rclone present: $(rclone version 2>/dev/null | head -1)"; else desk_info "rclone not installed (https://github.com/rclone/rclone/releases, or brew install rclone)"; fi
  if ls /Library/Audio/Plug-Ins/HAL/BlackHole*.driver >/dev/null 2>&1; then desk_pass "BlackHole audio driver present (E8b)"; else desk_info "BlackHole audio driver not installed (E8b)"; fi
  desk_say ""
  desk_say "security state (E8 needs Full Security, no reduced-security step):"
  desk_cmd csrutil status
  desk_cmd systemextensionsctl list
  desk_todo "Startup security level cannot be read without admin: check it by hand in Recovery > Startup Security Utility and write it in the results (RUNBOOK E8)."
}

# Cleanup removes only what this run created, and only after the mount is gone (so it can never delete through
# a live mount). The work path is held in a variable, never pasted into a trap string, so any character is safe.
CREATED_M1=0; CREATED_M2=0; CREATED_POOL=0
cleanup() {
  [ -n "$WORK" ] || return 0
  if [ "$CREATED_POOL" -eq 1 ]; then
    umount "$WORK/pool" 2>/dev/null || diskutil unmount force "$WORK/pool" >/dev/null 2>&1
    sleep 1
    if mount | grep -qF -- "$WORK/pool"; then desk_fail "the pool is still mounted; unmount it by hand, then delete the m1 and m2 folders"; return 0; fi
    rmdir "$WORK/pool" 2>/dev/null
  fi
  [ "$CREATED_M1" -eq 1 ] && rm -rf "${WORK:?}/m1"
  [ "$CREATED_M2" -eq 1 ] && rm -rf "${WORK:?}/m2"
  return 0
}

pool_run() {
  [ -n "$WORK" ] || { echo "give --work DIR" >&2; exit 2; }
  have_fuse || { desk_fail "backend $BACKEND is not installed"; return 1; }
  command -v rclone >/dev/null 2>&1 || { desk_fail "rclone is not installed"; return 1; }
  [ -d "$WORK" ] || { desk_fail "--work must be an existing directory"; return 1; }
  # The whole work directory must be empty: m1 and m2 are deleted at the end, so they must be ours.
  if [ -n "$(ls -A "$WORK" 2>/dev/null)" ]; then desk_fail "the work directory is not empty; use a new empty one (nothing in it is touched)"; return 1; fi
  mkdir "$WORK/m1" && CREATED_M1=1; mkdir "$WORK/m2" && CREATED_M2=1; mkdir "$WORK/pool" && CREATED_POOL=1
  trap cleanup EXIT
  export RCLONE_CONFIG_DESKPOOL_TYPE=union
  export RCLONE_CONFIG_DESKPOOL_UPSTREAMS="$WORK/m1 $WORK/m2"
  export RCLONE_CONFIG_DESKPOOL_CREATE_POLICY=mfs
  rclone mount DESKPOOL: "$WORK/pool" --daemon --vfs-cache-mode off >/dev/null 2>&1 || { desk_fail "rclone mount failed (a Recovery or security step may be required: write down exactly what macOS asked)"; return 1; }
  sleep 3
  if mount | grep -qF -- "$WORK/pool"; then desk_pass "pool mounted with no Recovery step"; else desk_fail "pool did not mount"; return 1; fi
  local t0 t1 mbs SUM_BEFORE=""
  t0=$(desk_now)
  dd if=/dev/zero of="$WORK/pool/desk-e8.bin" bs=1048576 count=$((SIZE_GB * 1024)) 2>/dev/null; sync
  t1=$(desk_now)
  mbs=$(awk -v a="$t0" -v b="$t1" -v g="$SIZE_GB" 'BEGIN { s = b - a; if (s <= 0) print 0; else printf "%d", g * 1024 / s }')
  if [ "$mbs" -gt 500 ]; then desk_pass "write through the pool $mbs MB/s (mark: above 500)"; else desk_fail "write through the pool $mbs MB/s (mark: above 500); plan: pool becomes shares plus a folder of links"; fi
  # Read it back (cache is off, so this is the pool's own read speed) and keep a checksum for the wake check.
  t0=$(desk_now)
  SUM_BEFORE=$(dd if="$WORK/pool/desk-e8.bin" bs=1048576 2>/dev/null | cksum)
  t1=$(desk_now)
  mbs=$(awk -v a="$t0" -v b="$t1" -v g="$SIZE_GB" 'BEGIN { s = b - a; if (s <= 0) print 0; else printf "%d", g * 1024 / s }')
  desk_info "read back through the pool $mbs MB/s (includes checksumming; a lower bound)"
  desk_info "landed on: m1 $(du -sk "$WORK/m1" | awk '{print int($1/1024)}') MB, m2 $(du -sk "$WORK/m2" | awk '{print int($1/1024)}') MB"
  if [ "$HOLD" -eq 1 ]; then
    desk_todo "Mounted. Put the Mac to sleep by hand, wake it, then check that ls on the pool still works. Press Return here to unmount and clean up."
    read -r _
    # A plain listing also succeeds on the empty folder left behind when the mount has gone, so require the
    # mount entry AND the same bytes back.
    if mount | grep -qF -- "$WORK/pool" && [ "$(dd if="$WORK/pool/desk-e8.bin" bs=1048576 2>/dev/null | cksum)" = "$SUM_BEFORE" ]; then
      desk_pass "pool still mounted after sleep and wake and returns the same bytes"
    else desk_fail "pool did not survive sleep and wake (mount gone or data differs)"; fi
  fi
}

while [ $# -gt 0 ]; do
  if desk_common_arg "$@"; then shift "$DESK_SHIFT"; continue; fi
  case "$1" in
    --run)      DO_RUN=1; shift ;;
    --work)     WORK="${2:-}"; shift 2 ;;
    --size-gb)  SIZE_GB="${2:-50}"; shift 2 ;;
    --backend)  BACKEND="${2:-fuse-t}"; shift 2 ;;
    --hold)     HOLD=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

main() {
  case "$DESK_MODE" in
    check)
      desk_is_macos && desk_pass "macOS" || desk_fail "not macOS"
      desk_need rclone "https://github.com/rclone/rclone/releases (v1.76.0 checked 2026-11-20) or brew install rclone"
      have_fuse && desk_pass "backend $BACKEND present" || desk_fail "backend $BACKEND missing (FUSE-T 1.2.9: https://github.com/macos-fuse-t/fuse-t/releases ; macFUSE 5.5.0: https://github.com/macfuse/macfuse/releases)"
      desk_finish ;;
    dry)
      desk_cmd csrutil status; desk_cmd systemextensionsctl list
      desk_say "with --run: would make <work>/m1 <work>/m2 <work>/pool, run: rclone mount DESKPOOL: <work>/pool --daemon (union of m1 and m2, policy mfs)"
      desk_say "with --run: would write $SIZE_GB GB through the pool, report MB/s, then unmount and delete what it made"
      exit 0 ;;
  esac
  if [ "$DO_RUN" -eq 1 ]; then pool_run; else inventory; fi
  desk_finish
}

if [ "${DESK_SOURCE_ONLY:-}" != 1 ]; then main; fi
