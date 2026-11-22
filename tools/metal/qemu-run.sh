#!/usr/bin/env bash
# Build a Tuck program for a bare-metal Cortex-M board and boot it under QEMU.
# Usage: tools/metal/qemu-run.sh [program]        (what `tuck sim` runs)
#   Builds tuck, compiles the program freestanding (ARM/Thumb, no OS), links
#   it with boards/ startup + linker script + picolibc, and boots it under
#   qemu-system-arm. The exit status is the program's: main's return value
#   through semihosting, 1 after a fault, 124 when it was still running when
#   the window closed.
# A program is a name under tests/metal/ (task_await) or a .tuck path.
# Needs qemu-system-arm, arm-none-eabi-gcc and picolibc (boards/picolibc/build.sh).
set -u
STAGE="${1:-boot_led}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
# Accept either a stage name (boot_led) or a file path (foo/bar.tuck).
if [[ "$STAGE" == *.tuck || "$STAGE" == */* ]]; then
  SRC="$STAGE"
  BASE="$(basename "$STAGE" .tuck)"
else
  BASE="$STAGE"
  SRC="tests/metal/${BASE}.tuck"
fi
export TUCK_CC=gcc   # keep gcc so we can point --gcc.exe at arm-none-eabi-gcc
# Extra flags for `tuck ch/b`, e.g. an SVD-generated module used as the stdlib:
#   TUCK_STDLIB=tools/svd2tuck/generated ./qemu-run.sh boot_led_svd
TUCK_FLAGS=""
if [ -n "${TUCK_STDLIB:-}" ]; then
  TUCK_FLAGS="--stdlib:$TUCK_STDLIB"
fi

# Board: a directory under boards/ with board.ld (memory map, _estack) and
# board.conf (machine, CPU, console). Add a board by adding a directory.
BOARD="${TUCK_BOARD:-lm3s6965evb}"
BOARD_DIR="$ROOT/boards/$BOARD"
if [ ! -f "$BOARD_DIR/board.conf" ]; then
  echo "!!! unknown board '$BOARD': no boards/$BOARD/board.conf (have: $(ls -d "$ROOT"/boards/*/board.conf 2>/dev/null | xargs -n1 dirname | xargs -n1 basename | tr '\n' ' '))"
  exit 1
fi
conf() { sed -n "s/^$1[[:space:]]*=[[:space:]]*//p" "$BOARD_DIR/board.conf" | head -1; }
MACHINE="$(conf qemu)"
CPU="$(conf cpu)"
CONSOLE="$(conf console)"

if [ "${TUCK_SKIP_TUCK_BUILD:-}" = "1" ]; then
  echo "=== build tuck (skipped: TUCK_SKIP_TUCK_BUILD=1) ==="
else
  echo "=== build tuck ==="
  nim c --hints:off -o:tuck tuck.nim 2>&1 | tail -2 || exit 1
fi

# A distinct scratch dir per concurrent caller (the test pool runs scenarios
# in parallel). Default keeps the historical path for human invocations.
OUT="${TUCK_OUT_DIR:-${TMPDIR:-/tmp}/tuck-metal/qemu_${BASE}}"
rm -rf "$OUT"; mkdir -p "$OUT"
# Nim's standalone runtime routes every failed check (bounds, nil, a failed
# assert) through `panic`. It goes to the board's tuck_fatal, which prints
# `PANIC: msg` and traps, so the fault recorder reports it. It used to loop
# silently, which a QEMU run read as a clean finish.
cat > "$OUT/panicoverride.nim" <<'EOF'
proc tuckSemihostWrite(s: cstring) {.importc: "tuck_board_puts".}
proc tuckFatal(msg: cstring) {.importc: "tuck_fatal", noreturn.}
proc rawoutput(msg: string) {.nimcall.} =
  tuckSemihostWrite(msg.cstring)
proc panic*(s: string) {.noreturn.} =
  tuckFatal(s.cstring)
EOF

BOARDS="$ROOT/boards"
PICOLIBC="$ROOT/build/picolibc/install"
if [ ! -f "$PICOLIBC/lib/libc.a" ]; then
  echo "!!! picolibc is not built: run boards/picolibc/build.sh once"
  exit 1
fi
arm-none-eabi-gcc -c -mcpu=$CPU -mthumb "$BOARDS/common/startup_cortex_m.c" -o "$OUT/startup.o" 2>&1
arm-none-eabi-gcc -c -mcpu=$CPU -mthumb "$BOARDS/common/stubs.c" -o "$OUT/stubs.o" 2>&1
arm-none-eabi-gcc -c -mcpu=$CPU -mthumb "$BOARDS/common/$CONSOLE.c" -o "$OUT/console.o" 2>&1
arm-none-eabi-as  -mcpu=$CPU -mthumb "$BOARDS/common/aeabi_read_tp.s" -o "$OUT/tp.o" 2>&1

echo "=== tuck check ==="
./tuck ch "$SRC" $TUCK_FLAGS 2>&1 | tail -3

NIMFLAGS="--os:standalone --cpu:arm --mm:none -d:freestanding --exceptions:goto --cc:gcc --gcc.exe:arm-none-eabi-gcc --gcc.linkerexe:arm-none-eabi-gcc --threads:off --tlsEmulation:off --passC:-mthumb --passC:-mcpu=$CPU --passC:-g --passC:-I$PICOLIBC/include --passL:-nostartfiles --passL:$OUT/startup.o --passL:$OUT/stubs.o --passL:$OUT/console.o --passL:$OUT/tp.o --passL:$PICOLIBC/lib/libc.a --passL:-T$BOARD_DIR/board.ld"
if [ "${TUCK_FAULT_ISR_DROP:-}" = "1" ]; then
  NIMFLAGS="$NIMFLAGS -d:TuckFaultIsrDrop"
fi

echo "=== freestanding build ==="
# The metal profile is stackless whatever TUCK_CONCURRENCY says: a stackful
# task needs an mmap'd stack, and bare metal has no mmap (POL-5).
./tuck b "$SRC" \
  $TUCK_FLAGS \
  --concurrency:stackless \
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
timeout 10 qemu-system-arm -M "$MACHINE" \
  $QEMU_EXTRA \
  -semihosting-config enable=on,target=native \
  -nographic -kernel "$ELF" 2>&1 | head -40
QEMU_RC=${PIPESTATUS[0]}
# The board exits QEMU through semihosting with main's return value (0 = the
# program returned 0). A fault exits 1 after printing its FAULT line. 124 is
# `timeout`: still running after the window — never a pass for a test.
echo "qemu exit: $QEMU_RC   (main's return value; 124 = timeout, still running)"
exit $QEMU_RC
