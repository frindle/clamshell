# shellcheck shell=bash
# Shared helpers for the arrival-kit scripts. Sourced, never run.
# Works with the bash 3.2 that ships with macOS (no associative arrays, no mapfile).
#
# Conventions every script follows:
#   --help       what it does
#   --check      only verify that prerequisites exist; measure nothing; exit 1 if something is missing
#   --dry-run    print the commands it would run; run none of them
#   (default)    read-only observation. Anything that generates load, writes files or starts a
#                listener needs an explicit --run, and says so in --help.
# Nothing here installs software or changes a setting. Installs are manual steps in ARRIVAL.md.
# All output goes through desk_scrub, so it carries no host names, addresses, serials, users or emails.

DESK_MODE=observe      # observe | dry | check
DESK_OUT=""            # directory for result files; empty means stdout only
DESK_LABEL="this-mac"  # generic label chosen by the person running it
DESK_FAILED=0

desk_is_macos() { [ "$(uname -s)" = "Darwin" ]; }

# Escape a literal string for use in a sed regular expression.
desk_sed_escape() { printf '%s' "$1" | sed -e 's/[][\.*^$/#&|(){}?+]/\\&/g'; }

# Reads stdin, writes it with anything identifying replaced by a generic token.
desk_scrub() {
  local script names n e home serial u cn
  script=$(mktemp "${TMPDIR:-/tmp}/desk-scrub.XXXXXX") || return 1
  # Exact local names first, so a host name is not half-eaten by the address rules.
  # One name per line: a computer name may contain spaces (often the owner's name), so never word-split.
  names="$(hostname 2>/dev/null)
$(hostname -s 2>/dev/null)"
  if desk_is_macos; then
    cn=$(scutil --get ComputerName 2>/dev/null)
    names="$names
$cn
$(printf '%s' "$cn" | tr ' ' '_')
$(printf '%s' "$cn" | tr ' ' '-')
$(printf '%s' "$cn" | sed "s/'/’/g")
$(scutil --get LocalHostName 2>/dev/null)"
    serial=$(ioreg -c IOPlatformExpertDevice -d 2 2>/dev/null | awk -F'"' '/IOPlatformSerialNumber/{print $4}')
    if [ -n "$serial" ]; then e=$(desk_sed_escape "$serial"); printf 's/%s/<serial>/g\n' "$e" >> "$script"; fi
  fi
  home="${HOME:-}"
  if [ -n "$home" ] && [ "$home" != "/" ]; then e=$(desk_sed_escape "$home"); printf 's#%s#~#g\n' "$e" >> "$script"; fi
  u=$(id -un 2>/dev/null)
  # Longest names first so "Owner's Mac Studio" goes before "Owner".
  names=$(printf '%s\n%s\n' "$u" "$names" | awk 'length($0) >= 2 { print length($0) "\t" $0 }' | sort -rn | cut -f2- | awk '!seen[$0]++')
  while IFS= read -r n; do
    [ "${#n}" -ge 2 ] || continue
    e=$(desk_sed_escape "$n")
    if [ "$n" = "$u" ]; then printf 's/%s/<user>/g\n' "$e" >> "$script"; else printf 's/%s/<host>/g\n' "$e" >> "$script"; fi
  done <<EOF
$names
EOF
  sed -E -f "$script" \
    -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g' \
    -e 's/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/<uuid>/g' \
    -e 's/([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}/<mac>/g' \
    -e 's/0x[0-9A-Fa-f]{8,}/<id>/g' \
    -e 's/(^|[^0-9A-Za-z])[0-9A-Fa-f]{16}([^0-9A-Za-z]|$)/\1<id>\2/g' \
    -e 's/([0-9]{1,3}\.){3}[0-9]{1,3}/<ip>/g' \
    -e 's/([0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}/<ip6>/g' \
    -e 's/[0-9A-Fa-f:]*::[0-9A-Fa-f:]*/<ip6>/g' \
    -e 's/[A-Za-z0-9-]+\.(local|lan|home|internal|home\.arpa|localdomain|ts\.net|corp|intranet|private)([^A-Za-z0-9-]|$)/<host>\2/g'
  rm -f "$script"
}

# Is Darkbloom on this Mac? A real check, not a guess at one process name:
#   - any process whose name OR full command line matches the pattern,
#   - any launchd job whose label matches,
#   - an installed app bundle whose name matches.
# The pattern is DESK_DARKBLOOM_PATTERN (extended regex, case-insensitive), default "darkbloom".
# The real process name is NOT confirmed (the app is not on the new Mac yet): after installing it, run
# `ps -axo args= | grep -i <part of the name>` once and set the variable if the name differs.
# Prints the evidence kinds found (process, launchd, app) on stdout; exit 0 when any was found.
desk_darkbloom_pattern() { printf '%s' "${DESK_DARKBLOOM_PATTERN:-darkbloom}"; }
desk_darkbloom_pids() {
  local pat pid
  pat=$(desk_darkbloom_pattern)
  for pid in $(pgrep -fi -- "$pat" 2>/dev/null); do
    [ "$pid" = "$$" ] || [ "$pid" = "$PPID" ] || printf '%s\n' "$pid"
  done
}
desk_darkbloom_running() {
  local pat found=""
  pat=$(desk_darkbloom_pattern)
  [ -n "$(desk_darkbloom_pids)" ] && found="$found process"
  if command -v launchctl >/dev/null 2>&1 && launchctl list 2>/dev/null | grep -qiE -- "$pat"; then found="$found launchd"; fi
  local a
  for a in /Applications/*; do
    if [ -e "$a" ] && printf '%s' "${a##*/}" | grep -qiE -- "$pat"; then found="$found app"; break; fi
  done
  [ -n "$found" ] || return 1
  printf '%s' "${found# }"
}

# Print one line of our own text through the scrubber.
desk_say() { printf '%s\n' "$*" | desk_scrub; }

desk_pass() { desk_say "PASS  $*"; }
desk_fail() { desk_say "FAIL  $*"; DESK_FAILED=1; }
desk_info() { desk_say "info  $*"; }
desk_todo() { desk_say "TODO  $*"; }

# Run a command and show its output scrubbed. In dry mode only print it.
# Always returns the command's own status (0 in dry mode).
desk_cmd() {
  if [ "$DESK_MODE" = dry ]; then desk_say "would run: $*"; return 0; fi
  local out rc
  out=$("$@" 2>&1); rc=$?
  [ -n "$out" ] && printf '%s\n' "$out" | desk_scrub
  return $rc
}

# Command output captured raw for parsing (never printed as is).
desk_capture() { "$@" 2>/dev/null; }

# Check that a tool exists. Prints where to get it when it does not.
desk_need() {
  local tool="$1" hint="${2:-}"
  if command -v "$tool" >/dev/null 2>&1; then desk_pass "tool present: $tool"; return 0; fi
  desk_fail "tool missing: $tool${hint:+ (get it: $hint)}"
  return 1
}

# Result file support. Only when --out was given, never in dry/check mode.
desk_result_path() {
  [ -n "$DESK_OUT" ] && [ "$DESK_MODE" = observe ] || return 1
  mkdir -p "$DESK_OUT" || return 1
  printf '%s/%s' "$DESK_OUT" "$1"
}

# Arguments every script shares. Sets globals and echoes unconsumed args via DESK_REST (space separated is
# not safe for paths, so scripts parse their own extras: this handles only the common ones, one at a time).
# Returns 0 when it consumed the argument(s) and sets DESK_SHIFT to how many.
desk_common_arg() {
  DESK_SHIFT=1
  case "$1" in
    --dry-run) DESK_MODE=dry ;;
    --check)   DESK_MODE=check ;;
    --out)     DESK_OUT="${2:-}"; DESK_SHIFT=2 ;;
    --label)   DESK_LABEL="${2:-this-mac}"; DESK_SHIFT=2 ;;
    *) return 1 ;;
  esac
  return 0
}

desk_finish() {
  if [ "$DESK_FAILED" -ne 0 ]; then desk_say "result: NOT READY (see FAIL lines)"; exit 1; fi
  desk_say "result: ok"
  exit 0
}

# Seconds with a fraction. perl ships with macOS; fall back to whole seconds.
desk_now() {
  if command -v perl >/dev/null 2>&1; then perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; else date +%s; fi
}
