#!/bin/bash
# Runs every tests/*.nim script plus tests/cli_smoke.sh and reports a single
# pass/fail gate. Each *.nim test is its own standalone program (no unittest
# lib) — see tests/known_bugs.nim's header for why. This script only compiles
# + runs them and checks exit codes / known text markers; it adds no new test
# convention.
set -u
cd "$(dirname "$0")"

failures=0

# tests/odin_backend.nim checks emitted Odin that it does not itself produce —
# it expects examples/*.odin to already be on disk and reports "missing emitted
# Odin" for every one that is not. Those are build artifacts (not committed),
# so generate them here or the whole Odin layer reports phantom failures.
echo "== prep: emit examples/*.odin =="
nim c --hints:off --warnings:off -o:tuck tuck.nim || { echo "FAIL: cannot build tuck"; exit 1; }
for t in examples/*.tuck; do
  ./tuck build "$t" --odin > /dev/null 2>&1 || echo "  (no odin for $t)"
done

# tests/temp_out.nim is generated output from end_to_end.nim, not a test.
test_files=$(ls tests/*.nim | grep -v temp_out.nim)

for f in $test_files; do
  echo "== $f =="
  out=$(nim c --hints:off --warnings:off -r "$f" 2>&1)
  status=$?
  echo "$out" | tail -5
  if [ $status -ne 0 ]; then
    echo "FAIL: $f exited $status"
    failures=$((failures + 1))
  fi
  # end_to_end.nim never calls quit(1); it only signals via this text.
  if echo "$out" | grep -q "^FAILED:"; then
    echo "FAIL: $f printed FAILED"
    failures=$((failures + 1))
  fi
done

echo "== tests/cli_smoke.sh =="
if ! bash tests/cli_smoke.sh; then
  echo "FAIL: cli_smoke.sh"
  failures=$((failures + 1))
fi

echo ""
if [ $failures -gt 0 ]; then
  echo "$failures failure(s)."
  exit 1
fi
echo "All tests passed."
