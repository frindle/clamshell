#!/bin/bash
# E10: how long does migration by restart take? (plan 6 E10, 9.3)
# Plan pass mark: a browser profile copies in under 30 seconds over Thunderbolt.
# Only measures the copy. It never opens the browser, never edits the source, and refuses to copy while the
# browser is running (a live profile copies inconsistently).
#
#   e10-profile-move.sh --profile DIR                   read-only: size and file count, browser running or not
#   e10-profile-move.sh --run --profile DIR --dest DIR  copies the profile into DEST/desk-e10-copy, times it,
#                                                       then deletes the copy (add --keep to keep it)
#   e10-profile-move.sh --check | --dry-run | --help
# DEST is a folder on the other Mac's share (or any folder, to see the disk-only time). The profile path is
# shown as <profile> in the output. Firefox profiles live under ~/Library/Application Support/Firefox/Profiles.

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$DIR/lib.sh"

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; }

PROFILE=""; DEST=""; DO_RUN=0; KEEP=0; BROWSER="${DESK_BROWSER_PROCESS:-firefox}"

# True when a process with this exact name is running.
browser_running() { pgrep -ix "$BROWSER" >/dev/null 2>&1; }

judge() {
  if awk -v s="$1" 'BEGIN { exit !(s < 30) }'; then desk_pass "profile copy took $1 s (mark: under 30 s)"
  else desk_fail "profile copy took $1 s (mark: under 30 s); plan: keep profiles pinned to one host, move tabs not profiles"; fi
}

observe() {
  [ -d "$PROFILE" ] || { echo "--profile must be an existing directory" >&2; exit 2; }
  local kb files
  kb=$(du -sk "$PROFILE" 2>/dev/null | awk '{print $1}')
  files=$(find "$PROFILE" -type f 2>/dev/null | wc -l | tr -d ' ')
  desk_say "<profile> size: $((kb / 1024)) MB in $files files"
  if browser_running; then desk_fail "$BROWSER is running: quit it fully before the timed copy"; else desk_pass "$BROWSER is not running"; fi
}

timed_copy() {
  [ -d "$PROFILE" ] && [ -d "$DEST" ] || { echo "--profile and --dest must be existing directories" >&2; exit 2; }
  if browser_running; then desk_fail "$BROWSER is running: quit it fully first (File > Quit), then rerun"; return 1; fi
  local target="$DEST/desk-e10-copy" t0 t1 secs
  [ ! -e "$target" ] || { desk_fail "a previous test copy exists in the destination; remove it first"; return 1; }
  t0=$(desk_now)
  rsync -a "$PROFILE/" "$target/" || { desk_fail "rsync failed"; return 1; }
  sync
  t1=$(desk_now)
  secs=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }')
  judge "$secs"
  if [ "$KEEP" -eq 0 ]; then rm -rf "${target:?}"; desk_info "test copy removed"; else desk_info "test copy kept in the destination"; fi
  desk_todo "Now open the browser on the other Mac with the copied profile and count what came back (RUNBOOK E10)."
}

while [ $# -gt 0 ]; do
  if desk_common_arg "$@"; then shift "$DESK_SHIFT"; continue; fi
  case "$1" in
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --dest)    DEST="${2:-}"; shift 2 ;;
    --run)     DO_RUN=1; shift ;;
    --keep)    KEEP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

main() {
  case "$DESK_MODE" in
    check)
      for t in rsync du find pgrep; do desk_need "$t"; done
      desk_finish ;;
    dry)
      desk_say "would run: du -sk <profile>; find <profile> -type f"
      desk_say "with --run: would run: rsync -a <profile>/ <dest>/desk-e10-copy/ and time it, then remove the copy"
      exit 0 ;;
  esac
  [ -n "$PROFILE" ] || { echo "give --profile DIR (try --help)" >&2; exit 2; }
  if [ "$DO_RUN" -eq 1 ]; then timed_copy; else observe; fi
  desk_finish
}

if [ "${DESK_SOURCE_ONLY:-}" != 1 ]; then main; fi
