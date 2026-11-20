#!/bin/bash
# E5: Thunderbolt link speed between the Studios (plan 6 E5 and 9.5).
# Plan pass marks: sockets above 20 Gb/s with under one core used; large-file copy above 1.5 GB/s;
# round trip measured on the cable and on Ethernet.
#
#   e5-thunderbolt-speed.sh                      read-only: Thunderbolt ports, network order, tools present
#   e5-thunderbolt-speed.sh --run server         starts ONE iperf3 listener (exits after one test). Opens a port.
#   e5-thunderbolt-speed.sh --run client --peer ADDRESS [--streams 4] [--seconds 20]
#                                                iperf3 both directions, CPU use, then 100 pings
#   e5-thunderbolt-speed.sh --run smb --dir MOUNTED_DIR [--size-gb 20] [--small-files 20000]
#                                                writes then reads a test file on a share mounted from the other
#                                                Mac, reports GB/s, deletes what it made. Writes SIZE GB to disk.
#   e5-thunderbolt-speed.sh --check | --dry-run | --help
# The address is read from the command line only and never printed.
# Load modes (--run ...) REFUSE to start while Darkbloom is present (process, launchd job or app; see lib.sh).
# Penn's go is the only reason to pass --allow-darkbloom: the tests use CPU, disk and network. The listener
# needs --bind ADDRESS (the Thunderbolt Bridge address on this Mac) and never listens on every interface.

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$DIR/lib.sh"

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

ALLOW_DB=0; BIND=""; RUN=""; PEER=""; STREAMS=4; SECONDS_T=20; SMBDIR=""; SIZE_GB=20; SMALL=20000

# GB/s from bytes and seconds.
rate_gbs() { awk -v b="$1" -v s="$2" 'BEGIN { if (s <= 0) print "0.00"; else printf "%.2f", b / s / 1000000000 }'; }

# Pulls "sender/receiver Gbits/sec" from iperf3 text output on stdin: the last summary line for the given role.
iperf_gbits() { awk -v role="$1" '$0 ~ /SUM|receiver|sender/ && $0 ~ role && /bits\/sec/ { for (i = 1; i <= NF; i++) if ($i ~ /bits\/sec/) { v = $(i-1); u = $i } } END { if (v == "") exit 1; if (u ~ /^M/) v = v / 1000; if (u ~ /^K/) v = v / 1000000; printf "%.1f", v }'; }

# Plan pass mark for sockets.
judge_sockets() {
  local gbit="$1" cpu="$2"
  if awk -v g="$gbit" 'BEGIN { exit !(g > 20) }'; then desk_pass "sockets $gbit Gb/s (mark: above 20)"; else desk_fail "sockets $gbit Gb/s (mark: above 20); plan: lossless transport limited to changed regions, or RDMA moves up from optional"; fi
  if [ -n "$cpu" ]; then desk_info "CPU use reported by iperf3 (percent of all cores): $cpu. Mark is under one core."; fi
}

judge_copy() {
  local gbs="$1" what="$2"
  if awk -v g="$gbs" 'BEGIN { exit !(g > 1.5) }'; then desk_pass "$what $gbs GB/s (mark: above 1.5)"; else desk_fail "$what $gbs GB/s (mark: above 1.5); plan: try NFS, or keep Thunderbolt for streams and bulk copies only"; fi
}

inventory() {
  desk_say "Thunderbolt ports and link speeds:"
  desk_cmd system_profiler SPThunderboltDataType
  desk_say ""
  desk_say "network service order (the Thunderbolt link should be first, or traffic quietly uses Wi-Fi or Ethernet):"
  desk_cmd networksetup -listnetworkserviceorder
  desk_say ""
  desk_say "SMB multichannel state (plan 9.5 step 4):"
  desk_cmd smbutil multichannel -a
  desk_say ""
  desk_say "RDMA devices (only after 'rdma_ctl enable' in Recovery):"
  if command -v ibv_devices >/dev/null 2>&1; then desk_cmd ibv_devices; else desk_info "ibv_devices not found: RDMA not enabled or not Thunderbolt 5"; fi
}

# Refuses load tests beside Darkbloom unless --allow-darkbloom was given (Penn's go).
guard_darkbloom() {
  local ev
  if ev=$(desk_darkbloom_running); then
    if [ "$ALLOW_DB" -eq 1 ]; then desk_todo "Darkbloom is present ($ev) and --allow-darkbloom was given: the load will share the machine with it."; return 0; fi
    desk_fail "Darkbloom is present ($ev): refusing to run a load test beside it. Needs Penn's go; then add --allow-darkbloom."
    return 1
  fi
  return 0
}

# Uncached sequential read (F_NOCACHE) so a read-back is not served from this Mac's file cache.
read_uncached() {
  perl -e 'use Fcntl; open(my $f, "<", $ARGV[0]) or exit 1; fcntl($f, 48, 1); my $b; 1 while sysread($f, $b, 1048576); ' "$1"
}

run_client() {
  guard_darkbloom || return 1
  [ -n "$PEER" ] || { echo "--peer ADDRESS is required for --run client" >&2; exit 2; }
  desk_need iperf3 "brew install iperf3 (3.x) or https://github.com/esnet/iperf/releases" || return 1
  local out gb_tx gb_rx cpu
  desk_say "iperf3, $STREAMS parallel streams, ${SECONDS_T}s each way (one stream under-reads, plan 9.5):"
  out=$(iperf3 -c "$PEER" -P "$STREAMS" -t "$SECONDS_T" -V 2>&1) || { desk_fail "iperf3 client could not complete (is the server running on the other Mac?)"; return 1; }
  gb_tx=$(printf '%s\n' "$out" | iperf_gbits sender); cpu=$(printf '%s\n' "$out" | sed -n 's/.*CPU Utilization: local\/sender \([0-9.]*\)%.*/\1/p' | tail -1)
  judge_sockets "${gb_tx:-0}" "$cpu"
  out=$(iperf3 -c "$PEER" -P "$STREAMS" -t "$SECONDS_T" -R -V 2>&1) || { desk_fail "iperf3 reverse test failed"; return 1; }
  gb_rx=$(printf '%s\n' "$out" | iperf_gbits receiver); cpu=$(printf '%s\n' "$out" | sed -n 's/.*CPU Utilization: local\/receiver \([0-9.]*\)%.*/\1/p' | tail -1)
  judge_sockets "${gb_rx:-0}" "$cpu"
  desk_say "round trip, 100 pings at 0.2 s (macOS limits faster intervals to root; the plan's 1,000 pings: rerun with -c 1000 as root):"
  ping -c 100 -i 0.2 -q "$PEER" 2>&1 | tail -2 | desk_scrub
}

run_smb() {
  [ -d "$SMBDIR" ] || { echo "--dir must be an existing mounted directory" >&2; exit 2; }
  guard_darkbloom || return 1
  local work big t0 t1 bytes
  work=$(mktemp -d "${TMPDIR:-/tmp}/desk-e5.XXXXXX") || return 1
  trap 'rm -rf "$work" "${SMBDIR:?}/desk-e5-test"' EXIT
  mkdir -p "$SMBDIR/desk-e5-test"
  big="$work/big.bin"
  desk_say "creating a ${SIZE_GB} GB local test file"
  dd if=/dev/zero of="$big" bs=1048576 count=$((SIZE_GB * 1024)) 2>/dev/null
  bytes=$((SIZE_GB * 1073741824))
  t0=$(desk_now); cp "$big" "$SMBDIR/desk-e5-test/big.bin" && sync; t1=$(desk_now)
  judge_copy "$(rate_gbs "$bytes" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{print b-a}')")" "write to share"
  rm -f "$big"
  t0=$(desk_now); read_uncached "$SMBDIR/desk-e5-test/big.bin"; t1=$(desk_now)
  judge_copy "$(rate_gbs "$bytes" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{print b-a}')")" "read from share"
  if [ "$SMALL" -gt 0 ]; then
    mkdir -p "$work/small"
    i=0; while [ "$i" -lt "$SMALL" ]; do head -c 4096 /dev/zero > "$work/small/f$i"; i=$((i + 1)); done
    t0=$(desk_now); cp -R "$work/small" "$SMBDIR/desk-e5-test/small"; t1=$(desk_now)
    desk_info "$SMALL small files (4 KB) written in $(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}') s"
  fi
  desk_todo "Pull the cable by hand now: during a copy, during video from the pool, during a hosted Firefox session (RUNBOOK E5 step 5)."
}

while [ $# -gt 0 ]; do
  if desk_common_arg "$@"; then shift "$DESK_SHIFT"; continue; fi
  case "$1" in
    --run)         RUN="${2:-}"; shift 2 ;;
    --peer)        PEER="${2:-}"; shift 2 ;;
    --bind)        BIND="${2:-}"; shift 2 ;;
    --allow-darkbloom) ALLOW_DB=1; shift ;;
    --streams)     STREAMS="${2:-4}"; shift 2 ;;
    --seconds)     SECONDS_T="${2:-20}"; shift 2 ;;
    --dir)         SMBDIR="${2:-}"; shift 2 ;;
    --size-gb)     SIZE_GB="${2:-20}"; shift 2 ;;
    --small-files) SMALL="${2:-20000}"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

main() {
  case "$DESK_MODE" in
    check)
      desk_is_macos && desk_pass "macOS" || desk_fail "not macOS"
      desk_need iperf3 "brew install iperf3 (3.x) or https://github.com/esnet/iperf/releases"
      for t in system_profiler networksetup smbutil ping dd; do desk_need "$t"; done
      desk_finish ;;
    dry)
      desk_cmd system_profiler SPThunderboltDataType
      desk_cmd networksetup -listnetworkserviceorder
      desk_cmd smbutil multichannel -a
      desk_say "with --run server: would run: iperf3 -s -1 -B <thunderbolt address>   (refused if Darkbloom is present)"
      desk_say "with --run client: would run: iperf3 -c <peer> -P $STREAMS -t $SECONDS_T, then the same with -R, then ping -c 100 <peer>"
      desk_say "with --run smb: would write and read a ${SIZE_GB} GB file and $SMALL small files under <dir>/desk-e5-test, then delete them"
      exit 0 ;;
  esac
  case "$RUN" in
    "") inventory ;;
    server)
      guard_darkbloom || desk_finish
      if [ -z "$BIND" ] && command -v ifconfig >/dev/null 2>&1; then BIND=$(ifconfig bridge0 2>/dev/null | awk '/inet /{print $2; exit}'); fi
      [ -n "$BIND" ] || { desk_fail "no Thunderbolt Bridge address found: pass --bind ADDRESS (the listener never binds every interface)"; desk_finish; }
      desk_need iperf3 && { desk_say "listening for one test on the Thunderbolt address only; the other Mac runs --run client"; iperf3 -s -1 -B "$BIND"; } ;;
    client) run_client ;;
    smb) run_smb ;;
    *) echo "--run takes server, client or smb" >&2; exit 2 ;;
  esac
  desk_finish
}

if [ "${DESK_SOURCE_ONLY:-}" != 1 ]; then main; fi
