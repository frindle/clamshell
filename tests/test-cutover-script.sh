#!/usr/bin/env bash
# Tests scripts/cutover-screen-sharing.sh with a stand-in Clamshell binary and
# a stand-in launchctl. Nothing real is touched.
set -u
cd "$(dirname "$0")/.." || exit 1
SCRIPT="scripts/cutover-screen-sharing.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOG="$TMP/calls.log"

cat >"$TMP/clamshell" <<'EOF'
#!/usr/bin/env bash
echo "clamshell $*" >>"$FAKE_LOG"
case "$1" in
  rfb-selftest) [ "${FAKE_RFB:-0}" = "1" ] && exit 0 || exit 64 ;;
  remote-ready) [ "${FAKE_READY:-0}" = "1" ] && exit 0 || exit 1 ;;
  redirect) exit 0 ;;
esac
exit 64
EOF
cat >"$TMP/launchctl" <<'EOF'
#!/usr/bin/env bash
echo "launchctl $*" >>"$FAKE_LOG"
EOF
chmod +x "$TMP/clamshell" "$TMP/launchctl"

export FAKE_LOG="$LOG" CLAMSHELL_BIN="$TMP/clamshell" CUTOVER_LAUNCHCTL="$TMP/launchctl" CUTOVER_SKIP_ROOT_CHECK=1

fails=0
expect() { # expect "<name>" <want-exit> <got-exit>
  if [ "$2" -eq "$3" ]; then echo "ok    $1"; else echo "FAIL  $1 (wanted exit $2, got $3)"; fails=$((fails + 1)); fi
}
logged() { grep -q "$1" "$LOG" 2>/dev/null; }

# No argument: usage.
bash "$SCRIPT" >/dev/null 2>&1; expect "no argument is a usage error" 64 $?

# --check never changes anything, whatever the gates say.
: >"$LOG"; FAKE_RFB=1 FAKE_READY=1 bash "$SCRIPT" --check >/dev/null 2>&1; expect "--check passes when ready" 0 $?
logged "redirect install" && { echo "FAIL  --check installed something"; fails=$((fails + 1)); } || echo "ok    --check installs nothing"
logged "launchctl" && { echo "FAIL  --check called launchctl"; fails=$((fails + 1)); } || echo "ok    --check never calls launchctl"
FAKE_RFB=0 FAKE_READY=1 bash "$SCRIPT" --check >/dev/null 2>&1; expect "--check fails without an RFB server" 1 $?
FAKE_RFB=1 FAKE_READY=0 bash "$SCRIPT" --check >/dev/null 2>&1; expect "--check fails when remote-ready fails" 1 $?

# --apply refuses unless both gates pass.
: >"$LOG"; FAKE_RFB=0 FAKE_READY=1 bash "$SCRIPT" --apply >/dev/null 2>&1; expect "--apply refuses with no RFB server" 1 $?
logged "redirect install" && { echo "FAIL  --apply installed without an RFB server"; fails=$((fails + 1)); } || echo "ok    nothing installed without an RFB server"
: >"$LOG"; FAKE_RFB=1 FAKE_READY=0 bash "$SCRIPT" --apply >/dev/null 2>&1; expect "--apply refuses when remote-ready fails" 1 $?
logged "redirect install" && { echo "FAIL  --apply installed while not ready"; fails=$((fails + 1)); } || echo "ok    nothing installed while not ready"
: >"$LOG"; FAKE_RFB=1 FAKE_READY=1 bash "$SCRIPT" --apply >/dev/null 2>&1; expect "--apply goes ahead when both pass" 0 $?
logged "redirect install" && echo "ok    redirect installed" || { echo "FAIL  redirect not installed"; fails=$((fails + 1)); }

# --revert removes the redirect and turns Apple's service back on.
: >"$LOG"; bash "$SCRIPT" --revert >/dev/null 2>&1; expect "--revert succeeds" 0 $?
logged "redirect uninstall" && echo "ok    redirect removed" || { echo "FAIL  redirect not removed"; fails=$((fails + 1)); }
logged "launchctl enable system/com.apple.screensharing" && echo "ok    Apple service enabled" || { echo "FAIL  Apple service not enabled"; fails=$((fails + 1)); }
logged "launchctl kickstart -k system/com.apple.screensharing" && echo "ok    Apple service kickstarted" || { echo "FAIL  Apple service not kickstarted"; fails=$((fails + 1)); }

# Without root, apply and revert stop before doing anything.
: >"$LOG"; (unset CUTOVER_SKIP_ROOT_CHECK; FAKE_RFB=1 FAKE_READY=1 bash "$SCRIPT" --apply >/dev/null 2>&1); r=$?
if [ "$(id -u)" -ne 0 ]; then expect "--apply needs root" 1 $r; fi

# SSH is never touched: no command in the script mentions it.
if grep -v '^[[:space:]]*#' "$SCRIPT" | grep -v 'say ' | grep -Eqi 'sshd|systemsetup|remotelogin|com\.openssh'; then
  echo "FAIL  the script touches SSH"; fails=$((fails + 1))
else
  echo "ok    the script does not touch SSH"
fi

[ "$fails" -eq 0 ]
