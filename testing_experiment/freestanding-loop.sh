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
export PATH=/root/toolchains/nim/bin:/root/toolchains/odin:/root/toolchains/ldc2/bin:/root/toolchains/dmd2/linux/bin64:$PATH
export TUCK_CC=gcc   # keep gcc so we can point --gcc.exe at arm-none-eabi-gcc

echo "=== build tuck ==="
nim c --hints:off -o:tuck tuck.nim 2>&1 | tail -2 || exit 1

OUT="/tmp/scratchpad/freestanding_${STAGE}"
rm -rf "$OUT"; mkdir -p "$OUT"
cat > "$OUT/panicoverride.nim" <<'EOF'
proc rawoutput(msg: string) {.nimcall.} =
  discard
proc panic*(s: string) {.exportc, noreturn.} =
  while true:
    discard
EOF

BOARDS="$ROOT/testing_experiment/boards"
arm-none-eabi-gcc -c -mcpu=cortex-m3 -mthumb "$BOARDS/startup_lm3s6965evb.c" -o "$OUT/startup.o" 2>&1
arm-none-eabi-gcc -c -mcpu=cortex-m3 -mthumb "$BOARDS/stubs.c" -o "$OUT/stubs.o" 2>&1
arm-none-eabi-as  -mcpu=cortex-m3 -mthumb "$BOARDS/semihost.s" -o "$OUT/semihost.o" 2>&1

echo "=== tuck check ==="
./tuck ch "testing_experiment/${STAGE}.tuck" 2>&1 | tail -3

echo "=== freestanding build ==="
./tuck b "testing_experiment/${STAGE}.tuck" \
  --nim:"--os:standalone --cpu:arm --mm:none -d:freestanding --exceptions:goto --cc:gcc --gcc.exe:arm-none-eabi-gcc --gcc.linkerexe:arm-none-eabi-gcc --threads:off --tlsEmulation:off --passC:-mthumb --passC:-mcpu=cortex-m3 --passL:-nostartfiles --passL:$OUT/startup.o --passL:$OUT/stubs.o --passL:$OUT/semihost.o --passL:-T$BOARDS/lm3s6965evb.ld" \
  -o:"$OUT" 2>&1 | tail -20

ELF="$OUT/${STAGE}"
if [ ! -f "$ELF" ]; then
  echo "!!! no ELF produced"
  exit 1
fi
echo "=== qemu run (10s) ==="
timeout 10 qemu-system-arm -M lm3s6965evb \
  -semihosting-config enable=on,target=native \
  -nographic -kernel "$ELF" 2>&1 | head -40
echo "qemu exit: ${PIPESTATUS[0]}   (124 = clean run into idle loop)"
