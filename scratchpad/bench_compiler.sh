#!/bin/bash
# Bench 3 — compiler throughput. Generate a large .tuck (N independent fns +
# types), then time the full front-end (lex+parse+check) via `tuck ch` and the
# whole build (adds emit) via `tuck compile`. Reports lines/sec.
#   Run: bash scratchpad/bench_compiler.sh [N]
set -e
cd "$(dirname "$0")/.."
N=${1:-20000}
BIG=scratchpad/big.tuck

# generate: N fns, each 3 lines, referencing a per-fn type. Independent so the
# checker does real work N times, no shared-symbol shortcut.
{
  for ((i=0; i<N; i++)); do
    printf 'type T%d = {a: int, b: int}\n' "$i"
    printf 'fn f%d({a: int, b: int}) -> int:\n  let s = a + b\n  return s * %d\n' "$i" "$i"
  done
} > "$BIG"
LINES=$(wc -l < "$BIG")
echo "generated $BIG: $N fns, $LINES lines, $(wc -c < "$BIG") bytes"

# tuck ch prints per-phase timing already (lex/parse/check). Time the whole cmd.
echo "--- tuck ch (lex + parse + typecheck) ---"
/usr/bin/time -v ./tuck ch "$BIG" 2>&1 | grep -iE "wall clock|Maximum resident" || true
t0=$(date +%s.%N); ./tuck ch "$BIG" > /dev/null; t1=$(date +%s.%N)
dt=$(echo "$t1 - $t0" | bc)
echo "  full check: ${dt}s  = $(echo "scale=0; $LINES / $dt" | bc) lines/sec"

echo "--- tuck compile (adds codegen) ---"
t0=$(date +%s.%N); ./tuck compile "$BIG" -o:scratchpad/big_out > /dev/null; t1=$(date +%s.%N)
dt=$(echo "$t1 - $t0" | bc)
echo "  full build: ${dt}s  = $(echo "scale=0; $LINES / $dt" | bc) lines/sec"

rm -rf scratchpad/big_out "$BIG"
