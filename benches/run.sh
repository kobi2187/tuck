#!/bin/bash
# Run all Tuck benchmarks and print a scoreboard. Compare against SCORES.md to
# spot major regressions. Not a pass/fail gate — a speed ledger.
#   Run: bash benches/run.sh
set -e
cd "$(dirname "$0")/.."

# No --path: the coroutine engine is vendored in compiler/tuck_coro.nim.
NIMFLAGS="-d:release --hints:off --warnings:off --stackTrace:off --lineTrace:off"

echo "=== building tuck ==="
nim c --hints:off --warnings:off -o:tuck tuck.nim > /dev/null 2>&1

echo "=== 1/3 async runtime scale ==="
nim c $NIMFLAGS -o:benches/.bas benches/bench_async_scale.nim > /dev/null 2>&1
benches/.bas 2>/dev/null

echo "=== 2/3 actor message throughput ==="
nim c $NIMFLAGS -o:benches/.bat benches/bench_actor_throughput.nim > /dev/null 2>&1
benches/.bat 2>/dev/null

echo "=== 3/3 compiler front-end ==="
bash benches/bench_compiler.sh

rm -f benches/.bas benches/.bat
