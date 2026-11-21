#!/usr/bin/env bash
# Fast host path for `tuck sim --host`: build against the host shims and run.
# No cross-toolchain, no QEMU: this validates logic and the scheduler in the
# time it takes a backend compiler to run. The freestanding/QEMU loop is
# freestanding-loop.sh; this is the 80% case before you flash anything.
#
# By default all three available backends run (Nim, Odin, D) and their output
# is left on stdout so it can be compared byte-for-byte. A backend whose
# compiler is not installed is reported as SKIP, not as a failure.
#
# Usage: ./host-loop.sh [stage] [nim|odin|d|all]
set -u
STAGE="${1:-stage9_minimal_task}"
BACKEND="${2:-all}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# Accept either a stage name (bare_metal_led) or a file path (foo/bar.tuck).
if [[ "$STAGE" == *.tuck || "$STAGE" == */* ]]; then
  SRC="$STAGE"
  BASE="$(basename "$STAGE" .tuck)"
else
  BASE="$STAGE"
  SRC="testing_experiment/${BASE}.tuck"
fi

# Cleanup is PER BACKEND inside run_one, not here: the test harness can drive
# several backends of the same stage in parallel, and one backend wiping the
# shared root would make another's binary vanish mid-run.
OUT_ROOT="/tmp/scratchpad/host_${BASE}"

have() {
  case "$1" in
    nim)  return 0 ;;
    odin) command -v odin >/dev/null 2>&1 ;;
    d)    command -v dmd >/dev/null 2>&1 || command -v ldc2 >/dev/null 2>&1 ;;
    *)    return 1 ;;
  esac
}

# One build+run. Each backend gets a fresh dir (no stale .nimcache/.o) and a
# distinct binary name, which is what `tuck b` emits for that target.
run_one() {
  local be="$1" flag="" bin=""
  case "$be" in
    nim)  flag="";        bin="${BASE}" ;;
    odin) flag="--odin";  bin="${BASE}_odin" ;;
    d)    flag="--dlang"; bin="${BASE}_d" ;;
    *) echo "!!! unknown backend: $be"; return 2 ;;
  esac
  local out="$OUT_ROOT/$be"
  rm -rf "$out"; mkdir -p "$out"
  echo "=== $be: build ==="
  ./tuck b "$SRC" $flag -o:"$out" 2>&1 | tail -5
  if [ ! -f "$out/$bin" ]; then
    echo "!!! $be: no binary produced"
    return 1
  fi
  echo "=== $be: run ==="
  "$out/$bin"
  local rc=$?
  echo "$be exit: $rc"
  return "$rc"
}

if [ "$BACKEND" != "all" ]; then
  if ! have "$BACKEND"; then
    echo "SKIP $BACKEND: compiler not found"
    exit 0
  fi
  run_one "$BACKEND"
  exit $?
fi

fail=0
ran=0
for be in nim odin d; do
  if ! have "$be"; then
    echo "SKIP $be: compiler not found"
    continue
  fi
  ran=$((ran + 1))
  run_one "$be" || fail=1
done
if [ "$ran" -eq 0 ]; then
  echo "!!! no backend compiler available"
  exit 1
fi
echo "=== three-target summary: $([ "$fail" -eq 0 ] && echo PASS || echo FAIL) ==="
exit "$fail"
