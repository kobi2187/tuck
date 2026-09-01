#!/bin/bash
# Re-emit every example's Nim, Odin and D, in place, next to its .tuck source.
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
# tuck_coro.d/tuck_rt.d/minicoro.a are D's copied runtime, not per-example
# output (gitignored, same reason as Odin's examples/tuckrt/) — deleted and
# regenerated here anyway so a stale copy never lingers between runs.
rm -f examples/*.nim examples/*.odin examples/*.d examples/minicoro.a

# One invocation now emits exactly one target — --odin/--dlang no longer ride
# alongside a free Nim emission — so refreshing all three tracked corpora
# needs three calls per example instead of one.
emitted_nim=0
emitted_odin=0
emitted_d=0
for f in examples/*.tuck; do
  if ./tuck c "$f" --root:"$(pwd)" > /dev/null 2>&1; then
    emitted_nim=$((emitted_nim + 1))
  else
    printf '  did not emit (nim): %s\n' "$(basename "$f")"
  fi
  if ./tuck c "$f" --odin --root:"$(pwd)" > /dev/null 2>&1; then
    emitted_odin=$((emitted_odin + 1))
  else
    printf '  did not emit (odin): %s\n' "$(basename "$f")"
  fi
  if ./tuck c "$f" --dlang --root:"$(pwd)" > /dev/null 2>&1; then
    emitted_d=$((emitted_d + 1))
  else
    printf '  did not emit (d): %s\n' "$(basename "$f")"
  fi
done

printf 'emitted %s .nim, %s .odin, %s .d of %s examples\n' \
  "$emitted_nim" "$emitted_odin" "$emitted_d" "$(ls examples/*.tuck | wc -l)"
