#!/bin/bash
# Cyclomatic complexity RATCHET over the compiler sources.
#
# The project's refactoring rule has two triggers: a proc is 5-8 lines (hard
# cap ~10), and complexity over 5 splits unconditionally. Length is easy to
# eyeball; complexity is not — genOdinCall sat at cc=32 in 47 lines and read
# as "already refactored" because its LENGTH had come down while its chain of
# `calleeStr == "..."` tests had not.
#
# So this gate exists to make the second trigger visible. It is a RATCHET, not
# a target: both numbers are set to whatever the tree currently is, so the
# tree cannot get worse, and they are lowered by hand as procs are split. They
# are never raised to accommodate new code — a new proc over the ceiling is
# the failure this catches.
#
#   CEILING — no proc may exceed this complexity.
#   BUDGET  — how many procs may sit above the threshold of 5.
#
# The script prints "tighten --budget to N" whenever the real count has
# dropped below the budget, so the ratchet reports its own slack instead of
# quietly drifting.
#
# There is no Nim tool for this. nimpretty only formats, nimfmt lints style,
# `nim check` has no complexity warning, and lizard/scc cannot parse Nim.
set -u
cd "$(dirname "$0")/.."

CEILING=27
BUDGET=196

echo "== cyclomatic complexity ratchet (ceiling $CEILING, budget $BUDGET) =="

# The verdict is python's exit status, not tail's — hence PIPESTATUS. Only the
# summary lines are shown; the full ranked table is `tools/complexity.py` on
# its own.
python3 tools/complexity.py --gate "$CEILING" --budget "$BUDGET" \
  compiler/*.nim lexer.nim tuck.nim | grep -vE '^  cc=' | tail -20
rc=${PIPESTATUS[0]}

if [ "$rc" -eq 0 ]; then
  echo "complexity.sh: passed, 0 failed"
  exit 0
fi
echo "complexity.sh: 1 failed"
echo "  A proc got more complex, or a new one landed over the ceiling."
echo "  Split it — do not raise CEILING/BUDGET in this file."
exit 1
