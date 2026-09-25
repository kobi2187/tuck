#!/usr/bin/env bash
# MEMORY STRESS, ACROSS BACKENDS — the heap paths the ownership pass decides,
# each hammered in a loop, built and run on Nim, Odin and D.
#
#   bash benches/memory/run.sh [N]        # default N=200000
#   PATTERNS="chain str_temps" bash benches/memory/run.sh   # a subset
#
# Each program runs at N and 2N. Two readings per row:
#
#   time   ratio t(2N)/t(N) ~2 is linear. Beyond that, compare ACROSS
#          backends: the runtime characteristics are not supposed to depend
#          on the target.
#   RSS    peak resident memory at N and at 2N. The same number twice means
#          nothing accumulates — every buffer a turn allocates is released.
#          Growth with N is a leak, whatever the absolute figure.
#
# Nim frees through ORC (its default) and D through its GC; Odin frees only
# what the ownership pass tells it to, so Odin's RSS column is the one this
# bench is really about. Every program checks its own answer and exits non-zero if it
# is wrong, so a fast wrong run cannot read as a win ("FAIL" in the row).
#
# Speed ledger, not a gate. Results and the baseline go in benches/SCORES.md.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE/../.."
N=${1:-200000}
N2=$((N * 2))
TUCK=${TUCK:-$PWD/tuck}   # a frozen copy keeps a long run immune to rebuilds
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- the programs --------------------------------------------------------------
. "$HERE/programs.sh"

gen "$WORK/a" "$N"
gen "$WORK/b" "$N2"

# --- the variants ------------------------------------------------------------
#
# label | tuck flags | binary suffix | run-time arguments
#
# The three backends as they ship, then the same programs with automatic
# memory management switched OFF, to show what it costs and what it buys:
#
#   nim-arc   --mm:arc — reference counting with no cycle collector. What
#             ORC (Nim 2's default) is minus its tracing part; frees stay
#             deterministic.
#   nim-none  --mm:none — nothing is ever freed. Allocation cost alone, and
#             the RSS that ownership has to claw back.
#   d-nogc    `--DRT-gcopt=disable:1` — D's collector never runs, so every
#             allocation stays. Same binary as `d`.
#
# Odin has no collector to switch off: its frees are the ones the ownership
# pass decided, which is the point of comparing it against these.
VARIANTS=(
  "nim|||"
  "nim-arc|--nim:--mm:arc||"
  "nim-none|--nim:--mm:none||"
  "odin|--odin|_odin|"
  "d|--dlang|_d|"
  "d-nogc|--dlang|_d|--DRT-gcopt=disable:1"
)
[ -n "${VARIANTS_ONLY:-}" ] && read -r -a VARIANTS <<< "$VARIANTS_ONLY"

# --- measuring ---------------------------------------------------------------

# Every run is capped in address space. The no-free variants allocate
# without bound — `nim-none` reached 7 GB on copy_loop at N=200000 — and an
# uncapped one takes the machine down with it. A capped run that runs out
# reports OOM, which is itself the reading: that variant cannot hold the load.
MEMCAP_KB=${MEMCAP_KB:-3145728}   # 3 GB

run() {  # binary args... -> "ms peakKB" | "OOM" | "FAIL"
  local peak=0 cur t0 t1 rc
  t0=$(date +%s%N)
  ( ulimit -v "$MEMCAP_KB"; exec "$@" ) >/dev/null 2>&1 &
  local pid=$!
  # VmHWM is the kernel's own high-water mark, so a sample can only miss a
  # peak by reading too early — never under-report one already reached.
  while kill -0 "$pid" 2>/dev/null; do
    cur=$(awk '/VmHWM/{print $2}' "/proc/$pid/status" 2>/dev/null)
    [ -n "$cur" ] && [ "$cur" -gt "$peak" ] && peak=$cur
    sleep 0.005
  done
  wait "$pid"; rc=$?
  t1=$(date +%s%N)
  if [ "$rc" -ne 0 ]; then
    # Near the cap: out of memory, not a wrong answer.
    if [ "$peak" -gt $((MEMCAP_KB / 4)) ]; then echo "OOM"; else echo "FAIL"; fi
    return
  fi
  echo "$(( (t1 - t0) / 1000000 )) $peak"
}

measure() {  # dir flags suffix runargs -> "ms peakKB" | "-" (no build) | "FAIL"
  local d=$1 flags=$2 sfx=$3 runargs=$4
  # Each distinct build gets its own output directory: the Nim variants all
  # produce a binary called `b`, and Odin compiles a directory as a package.
  local out="$d/out${flags//[^a-z]/_}"
  if [ ! -x "$out/b$sfx" ]; then
    timeout 300 "$TUCK" b "$d/b.tuck" $flags --release --max-fn-lines:0 \
      --max-complexity:0 -o:"$out" >/dev/null 2>&1 || { echo "-"; return; }
  fi
  [ -x "$out/b$sfx" ] || { echo "-"; return; }
  # shellcheck disable=SC2086  # runargs is empty or one word, on purpose
  run "$out/b$sfx" $runargs
}

mb() { awk -v k="$1" 'BEGIN { printf "%.1f", k / 1024 }'; }

echo "memory stress: N=$N vs 2N=$N2, release builds"
echo "(ratio ~2 = linear time; RSS(N) ~ RSS(2N) = nothing accumulates)"
printf "\n%-11s %-8s %8s %8s %6s %9s %9s\n" \
       "pattern" "variant" "t(N)ms" "t(2N)ms" "ratio" "RSS(N)MB" "RSS(2N)MB"
for p in ${PATTERNS:-copy_loop chain overwrite value_copy transfer str_temps}; do
  name=$p                 # printed on the first variant's row only
  for spec in "${VARIANTS[@]}"; do
    IFS='|' read -r label flags sfx runargs <<< "$spec"
    a=$(measure "$WORK/a/$p" "$flags" "$sfx" "$runargs")
    b=$(measure "$WORK/b/$p" "$flags" "$sfx" "$runargs")
    # Each side is "ms peakKB", or a status ("-" no build, FAIL, OOM) that
    # stands in both of its columns.
    read -r ta ka <<< "$a"
    read -r tb kb <<< "$b"
    ra=$( [ -n "${ka:-}" ] && mb "$ka" || echo "$ta" )
    rb=$( [ -n "${kb:-}" ] && mb "$kb" || echo "$tb" )
    ratio="-"
    if [ -n "${ka:-}" ] && [ -n "${kb:-}" ]; then
      ratio=$(awk -v x="$tb" -v y="$ta" 'BEGIN { if (y < 20) print "~"; else printf "%.1f", x / y }')
    fi
    printf "%-11s %-8s %8s %8s %6s %9s %9s\n" "$name" "$label" "$ta" "$tb" \
           "$ratio" "$ra" "$rb"
    name=""
  done
done
