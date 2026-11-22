#!/usr/bin/env bash
# Source-level debugging on the QEMU target (T16, metal half): build a stage
# freestanding, boot it HALTED under QEMU with a gdbstub, and stop gdb at a
# Tuck source line. Prints the backtrace and exits; a breakpoint never hit is
# exit 1. Needs gdb-multiarch (or arm-none-eabi-gdb) on PATH.
#
# Usage: ./gdb-run.sh STAGE LINE [PORT]
#   STAGE  a stage name (task_await) or a .tuck path
#   LINE   the line in that .tuck file to break at
#   PORT   gdbstub TCP port (default 3333; give each parallel caller its own)
set -u
STAGE="$1"; LINE="$2"; PORT="${3:-3333}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BASE="$(basename "$STAGE" .tuck)"
GDB="$(command -v gdb-multiarch || command -v arm-none-eabi-gdb || true)"
if [ -z "$GDB" ]; then echo "SKIP: no ARM-capable gdb (gdb-multiarch / arm-none-eabi-gdb)"; exit 0; fi
OUT="${TUCK_OUT_DIR:-${TMPDIR:-/tmp}/tuck-metal/gdb_${BASE}}"
mkdir -p "$(dirname "$OUT")"
TUCK_OUT_DIR="$OUT" "$ROOT/tools/metal/qemu-run.sh" "$STAGE" >"$OUT.build.log" 2>&1
ELF="$OUT/$BASE"
if [ ! -f "$ELF" ]; then echo "!!! no ELF produced (see $OUT.build.log)"; exit 1; fi
BOARD="${TUCK_BOARD:-lm3s6965evb}"
qemu-system-arm -M "$BOARD" -semihosting-config enable=on,target=native \
  -nographic -kernel "$ELF" -gdb "tcp::$PORT" -S >"$OUT.qemu.log" 2>&1 &
QPID=$!
trap 'kill $QPID 2>/dev/null' EXIT
sleep 0.5
LOG="$(timeout 30 "$GDB" -q -batch -ex 'set debuginfod enabled off' \
  -ex "target remote :$PORT" -ex "break $BASE.tuck:$LINE" -ex continue \
  -ex bt -ex 'kill' "$ELF" 2>&1)"
echo "$LOG"
echo "$LOG" | grep -q "^#0 .* at .*$BASE.tuck:$LINE" || exit 1
