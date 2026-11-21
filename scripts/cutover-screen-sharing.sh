#!/usr/bin/env bash
# Moves this Mac's remote screen access from Apple's Screen Sharing service
# to Clamshell, and back.
#
#   cutover-screen-sharing.sh --check    show what --apply would change; change nothing
#   sudo cutover-screen-sharing.sh --apply
#   sudo cutover-screen-sharing.sh --revert
#
# --apply sends connections to the standard VNC port to Clamshell's own
# server (a packet-filter redirect kept in place by a root daemon). It leaves
# the Screen Sharing switch in System Settings alone: that switch stays the
# control, and Clamshell obeys it. It refuses to run unless this Clamshell
# build has an RFB server that passes its self-test, and `clamshell
# remote-ready` passes.
#
# SSH is never touched. Keep it on for the pre-boot disk unlock.
#
# --revert removes the redirect and turns Apple's service back on. Run it
# from SSH or the console if remote access misbehaves.

set -u

BIN="${CLAMSHELL_BIN:-/Applications/Clamshell.app/Contents/MacOS/Clamshell}"
LAUNCHCTL="${CUTOVER_LAUNCHCTL:-/bin/launchctl}"
APPLE_SERVICE="system/com.apple.screensharing"

usage() {
  echo "Usage: $0 --check | --apply | --revert"
}

say() { printf '%s\n' "$*"; }

need_root() {
  # CUTOVER_SKIP_ROOT_CHECK is for the script's own test, which has no root.
  if [ "${CUTOVER_SKIP_ROOT_CHECK:-}" = "1" ]; then return 0; fi
  if [ "$(id -u)" -ne 0 ]; then
    say "Run with sudo."
    return 1
  fi
}

# Prints each gate and returns non-zero when any fails. Changes nothing.
gates() {
  local ok=0
  if [ ! -x "$BIN" ]; then
    say "FAIL  Clamshell not found at $BIN (set CLAMSHELL_BIN to its path)"
    return 1
  fi
  if "$BIN" rfb-selftest >/dev/null 2>&1; then
    say "ok    Clamshell's RFB server is present and its self-test passes"
  else
    say "FAIL  this Clamshell build has no RFB server, or its self-test fails; update Clamshell"
    ok=1
  fi
  if "$BIN" remote-ready; then
    say "ok    remote-ready self-check passes"
  else
    say "FAIL  remote-ready self-check failed (see above)"
    ok=1
  fi
  return $ok
}

plan() {
  say "Applying would:"
  say "  1. install a root daemon (com.frindle.clamshell.redirect) from Clamshell's root-owned app copy"
  say "  2. have it keep one packet-filter rule in anchor com.apple/clamshell:"
  say "       TCP port 5900 -> Clamshell's server on 127.0.0.1 port 5950"
  say "  3. re-apply that rule within seconds if a macOS update resets the packet filter (logged)"
  say "It would not change: SSH, the Screen Sharing switch, /etc/pf.conf, FileVault."
  say "Reverting runs: $BIN redirect uninstall"
  say "  then: launchctl enable $APPLE_SERVICE && launchctl kickstart -k $APPLE_SERVICE"
}

do_check() {
  plan
  say ""
  say "Checks:"
  if gates; then
    say ""
    say "Ready: --apply would go ahead."
    return 0
  fi
  say ""
  say "Not ready: --apply would refuse until the FAIL lines are fixed."
  return 1
}

do_apply() {
  need_root || return 1
  say "Checking first..."
  if ! gates; then
    say "Refusing to apply: a check failed. Nothing was changed."
    return 1
  fi
  if ! "$BIN" redirect install; then
    say "The redirect did not install. Nothing else was changed."
    return 1
  fi
  say "Done. Test from another device with Screen Sharing.app or a vnc:// link."
  say "To go back: sudo $0 --revert"
}

do_revert() {
  need_root || return 1
  local rc=0
  if [ -x "$BIN" ]; then
    "$BIN" redirect uninstall || rc=1
  else
    say "Clamshell not found at $BIN; skipping the redirect removal."
    rc=1
  fi
  "$LAUNCHCTL" enable "$APPLE_SERVICE" || rc=1
  "$LAUNCHCTL" kickstart -k "$APPLE_SERVICE" || rc=1
  if [ "$rc" -eq 0 ]; then
    say "Reverted. Apple's Screen Sharing is back on port 5900."
  else
    say "Reverted with errors (above). Check: $BIN redirect status"
  fi
  return $rc
}

case "${1:-}" in
  --check) do_check ;;
  --apply) do_apply ;;
  --revert) do_revert ;;
  *) usage; exit 64 ;;
esac
