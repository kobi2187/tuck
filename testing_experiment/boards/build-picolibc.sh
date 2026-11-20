#!/bin/sh
# Build vendored picolibc for Tuck freestanding ARM Cortex-M3 (Thumb).
# Output: testing_experiment/build/picolibc/install (include, lib/libc.a)
# Requires meson + ninja.
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PICOLIBC_SRC="$ROOT/testing_experiment/vendor/picolibc"
OUT=${PICOLIBC_OUT:-$ROOT/testing_experiment/build/picolibc}
CROSS="$ROOT/testing_experiment/boards/picolibc-cortex-m3.cross"
MESON=${MESON:-meson}
if ! $MESON --version >/dev/null 2>&1; then
  echo "picolibc_build: meson not found" >&2; exit 1
fi
if [ ! -f "$PICOLIBC_SRC/meson.build" ]; then
  echo "picolibc_build: vendor/picolibc missing (run fetch)" >&2; exit 1
fi
rm -rf "$OUT"; mkdir -p "$(dirname "$OUT")"
$MESON setup "$OUT/build" "$PICOLIBC_SRC" \
  --cross-file "$CROSS" --prefix "$OUT/install" \
  -Dmultilib=false -Dtests=false -Dpicocrt=false -Dsemihost=false \
  -Dthread-local-storage=false -Dsingle-thread=true -Dnewlib-global-errno=true \
  -Dwant-math-errno=false -Dposix-console=false -Dspecsdir=none -Dlibdl=false \
  >"$OUT.setup.log" 2>&1 || { echo "--- setup failed ---"; tail -30 "$OUT.setup.log"; exit 1; }
$MESON install -C "$OUT/build" >"$OUT.install.log" 2>&1 || { echo "--- install failed ---"; tail -30 "$OUT.install.log"; exit 1; }
echo "picolibc built -> $OUT/install"
ls "$OUT/install/lib/libc.a" && arm-none-eabi-objdump -d "$OUT/install/lib/libc.a" 2>/dev/null | grep -A1 '<memset>:' | head -3