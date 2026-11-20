#!/bin/bash
# E2, second half: memory census on the new Studio, before and after Darkbloom is installed and loaded.
# The difference between the two snapshots is Darkbloom's real footprint, which the placer needs for its
# reserve (plan 3.2: "Darkbloom's measured footprint plus 8 GB"; placement.toml darkbloom_footprint_mb).
#
# Read-only: sysctl, vm_stat, memory_pressure, ps. Does not touch Darkbloom.
#
#   e2-memory-census.sh --phase before|after [--out DIR] [--label NAME]   take a snapshot
#   e2-memory-census.sh --compare BEFORE.kv AFTER.kv [--label NAME]       print the footprint and the TOML line
#   e2-memory-census.sh --check | --dry-run | --help

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$DIR/lib.sh"

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }

# Reads `vm_stat` output on stdin and the page size as $1; prints key=value lines in MB.
# "available" counts memory the system can hand back without swapping: free + inactive + speculative + purgeable.
parse_vm_stat() {
  awk -v ps="$1" '
    function num(s) { gsub(/[^0-9]/, "", s); return s + 0 }
    /^Pages free:/                 { free = num($0) }
    /^Pages active:/               { active = num($0) }
    /^Pages inactive:/             { inactive = num($0) }
    /^Pages speculative:/          { spec = num($0) }
    /^Pages purgeable:/            { purg = num($0) }
    /^Pages wired down:/           { wired = num($0) }
    /^Pages occupied by compressor:/ { comp = num($0) }
    END {
      mb = ps / 1048576
      printf "free_mb=%d\nactive_mb=%d\ninactive_mb=%d\nspeculative_mb=%d\npurgeable_mb=%d\nwired_mb=%d\ncompressor_mb=%d\n",
        free * mb, active * mb, inactive * mb, spec * mb, purg * mb, wired * mb, comp * mb
      printf "available_mb=%d\n", (free + inactive + spec + purg) * mb
    }'
}

kv_get() { sed -n "s/^$2=//p" "$1" | head -1; }

# Prints the comparison for two snapshot files.
compare() {
  local b="$1" a="$2" tb ta ub ua sb sa fp
  [ -r "$b" ] && [ -r "$a" ] || { desk_fail "cannot read both snapshot files"; return 1; }
  tb=$(kv_get "$b" total_mb); ta=$(kv_get "$a" total_mb)
  [ -n "$tb" ] && [ "$tb" = "$ta" ] || { desk_fail "snapshots are from machines with different memory sizes ($tb vs $ta)"; return 1; }
  ub=$((tb - $(kv_get "$b" available_mb))); ua=$((ta - $(kv_get "$a" available_mb)))
  sb=$(kv_get "$b" swap_used_mb); sa=$(kv_get "$a" swap_used_mb)
  fp=$((ua - ub))
  desk_say "used before: ${ub} MB   used after: ${ua} MB   swap before: ${sb:-?} MB   swap after: ${sa:-?} MB"
  desk_say "darkbloom_footprint_mb = $fp"
  if [ "$fp" -lt 500 ]; then
    desk_todo "difference is under 500 MB: Darkbloom may not have loaded its model yet, or other apps changed. Repeat the 'after' snapshot once it is serving."
  fi
  if [ "$(kv_get "$a" darkbloom_running)" != "yes" ]; then
    desk_todo "the 'after' snapshot did not see a Darkbloom process; the number above is not its footprint."
  fi
  desk_say ""
  desk_say "Paste into ~/.config/desk/placement.toml (replace the label with the Mac's name in the rules file):"
  desk_say "[mac.\"$DESK_LABEL\"]"
  desk_say "darkbloom_footprint_mb = $fp"
  desk_say ""
  desk_say "Plan check (E2 pass): the second Studio has more than 20 GB of headroom beside Darkbloom."
  local head=$((ta - ua - 8192))
  desk_say "headroom after reserve, with nothing else running: $((head / 1024)) GB (total - used_after - 8 GB buffer)"
  if [ "$head" -gt 20480 ]; then desk_pass "more than 20 GB of headroom"; else desk_fail "20 GB of headroom not met"; fi
}

snapshot() {
  local phase="$1" ps total pr level swap_line swap_used top
  ps=$(desk_capture sysctl -n hw.pagesize); total=$(desk_capture sysctl -n hw.memsize)
  [ -n "$ps" ] && [ -n "$total" ] || { desk_fail "sysctl hw.pagesize / hw.memsize unavailable (is this macOS?)"; return 1; }
  local file=""
  file=$(desk_result_path "census-$phase.kv") || file=""
  local body
  body="phase=$phase
label=$DESK_LABEL
total_mb=$((total / 1048576))
$(desk_capture vm_stat | parse_vm_stat "$ps")"
  swap_line=$(desk_capture sysctl -n vm.swapusage)
  swap_used=$(printf '%s' "$swap_line" | sed -n 's/.*used = \([0-9.]*\)M.*/\1/p')
  level=$(desk_capture sysctl -n kern.memorystatus_vm_pressure_level)
  case "$level" in 1) pr=green ;; 2) pr=yellow ;; 4) pr=red ;; *) pr=unknown ;; esac
  body="$body
swap_used_mb=${swap_used%.*}
pressure=$pr
darkbloom_running=$(if pgrep -il darkbloom >/dev/null 2>&1; then echo yes; else echo no; fi)"
  printf '%s\n' "$body" | desk_scrub
  desk_info "$(desk_capture memory_pressure | grep -i 'free percentage')"
  if [ -n "$file" ]; then printf '%s\n' "$body" > "$file"; desk_info "snapshot written to $file"; fi
  desk_say ""
  desk_say "largest processes by resident memory (MB, name):"
  top=$(desk_capture ps -axo rss=,comm= | awk '{ rss=$1; $1=""; n=split($0, p, "/"); name=p[n]; sub(/^ +/, "", name); r[name]+=rss } END { for (k in r) printf "%d %s\n", r[k]/1024, k }' | sort -rn | head -15)
  printf '%s\n' "$top" | desk_scrub
  desk_say ""
  if [ "$phase" = before ]; then
    desk_todo "Before: close everything you do not need and make sure Darkbloom is NOT installed or running. Then run again with --phase after once Darkbloom has loaded its model."
  fi
}

MODE_PHASE=""; CMP_B=""; CMP_A=""
while [ $# -gt 0 ]; do
  if desk_common_arg "$@"; then shift "$DESK_SHIFT"; continue; fi
  case "$1" in
    --phase)   MODE_PHASE="${2:-}"; shift 2 ;;
    --compare) CMP_B="${2:-}"; CMP_A="${3:-}"; shift 3 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

main() {
  case "$DESK_MODE" in
    check)
      desk_is_macos && desk_pass "macOS" || desk_fail "not macOS"
      for t in sysctl vm_stat ps awk; do desk_need "$t"; done
      desk_need memory_pressure
      desk_finish ;;
    dry)
      desk_cmd sysctl -n hw.memsize; desk_cmd vm_stat; desk_cmd sysctl -n vm.swapusage
      desk_cmd sysctl -n kern.memorystatus_vm_pressure_level; desk_cmd memory_pressure
      desk_cmd ps -axo rss=,comm=
      desk_cmd pgrep -il darkbloom
      exit 0 ;;
  esac
  if [ -n "$CMP_B" ]; then compare "$CMP_B" "$CMP_A"; desk_finish; fi
  case "$MODE_PHASE" in
    before|after) snapshot "$MODE_PHASE"; desk_finish ;;
    *) echo "give --phase before|after, or --compare BEFORE AFTER (try --help)" >&2; exit 2 ;;
  esac
}

if [ "${DESK_SOURCE_ONLY:-}" != 1 ]; then main; fi
