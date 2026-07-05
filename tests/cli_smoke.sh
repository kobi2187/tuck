#!/bin/bash
# Smoke test for the tuck CLI: builds it, runs every command, checks fail-fast.
set -e
cd "$(dirname "$0")/.."

nim c --hints:off --warnings:off -o:tuck tuck.nim

./tuck l  examples/07-comments.tuck  > /dev/null
./tuck p  examples/07-comments.tuck  > /dev/null
./tuck ch examples/01-data-flow.tuck > /dev/null
out=$(mktemp -d)
./tuck c  examples/07-comments.tuck -o:"$out" > /dev/null
test -f "$out/07-comments.nim"

# fail-fast: type error must exit nonzero with file:line:col
bad="$out/bad.tuck"
printf 'fn f({a: int}) -> int:\n  return "nope"\n' > "$bad"
if ./tuck ch "$bad" 2>/dev/null; then
  echo "FAIL: expected nonzero exit on type error"; exit 1
fi
./tuck ch "$bad" 2>&1 | grep -q "bad.tuck:2:" || { echo "FAIL: no file:line:col prefix"; exit 1; }

rm -rf "$out"
echo "cli smoke OK"
