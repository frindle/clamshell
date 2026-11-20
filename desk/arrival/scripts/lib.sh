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
  local script names n e home serial
  script=$(mktemp "${TMPDIR:-/tmp}/desk-scrub.XXXXXX") || return 1
  # Exact local names first, so a host name is not half-eaten by the address rules.
  names="$(hostname 2>/dev/null) $(hostname -s 2>/dev/null)"
  if desk_is_macos; then
    names="$names $(scutil --get ComputerName 2>/dev/null | tr ' ' '_') $(scutil --get LocalHostName 2>/dev/null)"
    serial=$(ioreg -c IOPlatformExpertDevice -d 2 2>/dev/null | awk -F'"' '/IOPlatformSerialNumber/{print $4}')
    if [ -n "$serial" ]; then e=$(desk_sed_escape "$serial"); printf 's/%s/<serial>/g\n' "$e" >> "$script"; fi
  fi
  home="${HOME:-}"
  if [ -n "$home" ] && [ "$home" != "/" ]; then e=$(desk_sed_escape "$home"); printf 's#%s#~#g\n' "$e" >> "$script"; fi
  for n in $(id -un 2>/dev/null) $names; do
    [ "${#n}" -ge 2 ] || continue
    e=$(desk_sed_escape "$n")
    case "$n" in
      "$(id -un 2>/dev/null)") printf 's/%s/<user>/g\n' "$e" >> "$script" ;;
      *) printf 's/%s/<host>/g\n' "$e" >> "$script" ;;
    esac
  done
  sed -E -f "$script" \
    -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g' \
    -e 's/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/<uuid>/g' \
    -e 's/([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}/<mac>/g' \
    -e 's/([0-9]{1,3}\.){3}[0-9]{1,3}/<ip>/g' \
    -e 's/([0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}/<ip6>/g' \
    -e 's/[0-9A-Fa-f:]*::[0-9A-Fa-f:]*/<ip6>/g' \
    -e 's/[A-Za-z0-9-]+\.(local|lan|home|internal|home\.arpa)([^A-Za-z0-9-]|$)/<host>\2/g'
  rm -f "$script"
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
