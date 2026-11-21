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
# Extra flags for `tuck ch/b`, e.g. an SVD-generated module used as the stdlib:
#   TUCK_STDLIB=testing_experiment/tools/svd2tuck/generated ./freestanding-loop.sh bare_metal_led_svd
TUCK_FLAGS=""
if [ -n "${TUCK_STDLIB:-}" ]; then
  TUCK_FLAGS="--stdlib:$TUCK_STDLIB"
fi

# Board profile: machine, CPU, linker script, and initial stack pointer.
# Add a board by adding one arm here and a linker script under boards/.
BOARD="${TUCK_BOARD:-lm3s6965evb}"
case "$BOARD" in
  lm3s6965evb)
    CPU=cortex-m3
    LD=lm3s6965evb.ld
    INITIAL_SP=0x20010000
    ;;
  stm32vldiscovery)
    CPU=cortex-m3
    LD=stm32vldiscovery.ld
    INITIAL_SP=0x20002000
    ;;
  *)
    echo "!!! unknown board '$BOARD' (lm3s6965evb, stm32vldiscovery)"
    exit 1
    ;;
esac

if [ "${TUCK_SKIP_TUCK_BUILD:-}" = "1" ]; then
  echo "=== build tuck (skipped: TUCK_SKIP_TUCK_BUILD=1) ==="
else
  echo "=== build tuck ==="
  nim c --hints:off -o:tuck tuck.nim 2>&1 | tail -2 || exit 1
fi

# A distinct scratch dir per concurrent caller (the test pool runs scenarios
# in parallel). Default keeps the historical path for human invocations.
OUT="${TUCK_OUT_DIR:-/tmp/scratchpad/freestanding_${BASE}}"
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
arm-none-eabi-gcc -c -mcpu=$CPU -mthumb -DTUCK_INITIAL_SP=$INITIAL_SP "$BOARDS/startup_lm3s6965evb.c" -o "$OUT/startup.o" 2>&1
arm-none-eabi-gcc -c -mcpu=$CPU -mthumb "$BOARDS/stubs.c" -o "$OUT/stubs.o" 2>&1
arm-none-eabi-as  -mcpu=$CPU -mthumb "$BOARDS/semihost.s" -o "$OUT/semihost.o" 2>&1

echo "=== tuck check ==="
./tuck ch "$SRC" $TUCK_FLAGS 2>&1 | tail -3

NIMFLAGS="--os:standalone --cpu:arm --mm:none -d:freestanding --exceptions:goto --cc:gcc --gcc.exe:arm-none-eabi-gcc --gcc.linkerexe:arm-none-eabi-gcc --threads:off --tlsEmulation:off --passC:-mthumb --passC:-mcpu=$CPU --passC:-g --passC:-I$PICOLIBC/include --passL:-nostartfiles --passL:$OUT/startup.o --passL:$OUT/stubs.o --passL:$OUT/semihost.o --passL:$PICOLIBC/lib/libc.a --passL:-T$BOARDS/$LD"
if [ "${TUCK_FAULT_ISR_DROP:-}" = "1" ]; then
  NIMFLAGS="$NIMFLAGS -d:TuckFaultIsrDrop"
fi

echo "=== freestanding build ==="
./tuck b "$SRC" \
  $TUCK_FLAGS \
  --debug-lines \
  --nim:"$NIMFLAGS" \
  -o:"$OUT" 2>&1 | tail -20

ELF="$OUT/${BASE}"
if [ ! -f "$ELF" ]; then
  echo "!!! no ELF produced"
  exit 1
fi
# Machine-readable handle for `tuck decode-crash --log:FILE`: one captured
# log then carries both the fault record and the ELF it refers to.
echo "ELF=$ELF"
# QEMU tick length. `-icount shift=N` makes virtual time advance 2^N ns per
# translated instruction; N=0 is the finest (1 ns), N=10 the fastest.
# `--time:fast` uses 10; `--tick:N` overrides it. Without either, QEMU runs
# in real time and these options are absent.
QEMU_EXTRA=""
if [ -n "${TUCK_ICOUNT_SHIFT:-}" ]; then
  case "$TUCK_ICOUNT_SHIFT" in
    0|1|2|3|4|5|6|7|8|9|10)
      QEMU_EXTRA="-icount shift=$TUCK_ICOUNT_SHIFT,sleep=off"
      ;;
    *)
      echo "!!! TUCK_ICOUNT_SHIFT must be 0..10, got '$TUCK_ICOUNT_SHIFT'"
      exit 1
      ;;
  esac
elif [ "${TUCK_VIRTUAL_TIME:-}" = "1" ]; then
  QEMU_EXTRA="-icount shift=auto,sleep=off"
fi

echo "=== qemu run (10s, board=$BOARD, ${QEMU_EXTRA:-realtime}) ==="
timeout 10 qemu-system-arm -M "$BOARD" \
  $QEMU_EXTRA \
  -semihosting-config enable=on,target=native \
  -nographic -kernel "$ELF" 2>&1 | head -40
echo "qemu exit: ${PIPESTATUS[0]}   (124 = clean run into idle loop)"
