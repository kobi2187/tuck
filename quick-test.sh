#!/bin/bash
# The INNER-LOOP gate: does the tree still build and typecheck?
#
# Every script here drives `tuck ch` / `tuck c` only — no `tuck build`, so no
# Nim compile-and-link, which is what makes run-all-tests.sh a 40s wait. That
# suite is the pre-commit gate; this one is what you run after every edit.
#
# What it does NOT cover: anything asserting a program's exit code or its
# runtime output, and the Odin `odin build` layer. Run ./run-all-tests.sh
# before committing.
set -u
cd "$(dirname "$0")"

t0=$(date +%s.%N)
echo "== nim builds tuck =="
nim c --hints:off --warnings:off -o:tuck tuck.nim || { echo "FAIL: cannot build tuck"; exit 1; }

# Check-only scripts: no `runs`, no `odin build`. Ordered longest-first so the
# critical path starts immediately.
quick="typecheck.sh frontend.sh examples.sh pointer_containment.sh
interfaces.sh interface_wrap.sh interface_call.sh actor_result.sh
bare_variant.sh member_names.sh mangle.sh complexity.sh duplicates.sh
fuzz_corpus.sh"

logdir=$(mktemp -d)
trap 'rm -rf "$logdir"' EXIT
export TEST_JOBS=2

failures=0
printf '%s\n' $quick | xargs -P "$(nproc)" -I{} sh -c '
  b="$1"; [ -f "tests/$b" ] || exit 0
  bash "tests/$b" > "'"$logdir"'/$b.out" 2>&1
  echo $? > "'"$logdir"'/$b.rc"' _ {}

for b in $quick; do
  [ -f "$logdir/$b.rc" ] || continue
  grep -E "passed, [0-9]+ failed" "$logdir/$b.out" | sed "s/^/  /"
  if [ "$(cat "$logdir/$b.rc")" -ne 0 ]; then
    echo "FAIL: tests/$b"
    sed 's/^/     /' "$logdir/$b.out"
    failures=$((failures + 1))
  fi
done

printf '\n  %ss total\n' "$(echo "scale=1; ($(date +%s.%N) - $t0)/1" | bc)"
if [ $failures -gt 0 ]; then echo "$failures failure(s)."; exit 1; fi
echo "Quick gate passed. Run ./run-all-tests.sh before committing."
