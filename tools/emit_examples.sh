#!/bin/bash
# Re-emit every example's Nim, Odin and D, in place, next to its .tuck source.
#
# In place is the DEFAULT mode's output (--concurrency:stackless, #216).
# examples/stackful/ holds the stackful output of every file where the two
# differ (a task, a frame fn, a frame actor) and nothing else: a file the
# modes emit alike is not kept twice.
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
rm -f examples/stackful/*.nim examples/stackful/*.odin examples/stackful/*.d

# One invocation now emits exactly one target — --odin/--dlang no longer ride
# alongside a free Nim emission — so refreshing all three tracked corpora
# needs three calls per example instead of one.
emitted_nim=0
emitted_odin=0
emitted_d=0
for f in examples/*.tuck; do
  if ./tuck c "$f" --concurrency:stackless --root:"$(pwd)" > /dev/null 2>&1; then
    emitted_nim=$((emitted_nim + 1))
  else
    printf '  did not emit (nim): %s\n' "$(basename "$f")"
  fi
  if ./tuck c "$f" --odin --concurrency:stackless --root:"$(pwd)" > /dev/null 2>&1; then
    emitted_odin=$((emitted_odin + 1))
  else
    printf '  did not emit (odin): %s\n' "$(basename "$f")"
  fi
  if ./tuck c "$f" --dlang --concurrency:stackless --root:"$(pwd)" > /dev/null 2>&1; then
    emitted_d=$((emitted_d + 1))
  else
    printf '  did not emit (d): %s\n' "$(basename "$f")"
  fi
done

# The stackful twin of each example's own file, kept only where it differs
# from the default. Both modes are emitted into scratch dirs at the SAME
# depth first, so relative import paths cannot make a false difference.
mkdir -p examples/stackful
kept=0
for f in examples/*.tuck; do
  stem=$(basename "$f" .tuck)
  for flag in "" --odin --dlang; do
    case "$flag" in --odin) ext=odin;; --dlang) ext=d;; *) ext=nim;; esac
    rm -rf examples/.cmp-a examples/.cmp-b
    ./tuck c "$f" $flag --concurrency:stackless -o:examples/.cmp-a --root:"$(pwd)" > /dev/null 2>&1 || continue
    ./tuck c "$f" $flag --concurrency:stackful -o:examples/.cmp-b --root:"$(pwd)" > /dev/null 2>&1 || continue
    if ! cmp -s "examples/.cmp-a/$stem.$ext" "examples/.cmp-b/$stem.$ext"; then
      ./tuck c "$f" $flag --concurrency:stackful -o:examples/stackful --root:"$(pwd)" > /dev/null 2>&1
      kept=$((kept + 1))
    fi
  done
done
rm -rf examples/.cmp-a examples/.cmp-b
# Only each example's own file is a twin; what the emit dragged along (module
# files, runtime copies, shims) is not.
for g in examples/stackful/* examples/stackful/.[!.]*; do
  [ -e "$g" ] || continue
  name=$(basename "$g")
  stem=${name%.*}
  if [ -d "$g" ] || [ ! -e "examples/$stem.tuck" ]; then rm -rf "$g"; fi
done

printf 'emitted %s .nim, %s .odin, %s .d of %s examples; %s stackful twins differ\n' \
  "$emitted_nim" "$emitted_odin" "$emitted_d" "$(ls examples/*.tuck | wc -l)" "$kept"
