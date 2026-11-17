#!/bin/bash
# tools/corpus_check.sh OLD_TUCK NEW_TUCK
#
# Runs `tuck ch` over the whole corpus with two compilers and prints every file
# whose verdict differs — the check to run after any checker change. Each file
# is checked the way it is meant to be built: examples/ and std/ against the
# blessed std/, stdlib-project/ and benches/ against the project stdlib
# (`--stdlib:stdlib-project --root:`). Without those flags the project files
# fail identically under both compilers and a new refusal there goes unseen.
#
# Build OLD from the commit to compare against, e.g.
#   git worktree add /tmp/wt_base <commit> && (cd /tmp/wt_base && nim c -o:tuck tuck.nim)
#   tools/corpus_check.sh /tmp/wt_base/tuck ./tuck
set -u
OLD=$(realpath "$1"); NEW=$(realpath "$2")
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OLDROOT=$(dirname "$OLD")
cd "$ROOT"
one() {
  local f=$1; shift
  local a b
  a=$("$OLD" ch "$f" "$@" 2>&1 | tail -1 | sed "s#$OLDROOT#$ROOT#g; s/ ([0-9.]* ms)//")
  b=$("$NEW" ch "$f" "$@" 2>&1 | tail -1 | sed 's/ ([0-9.]* ms)//')
  [ "$a" != "$b" ] && echo "$f: OLD[$a] NEW[$b]"
}
for f in examples/*.tuck $(find std -name '*.tuck'); do one "$f"; done
for f in $(find stdlib-project benches -name '*.tuck' -not -path '*/.tuck-cache/*'); do
  one "$f" --stdlib:stdlib-project --root:"$ROOT"
done
exit 0
