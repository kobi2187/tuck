#!/bin/bash
# Bench 3 — compiler front-end throughput. Generate a large .tuck (N independent
# type+fn pairs), time `tuck ch` (lex+parse+typecheck). Reports lines/sec.
# Front-end scales linearly (~24k lines/sec on this box up to 12k fns).
#   Run: bash benches/bench_compiler.sh [N]
set -e
cd "$(dirname "$0")/.."
N=${1:-8000}
BIG=benches/.big.tuck

# generate N independent fns (awk — bash printf-loop is too slow at scale).
awk -v n="$N" 'BEGIN{
  for(i=0;i<n;i++){
    printf "type T%d = {a: int, b: int}\n", i
    printf "fn f%d({a: int, b: int}) -> int:\n  let s = a + b\n  return s * %d\n", i, i
  }
}' > "$BIG"
LINES=$(wc -l < "$BIG")

# warm the msgpack import cache (first run pays cold-cache cost); measure the 2nd.
./tuck ch "$BIG" > /dev/null 2>&1 || true
t0=$(date +%s.%N); ./tuck ch "$BIG" > /dev/null 2>&1; t1=$(date +%s.%N)
dt=$(echo "$t1 - $t0" | bc)
echo "compiler front-end: N=$N fns, $LINES lines"
echo "  tuck ch (lex+parse+check): ${dt}s  = $(echo "scale=0; $LINES / $dt" | bc) lines/sec"

rm -f "$BIG"
