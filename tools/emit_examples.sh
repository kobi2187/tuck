#!/bin/bash
# Re-emit every example's Nim and Odin, in place, next to its .tuck source.
#
# The emitted code is TRACKED (see .gitignore). This script is how you refresh
# it: run it after any codegen change, then read `git diff examples/` — that
# diff IS the review. A change you did not intend shows up there as plainly as
# one you did.
#
# It deliberately does NOT check exit status per example: some examples are
# known not to compile (tests/suites/examples.nim holds the gated list, and the
# ungated ones are tracked in MISSING-FEATURES). Their output simply does not
# refresh, which is the honest result rather than a failure.
set -u
cd "$(dirname "$0")/.."

[ -x ./tuck ] || nim c --hints:off --warnings:off -o:tuck tuck.nim

# Stale output for a since-deleted example would otherwise linger forever.
rm -f examples/*.nim examples/*.odin

emitted=0
for f in examples/*.tuck; do
  if ./tuck c "$f" --odin --root:"$(pwd)" > /dev/null 2>&1; then
    emitted=$((emitted + 1))
  else
    printf '  did not emit: %s\n' "$(basename "$f")"
  fi
done

printf 'emitted %s of %s examples -> %s .nim, %s .odin\n' \
  "$emitted" "$(ls examples/*.tuck | wc -l)" \
  "$(ls examples/*.nim 2>/dev/null | wc -l)" \
  "$(ls examples/*.odin 2>/dev/null | wc -l)"
