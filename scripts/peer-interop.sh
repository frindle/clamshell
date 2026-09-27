#!/bin/bash
# Mac<->Windows peer-link wire cross-check on one machine: the Swift
# `clamshell peer-interop` and the C# `ClamshellPeerTests peerinterop` pair
# over loopback (each direction in turn: one listens and prints its PIN, the
# other dials with it), swap the golden message set and a ~1 MB file, and
# each side verifies what it received byte for byte.
#   usage: scripts/peer-interop.sh <clamshell-binary> <ClamshellPeerTests.dll>
set -u
SW="$1"; CS="$2"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export CLAMSHELL_PEER_DIR="$WORK/peerdir"
fail=0
run() { # $1 label, $2 listener cmd…, then connector cmd after "--"
  local label="$1"; shift
  local lcmd=() ccmd=()
  while [ "$1" != "--" ]; do lcmd+=("$1"); shift; done; shift
  ccmd=("$@")
  rm -rf "$WORK/l" "$WORK/c"; : > "$WORK/l.log"
  "${lcmd[@]}" > "$WORK/l.log" 2>&1 &
  local lp=$! pin=""
  for _ in $(seq 1 150); do pin=$(sed -n 's/^PIN //p' "$WORK/l.log"); [ -n "$pin" ] && break; sleep 0.1; done
  if [ -z "$pin" ]; then echo "FAIL [$label]: listener printed no PIN"; cat "$WORK/l.log"; kill $lp 2>/dev/null; fail=1; return; fi
  "${ccmd[@]}" "$pin" "$WORK/c" > "$WORK/c.log" 2>&1; local cr=$?
  wait $lp; local lr=$?
  echo "--- [$label] listener (exit $lr)"; grep -E "^(ok|FAIL|PASS|linked|link:)" "$WORK/l.log"
  echo "--- [$label] connector (exit $cr)"; grep -E "^(ok|FAIL|PASS|linked|link:)" "$WORK/c.log"
  if [ $lr -ne 0 ] || [ $cr -ne 0 ]; then fail=1; echo "--- full logs"; cat "$WORK/l.log" "$WORK/c.log"; fi
}
run "Mac listens, Windows code dials" "$SW" peer-interop listen 5997 "$WORK/l" -- dotnet "$CS" peerinterop connect 127.0.0.1 5997
run "Windows code listens, Mac dials" dotnet "$CS" peerinterop listen 5998 "$WORK/l" -- "$SW" peer-interop connect 127.0.0.1 5998
[ $fail -eq 0 ] && echo "PASS: Swift and C# peer links interoperate in both directions" || echo "FAIL: interop"
exit $fail
