#!/bin/sh
# Build picolibc for Tuck's bare-metal Cortex-M3 builds (Thumb, soft-float).
#
# Output: build/picolibc/install (include/, lib/libc.a), which
# tools/metal/qemu-run.sh links. Needs meson, ninja and arm-none-eabi-gcc.
#
# Source: the official picolibc 1.8.12 release, pinned by SHA-256 and cached
# under build/. It used to be vendored (4,193 files in the repo); the release
# tarball is byte-identical to that tree. Offline, point PICOLIBC_TARBALL at
# a local copy of the same file.
#
# Why picolibc: newlib as shipped with arm-none-eabi-gcc has an ARM-state
# memset, and Cortex-M is Thumb-only, so Nim's zeroMem faulted on the first
# call. picolibc's is Thumb.
set -e
VERSION=1.8.12
SHA256=64e8c412e1c40fa6eb1a72d2b5cdbcbfe6ceca4cbea454edbad54557ffc747fa
URL="https://github.com/picolibc/picolibc/releases/download/$VERSION/picolibc-$VERSION.tar.xz"

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CACHE="$ROOT/build"
TARBALL=${PICOLIBC_TARBALL:-$CACHE/picolibc-$VERSION.tar.xz}
SRC="$CACHE/picolibc-$VERSION"
OUT=${PICOLIBC_OUT:-$CACHE/picolibc}
CROSS="$ROOT/boards/picolibc/cortex-m3.cross"
MESON=${MESON:-meson}

if ! $MESON --version >/dev/null 2>&1; then
  echo "picolibc build: meson not found (apt install meson ninja-build)" >&2; exit 1
fi
mkdir -p "$CACHE"
if [ ! -f "$TARBALL" ]; then
  echo "picolibc build: fetching $URL"
  curl -sSfL -o "$TARBALL.part" "$URL"
  mv "$TARBALL.part" "$TARBALL"
fi
echo "$SHA256  $TARBALL" | sha256sum -c --quiet - || {
  echo "picolibc build: $TARBALL does not match the pinned SHA-256" >&2; exit 1; }
if [ ! -f "$SRC/meson.build" ]; then
  tar -xJf "$TARBALL" -C "$CACHE"
fi

rm -rf "$OUT"; mkdir -p "$OUT"
$MESON setup "$OUT/build" "$SRC" \
  --cross-file "$CROSS" --prefix "$OUT/install" \
  -Dmultilib=false -Dtests=false -Dpicocrt=false -Dsemihost=false \
  -Dthread-local-storage=false -Dsingle-thread=true -Dnewlib-global-errno=true \
  -Dwant-math-errno=false -Dposix-console=false -Dspecsdir=none -Dlibdl=false \
  >"$OUT.setup.log" 2>&1 || { echo "--- setup failed ---"; tail -30 "$OUT.setup.log"; exit 1; }
$MESON install -C "$OUT/build" >"$OUT.install.log" 2>&1 || { echo "--- install failed ---"; tail -30 "$OUT.install.log"; exit 1; }
echo "picolibc built -> $OUT/install"
# The reason it exists: memset must be Thumb code, not an ARM-state prologue.
arm-none-eabi-objdump -d "$OUT/install/lib/libc.a" 2>/dev/null | grep -A1 '<memset>:' | head -3
