#!/bin/bash
# Tests for the arrival-kit scripts. Safe anywhere: touches no network, installs nothing, runs no measurement.
# Linux (CI, sandbox) and macOS CI runners. Not for use on a Darkbloom Mac.
cd "$(dirname "$0")/.." || exit 1
S=$(pwd)/scripts
FAILS=0; N=0
ok()  { N=$((N + 1)); }
bad() { N=$((N + 1)); FAILS=$((FAILS + 1)); echo "FAIL: $*"; }
eq()  { if [ "$1" = "$2" ]; then ok; else bad "$3 (got '$1', want '$2')"; fi; }
has() { if printf '%s' "$1" | grep -qF -- "$2"; then ok; else bad "$3 (missing '$2')"; fi; }
lacks() { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found '$2')"; else ok; fi; }

SCRIPTS="e2-memory-census e4-remote-launch e5-thunderbolt-speed e8-pool-test e10-profile-move preflight-new-studio"

# ---- every script: --help, --dry-run, bad argument, no identifying data ----
for s in $SCRIPTS; do
  out=$("$S/$s.sh" --help 2>&1); eq "$?" 0 "$s --help exit"; has "$out" "--dry-run" "$s --help mentions --dry-run"
  out=$("$S/$s.sh" --dry-run 2>&1); eq "$?" 0 "$s --dry-run exit"
  has "$out" "would run" "$s --dry-run prints commands"
  if printf '%s' "$out" | grep -qE '([0-9]{1,3}\.){3}[0-9]{1,3}'; then bad "$s --dry-run printed an address"; else ok; fi
  "$S/$s.sh" --no-such-flag >/dev/null 2>&1; eq "$?" 2 "$s rejects unknown flags"
  grep -q -- '--check' "$S/$s.sh" && ok || bad "$s has no --check"
done

# ---- no script installs or changes settings ----
for f in "$S"/*.sh; do
  if grep -nE '(^|[;&|[:space:]])(brew install|sudo|softwareupdate|installer |defaults write|systemsetup -set|networksetup -set|rdma_ctl enable|launchctl (load|bootstrap|enable)|pmset |csrutil (disable|enable))' "$f" | grep -vE '^[0-9]+:\s*#|desk_say|desk_todo|desk_info|desk_pass|desk_fail|desk_need|missing |echo |printf ' >/dev/null; then
    bad "$(basename "$f") contains a state-changing command outside of text"
  else ok; fi
done

# ---- scrubber ----
# shellcheck source=../scripts/lib.sh
. "$S/lib.sh"
U=$(id -un); H=$(hostname)
sample="user=$U host=$H home=$HOME ip=192.168.1.20 and 10.0.0.5 mac=aa:bb:cc:dd:ee:ff v6=fe80::1c2:3d4:5e6:7f8 uuid=123e4567-e89b-12d3-a456-426614174000 mail=person@example.com name=studio-b.local"
out=$(printf '%s\n' "$sample" | desk_scrub)
for needle in "192.168.1.20" "10.0.0.5" "aa:bb:cc:dd:ee:ff" "fe80::" "123e4567" "person@example.com" "studio-b.local"; do lacks "$out" "$needle" "scrub removes $needle"; done
if [ "${#U}" -ge 2 ]; then lacks "$out" "user=$U" "scrub removes user name"; fi
if [ "${#H}" -ge 2 ]; then lacks "$out" "host=$H" "scrub removes host name"; fi
has "$out" "<ip>" "scrub marks ip"; has "$out" "<email>" "scrub marks email"; has "$out" "<mac>" "scrub marks mac"
keep=$(printf 'time 12:34:56 version 26.2.1 value 42\n' | desk_scrub)
has "$keep" "12:34:56" "scrub keeps a clock time"; has "$keep" "26.2.1" "scrub keeps a three-part version"

# ---- E2 maths ----
# shellcheck source=/dev/null
DESK_SOURCE_ONLY=1 . "$S/e2-memory-census.sh"
vm='Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                               100000.
Pages active:                             200000.
Pages inactive:                           300000.
Pages speculative:                         10000.
Pages purgeable:                           20000.
Pages wired down:                         150000.
Pages occupied by compressor:              50000.'
kv=$(printf '%s\n' "$vm" | parse_vm_stat 16384)
has "$kv" "free_mb=1562" "E2 free"; has "$kv" "wired_mb=2343" "E2 wired"
eq "$(printf '%s\n' "$kv" | sed -n 's/^available_mb=//p')" 6718 "E2 available = free+inactive+speculative+purgeable (in pages, then MB)"
T=$(mktemp -d)
printf 'total_mb=98304\navailable_mb=90000\nswap_used_mb=0\n' > "$T/b.kv"
printf 'total_mb=98304\navailable_mb=80000\nswap_used_mb=12\ndarkbloom_running=yes\n' > "$T/a.kv"
out=$(DESK_LABEL=second compare "$T/b.kv" "$T/a.kv" 2>&1)
has "$out" "darkbloom_footprint_mb = 10000" "E2 footprint is the difference in used memory"
has "$out" 'PASS  more than 20 GB of headroom' "E2 headroom pass"
printf 'total_mb=98304\navailable_mb=89900\nswap_used_mb=0\ndarkbloom_running=no\n' > "$T/c.kv"
out=$(compare "$T/b.kv" "$T/c.kv" 2>&1)
has "$out" "did not see a Darkbloom process" "E2 warns when Darkbloom was not running"
has "$out" "under 500 MB" "E2 warns on a tiny difference"
printf 'total_mb=65536\navailable_mb=1\n' > "$T/d.kv"
out=$(compare "$T/b.kv" "$T/d.kv" 2>&1); has "$out" "different memory sizes" "E2 refuses mismatched machines"
rm -rf "$T"

# ---- E5 maths ----
# shellcheck source=/dev/null
DESK_SOURCE_ONLY=1 . "$S/e5-thunderbolt-speed.sh"
eq "$(printf '[SUM]   0.00-20.00  sec  52.3 GBytes  22.5 Gbits/sec  sender\n[SUM]   0.00-20.00  sec  52.2 GBytes  22.4 Gbits/sec  receiver\n' | iperf_gbits sender)" 22.5 "E5 parses sender"
eq "$(printf '[SUM]   0.00-20.00  sec  52.3 GBytes  22.5 Gbits/sec  sender\n[SUM]   0.00-20.00  sec  52.2 GBytes  22.4 Gbits/sec  receiver\n' | iperf_gbits receiver)" 22.4 "E5 parses receiver"
eq "$(printf '[SUM] 0-1 sec 900 Mbits/sec sender\n' | iperf_gbits sender)" 0.9 "E5 converts Mbits"
eq "$(rate_gbs 21474836480 10)" 2.15 "E5 GB per second"
DESK_FAILED=0; out=$(judge_sockets 25.0 "" 2>&1); has "$out" "PASS" "E5 25 Gb/s passes"
out=$(judge_sockets 12.0 "" 2>&1); has "$out" "FAIL" "E5 12 Gb/s fails"
out=$(judge_copy 1.2 "write" 2>&1); has "$out" "FAIL" "E5 1.2 GB/s copy fails"
out=$(judge_copy 2.0 "write" 2>&1); has "$out" "PASS" "E5 2.0 GB/s copy passes"

# ---- E10 mark ----
# shellcheck source=/dev/null
DESK_SOURCE_ONLY=1 . "$S/e10-profile-move.sh"
out=$(judge 12.5 2>&1); has "$out" "PASS" "E10 12.5 s passes"
out=$(judge 45 2>&1); has "$out" "FAIL" "E10 45 s fails"

# ---- E10 refuses to copy while the browser runs (uses a long-lived process named like the browser) ----
T=$(mktemp -d); mkdir -p "$T/p" "$T/d"; echo x > "$T/p/f"
# shellcheck disable=SC2016
out=$(env DESK_BROWSER_PROCESS=sleep bash -c 'sleep 30 & P=$!; "'"$S"'/e10-profile-move.sh" --run --profile "'"$T"'/p" --dest "'"$T"'/d" 2>&1; kill $P')
has "$out" "is running" "E10 refuses while the browser runs"
[ ! -e "$T/d/desk-e10-copy" ] && ok || bad "E10 copied while running"
out=$(DESK_BROWSER_PROCESS=nonexistentbrowser "$S/e10-profile-move.sh" --run --profile "$T/p" --dest "$T/d" 2>&1)
has "$out" "profile copy took" "E10 times a copy"
[ ! -e "$T/d/desk-e10-copy" ] && ok || bad "E10 left the copy behind"
lacks "$out" "$T" "E10 does not print the paths"
rm -rf "$T"

# ---- review round 2 ----
# scrub: id forms and a name with spaces
out=$(printf 'id 0x1234567890abcdef0 and 1234567890ABCDEF and host.corp x.ts.net\n' | desk_scrub)
lacks "$out" "1234567890" "scrub removes 16-digit and 0x ids"; lacks "$out" "host.corp" "scrub removes .corp host"
# Darkbloom detection by command line, with the pattern override
T=$(mktemp -d); printf '%s\n' '#!/bin/sh' 'sleep 30' > "$T/xq-fake-service"; chmod +x "$T/xq-fake-service"
"$T/xq-fake-service" 30 & FP=$!
out=$(DESK_DARKBLOOM_PATTERN=xq-fake-service desk_darkbloom_running); eq "$?" 0 "Darkbloom check finds a matching process"; has "$out" process "evidence names the process"
if DESK_DARKBLOOM_PATTERN=zz-no-such-thing-zz desk_darkbloom_running >/dev/null; then bad "false positive on an absent name"; else ok; fi
# E5 refuses load modes beside Darkbloom, E2 baseline refuses it too
out=$(DESK_DARKBLOOM_PATTERN=xq-fake-service "$S/e5-thunderbolt-speed.sh" --run smb --dir "$T" 2>&1); eq "$?" 1 "E5 refuses beside Darkbloom"; has "$out" "refusing" "E5 says why"
out=$(DESK_DARKBLOOM_PATTERN=xq-fake-service "$S/e5-thunderbolt-speed.sh" --run server 2>&1); has "$out" "refusing" "E5 server refuses beside Darkbloom"
# E2 uses the larger of the system difference and the process figure
printf 'total_mb=98304\navailable_mb=90000\nswap_used_mb=0\ndarkbloom_running=no\n' > "$T/b.kv"
printf 'total_mb=98304\navailable_mb=89000\nswap_used_mb=0\ndarkbloom_running=yes\ndarkbloom_rss_mb=30000\n' > "$T/a.kv"
out=$(compare "$T/b.kv" "$T/a.kv" 2>&1); has "$out" "darkbloom_footprint_mb = 30000" "E2 takes the larger process figure"
printf 'total_mb=98304\navailable_mb=90000\ndarkbloom_running=yes\n' > "$T/b2.kv"
out=$(compare "$T/b2.kv" "$T/a.kv" 2>&1); has "$out" "not a clean baseline" "E2 rejects a dirty baseline"
kill "$FP" 2>/dev/null; wait "$FP" 2>/dev/null
# E8 refuses a non-empty work directory (before any mount is tried), even with the backend missing it reports and touches nothing
mkdir -p "$T/bin" "$T/w" && printf '#!/bin/sh\n' > "$T/bin/rclone" && chmod +x "$T/bin/rclone" && echo keep > "$T/w/precious"
out=$(PATH="$T/bin:$PATH" DESK_SOURCE_ONLY=1 bash -c '. "'"$S"'/e8-pool-test.sh"; have_fuse() { return 0; }; WORK="'"$T"'/w"; pool_run' 2>&1)
has "$out" "not empty" "E8 refuses a non-empty work directory"; [ -f "$T/w/precious" ] && ok || bad "E8 touched a non-empty directory"
# E8 work path with a quote does not break cleanup
mkdir -p "$T/it's here"; DESK_SOURCE_ONLY=1 bash -c '. "'"$S"'/e8-pool-test.sh"; WORK="'"$T"'/it'"'"'s here"; mkdir "$WORK/m1"; CREATED_M1=1; cleanup'; [ ! -e "$T/it's here/m1" ] && ok || bad "E8 cleanup failed on a quoted path"
rm -rf "$T"

echo "arrival-kit tests: $N checks, $FAILS failed"
[ "$FAILS" -eq 0 ]
