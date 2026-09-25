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
cd "$(dirname "$0")/../.."
N=${1:-200000}
N2=$((N * 2))
TUCK=$PWD/tuck
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- the programs --------------------------------------------------------------
#
# One directory per pattern and size: Odin compiles a directory as a package.
gen() {  # dir n
  local out=$1 n=$2
  mk() { mkdir -p "$out/$1"; cat > "$out/$1/b.tuck"; }

  # #77's shape. A copy per turn that the binding must make, and the old
  # value freed at the OVERWRITE (fkOverwrite): 1024 ints per turn.
  mk copy_loop <<EOF
import seq

fn zeroed({levels: int}) -> Seq[int]:
  var out = [0]
  var i = 1
  for i < levels:
    out = {items: out, value: 0} push
    i = i + 1
  return out

fn bump({xs: Seq[int]}) -> Seq[int]:
  var ys = xs
  ys[0] = ys[0] + 1
  return ys

fn main() -> int:
  var xs = {levels: 1024} zeroed
  var i = 0
  for i < $n:
    let ns = {xs: xs} bump
    xs = ns
    i = i + 1
  if xs[0] != $n:
    return 1
  return 0
EOF

  # #82's shape. A record with two Seq fields threaded through two MOVED
  # twins; one field of the last result is kept. Each twin frees the slots
  # it does not hand on (fkTwinParam, per slot); each local frees the slots
  # that do not escape (fkScopeExit, per slot).
  mk chain <<EOF
import seq

type Flood:
  height: Seq[int]
  light:  Seq[int]
  n:      int

fn zeroed({levels: int}) -> Seq[int]:
  var out = [0]
  var i = 1
  for i < levels:
    out = {items: out, value: 0} push
    i = i + 1
  return out

fn step({f: Flood}) -> Flood:
  var l = f.light
  l[0] = l[0] + 1
  return {height: f.height, light: l, n: f.n + 1} Flood

fn relight({h: Seq[int], l: Seq[int]}) -> Seq[int]:
  let a = {height: h, light: l, n: 0} Flood
  let b = {f: a} step
  let c = {f: b} step
  return c.light

fn main() -> int:
  let h = {levels: 1024} zeroed
  let l = {levels: 1024} zeroed
  var i = 0
  var acc = 0
  for i < $n:
    let out = {h: h, l: l} relight
    acc = acc + out[0]
    i = i + 1
  if acc != 2 * $n:
    return 1
  return 0
EOF

  # A value overwritten by one built FROM it: the old buffer must die after
  # the replacement is built, not before (a use-after-free on Odin until
  # 2026-09-25). 256 pushes per turn, so the in-place append is in it too.
  mk overwrite <<EOF
import seq

fn fresh({k: int, size: int}) -> Seq[int]:
  var out = [k]
  var i = 1
  for i < size:
    out = {items: out, value: k} push
    i = i + 1
  return out

fn main() -> int:
  var xs = {k: 0, size: 256} fresh
  var i = 0
  for i < $n:
    xs = {k: xs[0] + 1, size: 256} fresh
    i = i + 1
  if xs[0] != $n:
    return 1
  return 0
EOF

  # Value semantics that COSTS: `var t = xs` in the callee must copy (the
  # write to t may not reach the caller), and the copy is freed at scope
  # exit. The caller's value never changes.
  mk value_copy <<EOF
import seq

fn zeroed({levels: int}) -> Seq[int]:
  var out = [0]
  var i = 1
  for i < levels:
    out = {items: out, value: 0} push
    i = i + 1
  return out

fn poke({xs: Seq[int]}) -> int:
  var t = xs
  t[0] = t[0] + 1
  return t[0]

fn main() -> int:
  let xs = {levels: 1024} zeroed
  var i = 0
  var acc = 0
  for i < $n:
    acc = acc + {xs: xs} poke
    i = i + 1
  if xs[0] != 0 or acc != $n:
    return 1
  return 0
EOF

  # A local that TAKES a twin's parameter at its last read: no copy, and the
  # local is the buffer's only owner — freed once, not also by the twin.
  mk transfer <<EOF
import seq

fn fresh({k: int, size: int}) -> Seq[int]:
  var out = [k]
  var i = 1
  for i < size:
    out = {items: out, value: k} push
    i = i + 1
  return out

fn drop({xs: Seq[int]}) -> Seq[int]:
  let t = xs
  let n = t.len
  return {k: n, size: 64} fresh

fn main() -> int:
  var a = {k: 0, size: 64} fresh
  var i = 0
  for i < $n:
    a = {xs: a} drop
    i = i + 1
  if a[0] != 64:
    return 1
  return 0
EOF

  # Temporary strings: the runtime's allocating procs (toStr, concat) hand
  # back storage the caller owns, freed at scope exit.
  mk str_temps <<EOF
import str

fn main() -> int:
  var acc = 0
  var i = 0
  for i < $n * 10:
    let s = i.toStr
    let t = s + "-" + s
    acc = acc + t.len
    i = i + 1
  if acc < $n * 10:
    return 1
  return 0
EOF
}

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

run() {  # binary args... -> "ms peakKB" or "FAIL"
  local peak=0 cur t0 t1 rc
  t0=$(date +%s%N)
  "$@" >/dev/null 2>&1 &
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
  [ "$rc" -ne 0 ] && { echo "FAIL"; return; }
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
    if [ "$a" = "-" ] || [ "$b" = "-" ] || [ "$a" = "FAIL" ] || [ "$b" = "FAIL" ]; then
      printf "%-11s %-8s %8s %8s\n" "$name" "$label" "$a" "$b"
      name=""
      continue
    fi
    read -r ta ka <<< "$a"
    read -r tb kb <<< "$b"
    ratio=$(awk -v x="$tb" -v y="$ta" 'BEGIN { if (y < 20) print "~"; else printf "%.1f", x / y }')
    printf "%-11s %-8s %8s %8s %6s %9s %9s\n" "$name" "$label" "$ta" "$tb" \
           "$ratio" "$(mb "$ka")" "$(mb "$kb")"
    name=""
  done
done
