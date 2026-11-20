#!/bin/bash
# E4: can apps be started in the host's logged-in session from the operator? (plan 6 E4)
#   (a) ssh then `open -a Firefox` on the second Studio: the window appears in the session.
#   (b) a Claude desktop SSH session for an hour: no crash.   (c) a tool server through ssh for a day: no stalls.
# This script covers (a) and the stall counting for (c). (b) is a manual hour; see RUNBOOK.
#
#   e4-remote-launch.sh --host-check                 ON THE HOST, read-only: SSH reachable locally, a person is logged in
#   e4-remote-launch.sh --target SSHTARGET           read-only from the operator: reachable, which session type ssh lands in
#   e4-remote-launch.sh --run --target SSHTARGET [--app Firefox]
#                                                    opens the app over ssh and reports whether a window appeared
#   e4-remote-launch.sh --soak MINUTES --target SSHTARGET
#                                                    one trivial ssh round trip every 10 s; counts stalls over 2 s
#   e4-remote-launch.sh --check | --dry-run | --help
# SSHTARGET is user@address as you would type it; it is used but never printed. Key login only (BatchMode),
# so it cannot prompt for or send a password.

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$DIR/lib.sh"

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }

TARGET=""; APP="Firefox"; DO_RUN=0; SOAK=0; HOSTCHECK=0
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=yes"

# The remote command is meant to be expanded here, on the client side.
# shellcheck disable=SC2029,SC2086
rssh() { ssh $SSH_OPTS "$TARGET" "$@"; }

host_check() {
  if nc -z 127.0.0.1 22 >/dev/null 2>&1; then desk_pass "Remote Login is on (port 22 answers locally)"; else desk_fail "Remote Login is off: System Settings > General > Sharing > Remote Login (Penn's hands)"; fi
  local console
  console=$(stat -f%Su /dev/console 2>/dev/null)
  case "$console" in
    ""|root|loginwindow) desk_fail "nobody is logged in at the console: apps need a logged-in user session" ;;
    *) desk_pass "a user session is logged in at the console" ;;
  esac
  if [ -n "$(pgrep -x WindowServer)" ]; then desk_pass "WindowServer is running"; else desk_fail "WindowServer not running"; fi
  desk_info "Screen Recording and Accessibility for Clamshell cannot be read without Full Disk Access: confirm by hand in System Settings > Privacy & Security"
}

observe_target() {
  [ -n "$TARGET" ] || { echo "--target SSHTARGET is required" >&2; exit 2; }
  if rssh true 2>/dev/null; then desk_pass "ssh reachable with a key"; else desk_fail "ssh did not connect with a key (BatchMode); set up key login first"; return 1; fi
  local mgr
  mgr=$(rssh 'launchctl managername' 2>/dev/null)
  desk_info "ssh lands in launchd session: ${mgr:-unknown}  (Aqua = the logged-in GUI session; Background means 'open' may not show windows)"
  if [ "$mgr" = Aqua ]; then desk_pass "ssh session is the GUI session"; else desk_info "not Aqua: if (a) fails, plan fallback is a small launch agent inside the session (1 day)"; fi
}

launch() {
  observe_target || return 1
  local before after
  before=$(rssh "osascript -e 'tell application \"System Events\" to count windows of process \"$APP\"'" 2>/dev/null)
  rssh "open -a \"$APP\"" || { desk_fail "open -a $APP failed on the target"; return 1; }
  sleep 4
  after=$(rssh "osascript -e 'tell application \"System Events\" to count windows of process \"$APP\"'" 2>/dev/null)
  desk_info "windows before: ${before:-unknown}, after: ${after:-unknown} (unknown means Accessibility is not granted to the ssh session; look at the screen)"
  case "$after" in
    ''|*[!0-9]*) desk_todo "Look at the host's screen: did a $APP window appear in the logged-in session? (E4 pass (a))" ;;
    0) desk_fail "no $APP window after open (E4 fail (a)); fallback: launch agent inside the session" ;;
    *) desk_pass "$APP shows $after window(s) in the session (E4 pass (a))" ;;
  esac
}

soak() {
  [ -n "$TARGET" ] || { echo "--target SSHTARGET is required" >&2; exit 2; }
  local end stalls=0 fails=0 n=0 t0 t1 d
  end=$(( $(date +%s) + SOAK * 60 ))
  while [ "$(date +%s)" -lt "$end" ]; do
    t0=$(desk_now)
    if rssh true 2>/dev/null; then
      t1=$(desk_now); d=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.2f", b - a }')
      if awk -v d="$d" 'BEGIN { exit !(d > 2) }'; then stalls=$((stalls + 1)); fi
    else fails=$((fails + 1)); fi
    n=$((n + 1)); sleep 10
  done
  desk_say "soak: $n round trips, $stalls stalls over 2 s, $fails failures"
  if [ "$stalls" -eq 0 ] && [ "$fails" -eq 0 ]; then desk_pass "no stalls (E4 pass (c))"; else desk_fail "stalls or failures seen (E4 fail (c)); plan: keep tool servers local"; fi
}

while [ $# -gt 0 ]; do
  if desk_common_arg "$@"; then shift "$DESK_SHIFT"; continue; fi
  case "$1" in
    --target)     TARGET="${2:-}"; shift 2 ;;
    --app)        APP="${2:-Firefox}"; shift 2 ;;
    --run)        DO_RUN=1; shift ;;
    --soak)       SOAK="${2:-0}"; shift 2 ;;
    --host-check) HOSTCHECK=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

main() {
  case "$DESK_MODE" in
    check)
      for t in ssh nc stat pgrep osascript; do desk_need "$t"; done
      desk_finish ;;
    dry)
      desk_say "would run on the host: nc -z 127.0.0.1 22; stat -f%Su /dev/console; pgrep -x WindowServer"
      desk_say "would run from the operator: ssh <target> true; ssh <target> launchctl managername"
      desk_say "with --run: would run: ssh <target> open -a $APP, then count windows with osascript"
      desk_say "with --soak N: would run: ssh <target> true every 10 s for N minutes"
      exit 0 ;;
  esac
  if [ "$HOSTCHECK" -eq 1 ]; then host_check
  elif [ "$SOAK" -gt 0 ]; then soak
  elif [ "$DO_RUN" -eq 1 ]; then launch
  else observe_target; fi
  desk_finish
}

if [ "${DESK_SOURCE_ONLY:-}" != 1 ]; then main; fi
