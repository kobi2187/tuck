#!/bin/bash
# The escape solver (compiler/escape.nim).
#
# A thin wrapper so the suite's tests/*.sh glob picks it up. The real tests are
# in tests/escape_solver.nim and call the module DIRECTLY, because it has no
# compiler dependencies — it is a lattice solver over opaque integers, so there
# is no .tuck source that would exercise it, and calling it directly is what
# allows the randomised graphs.
#
# Every other test here drives the ./tuck binary, which is right for checking
# the compiler's behaviour. This is the exception, and deliberately the only
# one: a pure algorithm whose correctness is asymmetric — a wrong "escapes"
# wastes a promotion, a wrong "does not escape" is a dangling pointer.
cd "$(dirname "$0")/.."

out=$(nim c --hints:off --warnings:off -r tests/escape_solver.nim 2>&1)
rc=$?
if [ $rc -ne 0 ] || echo "$out" | grep -q "^FAIL"; then
  echo "$out" | grep -E "^FAIL|Error" | head -10
  n=$(echo "$out" | grep -c "^FAIL")
  echo "escape.sh: $(echo "$out" | grep -c '^PASS') passed, ${n:-1} failed"
  exit 1
fi
echo "escape.sh: $(echo "$out" | grep -c '^PASS') passed, 0 failed"
