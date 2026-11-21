#!/usr/bin/env bash
# Rebuild svd2tuck and regenerate both committed modules.
set -euo pipefail
cd "$(dirname "$0")"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "=== build svd2tuck ==="
nim c --hints:off --warnings:off -o:"$TMP/svd2tuck" src/svd2tuck.nim
echo "=== whole device ==="
"$TMP/svd2tuck" svd/STM32F103.svd --out generated 2>/dev/null
echo "=== blue pill overlay ==="
"$TMP/svd2tuck" svd/STM32F103.svd --overlay bluepill.json \
  --module stm32f103_bluepill --out generated 2>/dev/null
echo "=== check generated modules ==="
ROOT="$(cd ../../.. && pwd)"
"$ROOT/tuck" ch generated/stm32f103.tuck --root:"$ROOT"
"$ROOT/tuck" ch generated/stm32f103_bluepill.tuck --root:"$ROOT"
