#!/usr/bin/env bash
# Feedback loop for the freestanding (bare-metal) experiment on QEMU.
# Usage: ./freestanding-loop.sh [stage]
#   Builds tuck, compiles the stage freestanding (ARM/Thumb, no OS/heap),
#   links with a template startup + linker script, and boots it under
#   qemu-system-arm. A clean run ends in the idle loop (timeout, no fault).
set -u
STAGE="${1:-bare_metal_led}"
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
export PATH=/root/toolchains/nim/bin:/root/toolchains/odin:/root/toolchains/ldc2/bin:/root/toolchains/dmd2/linux/bin64:$PATH
export TUCK_CC=gcc   # keep gcc so we can point --gcc.exe at arm-none-eabi-gcc

echo "=== build tuck ==="
nim c --hints:off -o:tuck tuck.nim 2>&1 | tail -2 || exit 1

OUT="/tmp/scratchpad/freestanding_${BASE}"
rm -rf "$OUT"; mkdir -p "$OUT"
cat > "$OUT/panicoverride.nim" <<'EOF'
proc rawoutput(msg: string) {.nimcall.} =
  discard
proc panic*(s: string) {.exportc, noreturn.} =
  while true:
    discard
EOF

BOARDS="$ROOT/testing_experiment/boards"
PICOLIBC="$ROOT/testing_experiment/build/picolibc/install"
arm-none-eabi-gcc -c -mcpu=cortex-m3 -mthumb "$BOARDS/startup_lm3s6965evb.c" -o "$OUT/startup.o" 2>&1
arm-none-eabi-gcc -c -mcpu=cortex-m3 -mthumb "$BOARDS/stubs.c" -o "$OUT/stubs.o" 2>&1
arm-none-eabi-as  -mcpu=cortex-m3 -mthumb "$BOARDS/semihost.s" -o "$OUT/semihost.o" 2>&1

echo "=== tuck check ==="
./tuck ch "$SRC" 2>&1 | tail -3

NIMFLAGS="--os:standalone --cpu:arm --mm:none -d:freestanding --exceptions:goto --cc:gcc --gcc.exe:arm-none-eabi-gcc --gcc.linkerexe:arm-none-eabi-gcc --threads:off --tlsEmulation:off --passC:-mthumb --passC:-mcpu=cortex-m3 --passC:-g --passC:-I$PICOLIBC/include --passL:-nostartfiles --passL:$OUT/startup.o --passL:$OUT/stubs.o --passL:$OUT/semihost.o --passL:$PICOLIBC/lib/libc.a --passL:-T$BOARDS/lm3s6965evb.ld"
if [ "${TUCK_FAULT_ISR_DROP:-}" = "1" ]; then
  NIMFLAGS="$NIMFLAGS -d:TuckFaultIsrDrop"
fi

echo "=== freestanding build ==="
./tuck b "$SRC" \
  --nim:"$NIMFLAGS" \
  -o:"$OUT" 2>&1 | tail -20

ELF="$OUT/${BASE}"
if [ ! -f "$ELF" ]; then
  echo "!!! no ELF produced"
  exit 1
fi
echo "=== qemu run (10s) ==="
QEMU_EXTRA=""
if [ "${TUCK_VIRTUAL_TIME:-}" = "1" ]; then
  QEMU_EXTRA="-icount shift=auto,sleep=off"
fi
timeout 10 qemu-system-arm -M lm3s6965evb \
  $QEMU_EXTRA \
  -semihosting-config enable=on,target=native \
  -nographic -kernel "$ELF" 2>&1 | head -40
echo "qemu exit: ${PIPESTATUS[0]}   (124 = clean run into idle loop)"
