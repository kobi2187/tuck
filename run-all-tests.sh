#!/bin/bash
# Runs every tests/*.sh and reports a single pass/fail gate.
#
# THE PIPELINE, and why it is this shape: nim builds tuck ONCE, then tuck
# builds the examples, then the tests run against that one binary. Nim is
# invoked exactly once in the whole suite.
#
# It used to be invoked ten times. Every test was a Nim program that did
# `import ../compiler/codegen` — linking the compiler in to call it as a
# library — so `nim c` re-ran semantic analysis over the entire compiler once
# per test file before a single assertion executed. On top of that,
# compile_all_examples re-verified the emitted Nim with ~25 serial `nim check`
# calls, re-answering a question tuck's own typechecker had already answered.
#
# Now every test drives the ./tuck BINARY from shell (assertions in
# tests/lib.sh), which is what most of them were morally doing anyway —
# known_bugs and odin_backend already shelled out to subprocesses and imported
# nothing from the compiler at all.
set -u
cd "$(dirname "$0")"

failures=0

# Stage timings. This is a compiler project, so the pipeline has three stages
# worth measuring separately — nim builds tuck, tuck builds the examples, then
# the tests run. Knowing WHICH stage got slower is the whole point; a single
# wall-clock number for the suite tells you nothing about where it went.
t0=$(date +%s.%N)
stage_secs() { echo "scale=1; ($(date +%s.%N) - $1)/1" | bc; }

# tests/odin_backend.sh checks emitted Odin that it does not itself produce —
# it expects examples/*.odin to already be on disk and reports "missing emitted
# Odin" for every one that is not. Those are build artifacts (not committed),
# so generate them here or the whole Odin layer reports phantom failures.
echo "== stage 1: nim builds tuck =="
ts=$(date +%s.%N)
nim c --hints:off --warnings:off -o:tuck tuck.nim || { echo "FAIL: cannot build tuck"; exit 1; }
nim_secs=$(stage_secs $ts)
tuck_bytes=$(stat -c%s tuck)
echo "  ${nim_secs}s, tuck binary $(numfmt --to=iec $tuck_bytes)"

n_tuck=$(ls examples/*.tuck | wc -l)
echo "== stage 2: tuck builds ${n_tuck} examples -> .odin (parallel x$(nproc)) =="
# One tuck process per example, $(nproc) at a time. These are independent
# single-file compiles writing to distinct outputs, so parallelism is free —
# verified byte-identical to the serial loop. Serial was 26s of the suite.
# Each job prints its own name as it finishes, so a hang is visible.
#
# `tuck c`, NOT `tuck build`: all this stage owes odin_backend.sh is the
# emitted .odin files. `build` additionally links a Nim binary per example,
# which nothing here reads — 6.8s of the suite for artifacts it discards.
#
# The check is for the .odin ARTIFACT rather than tuck's exit status: the
# FFI examples emit Odin fine and then fail at the Nim backend for want of
# their C fixtures, which reported as "no-odin" for files that were right
# there on disk. `no-odin` is not a failure either way — a few examples have
# no Odin path yet, and tests/odin_backend.sh owns the actual gate list.
ts=$(date +%s.%N)
ls examples/*.tuck | xargs -P "$(nproc)" -I{} sh -c \
  './tuck c "$1" --odin >/dev/null 2>&1
   n=$(basename "$1" .tuck)
   if [ -f "examples/$n.odin" ]; then printf "  ok        %s\n" "$n"
   else printf "  no-odin   %s\n" "$n"; fi' _ {}
emit_secs=$(stage_secs $ts)
n_odin=$(ls examples/*.odin 2>/dev/null | wc -l)
echo "  -> ${emit_secs}s, ${n_odin}/${n_tuck} emitted"

# Every test is a shell script driving the ./tuck binary built in stage 1.
# They used to be Nim programs importing compiler/*, so `nim c` rebuilt the
# whole compiler once PER TEST — ten builds to run nine tests. tests/lib.sh
# holds the assertions.
test_files=$(ls tests/*.sh | grep -v '/lib\.sh$')

echo "== stage 3: tests ($(echo "$test_files" | wc -l) files, parallel) =="
ts=$(date +%s.%N)
logdir=$(mktemp -d)
trap 'rm -rf "$logdir"' EXIT

# Every test script allocates its own mktemp -d scratch and shells out to the
# already-built ./tuck, so they share nothing writable and all run at once.
# Serial, this stage was dominated by three scripts doing the SAME thing in a
# loop — cli_smoke's 30 `tuck build` calls (28s), odin_backend's 35
# `odin build` calls, known_bugs' 13 — each fork costing ~0.85s of Nim
# compile-and-link that no amount of test-side cleverness removes. The only
# lever left is overlapping them.
#
# Output is captured per test and printed after, since interleaved live output
# from 21 concurrent scripts is unreadable.
#
# BOUNDED to core count. Launching all 21 at once with TEST_JOBS=2 each put up
# to 42 Nim compiles on $(nproc) cores; every one of them is a full
# compile-and-link, so they thrash rather than overlap. Measured:
# known_bugs.sh takes 11.7s alone and 37.6s in that pile-up — a 3.2x
# contention tax, and since the stage cannot finish before its slowest script,
# that tax WAS the stage.
#
# Longest-first, so the critical-path scripts start immediately rather than
# landing last behind a queue of short ones.
# Inner parallelism stays: odin_backend fans 36 `odin build` calls out over
# TEST_JOBS, and serializing those cost more than the contention it saved
# (37.4s vs 33.2s). What changed is the OUTER bound — 21 scripts at once on
# $(nproc) cores was the pile-up.
export TEST_JOBS=3
_slowest="known_bugs.sh interface_seq.sh odin_backend.sh cli_smoke.sh auto_alias.sh object_composition.sh loop_var_type.sh interface_dispatch.sh"
_ordered=""
for b in $_slowest; do
  [ -f "tests/$b" ] && _ordered="$_ordered tests/$b"
done
for f in $test_files; do
  case " $_ordered " in *" $f "*) ;; *) _ordered="$_ordered $f";; esac
done

# NOT a shared TUCK_NIMCACHE. Sharing one cache per script looked like a 3x
# win in isolation (0.85s -> 0.27s per build, since the runtime compiles once)
# and made the suite 7x SLOWER — 43s to 301s, with a failure. Builds inside a
# script are not sequential: TEST_JOBS fans them out, and concurrent nim
# invocations against one cache serialize on it and corrupt each other.
# Measure the suite, not the microbenchmark.
printf '%s\n' $_ordered | xargs -P "$(nproc)" -I{} sh -c '
  f="$1"; b=$(basename "$f")
  start=$(date +%s.%N)
  bash "$f" > "'"$logdir"'/$b.out" 2>&1
  echo $? > "'"$logdir"'/$b.rc"
  echo "scale=1; ($(date +%s.%N) - $start)/1" | bc > "'"$logdir"'/$b.t"' _ {}

for f in $test_files; do
  b=$(basename "$f")
  status=$(cat "$logdir/$b.rc")
  printf '%-28s %ss\n' "-- $b" "$(cat "$logdir/$b.t")"
  # The verdict line each script ends with, plus any OPEN bug notes.
  grep -E "passed, [0-9]+ failed|^open bugs:|^  OPEN " "$logdir/$b.out" | sed 's/^/     /'
  if [ "$status" -ne 0 ]; then
    echo "FAIL: $f exited $status — full output:"
    sed 's/^/     /' "$logdir/$b.out"
    failures=$((failures + 1))
  fi
done

test_secs=$(stage_secs $ts)

echo ""
echo "--- timings ---"
printf '  %-22s %6ss  (tuck binary %s)\n' "nim -> tuck"      "$nim_secs"  "$(numfmt --to=iec $tuck_bytes)"
printf '  %-22s %6ss  (%s examples, %s each)\n' "tuck -> odin" "$emit_secs" "$n_odin" \
  "$(echo "scale=2; $emit_secs / $n_odin" | bc)s"
printf '  %-22s %6ss\n' "tests" "$test_secs"
printf '  %-22s %6ss\n' "total" "$(stage_secs $t0)"

if [ $failures -gt 0 ]; then
  echo "$failures failure(s)."
  exit 1
fi
echo "All tests passed."
