#!/usr/bin/env bash
# The checks CI runs that need only Node, Python and bash. Run it from the
# root of a checkout: `bash scripts/ci-local.sh`.
#
# GitHub's ci.yml calls this script, and so does the local CI runner, so both
# run the same steps. Needs no network and installs nothing. Works on Node 20
# and newer. Everything that needs the Mac host binary, Swift, Xcode or .NET
# stays in the workflows.
#
# Every step runs even when an earlier one fails. The last line is a count
# only ("N of M steps passed"), so it is safe to publish. Exit code 0 means
# every step passed.

set -u

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

total=0
passed=0
IN_ACTIONS=false
[ "${GITHUB_ACTIONS:-}" = "true" ] && IN_ACTIONS=true

# run_step "<name>" <function>: the function returns non-zero when the step fails.
run_step() {
  local name="$1" fn="$2" rc
  total=$((total + 1))
  if $IN_ACTIONS; then echo "::group::$name"; else echo "=== $name"; fi
  "$fn"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    passed=$((passed + 1))
  else
    if $IN_ACTIONS; then echo "::error::$name failed"; else echo "FAILED: $name"; fi
  fi
  if $IN_ACTIONS; then echo "::endgroup::"; fi
}

step_hello() {
  node tests/test-webclient-hello.js
}

step_input() {
  node tests/test-webclient-input.js
}

step_login_sw() {
  node tests/test-webclient-login.js || return 1
  node tests/test-webclient-sw.js
}

step_auth() {
  node tests/test-webclient-auth.js || return 1
  node tests/test-webclient-auth-flow.js
}

step_syntax() {
  # No build step for the web client, so a typo would only show up in the
  # browser. Parse every module here (.mjs = parse as a module).
  local f found=0
  for f in Sources/Clamshell/Resources/webclient/*.js; do
    [ -e "$f" ] || continue
    found=1
    cp "$f" "$TMP_DIR/check.mjs" || return 1
    node --check "$TMP_DIR/check.mjs" || { echo "syntax error in $f"; return 1; }
  done
  [ "$found" -eq 1 ] || { echo "no web client files found"; return 1; }
}

step_plists() {
  # plutil is a Mac tool; plistlib parses the same XML and binary files.
  python3 - scripts/loginwindow-probe/*.plist scripts/loginwindow-agent/*.plist scripts/launchagent/*.plist <<'PY'
import plistlib, sys
bad = 0
files = [f for f in sys.argv[1:] if not f.endswith("*.plist")]
if not files:
    print("no plist files found")
    sys.exit(1)
for f in files:
    try:
        with open(f, "rb") as fh:
            plistlib.load(fh)
        print(f + ": OK")
    except Exception as e:
        print(f + ": " + str(e))
        bad = 1
sys.exit(bad)
PY
}

step_ci_retry() {
  python3 -I tests/test-ci-infra-retry.py
}

run_step "Web client hello test" step_hello
run_step "Web client input and audio tests" step_input
run_step "Web client auth tests" step_auth
run_step "Web client login form and offline shell tests" step_login_sw
run_step "Web client syntax check" step_syntax
run_step "Lint probe plists" step_plists
run_step "CI infrastructure auto-retry decision" step_ci_retry

echo "$passed of $total steps passed"
[ "$passed" -eq "$total" ]
