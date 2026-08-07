#!/bin/bash
# What does each of `compatible`'s escape hatches actually cost?
#
# The checker is lenient in three separate places, and "too lenient" is not
# actionable until each one has a number. This builds a compiler per hatch,
# with that hatch closed and the others left open, and counts how many of the
# examples stop checking.
#
#   strictUnknown — an Unknown on either side matches anything
#   strictNumeric — any numeric widens to any other numeric
#   strictKind    — two types of the same KIND match, whatever they are
#
# A fourth, `strictAny` (void / unit / Self / fn match anything), is GONE: the
# hatch it measured was closed rather than flagged. Each name was removed once
# its cost had been measured at zero — see the note above `compatible` in
# compiler/typecheck.nim. No type matches anything now.
#
# A high count is not automatically bad: some leniency is deliberate (a
# pending fn's callers must keep compiling). The point is to know which
# examples each one is holding up, so they can be fixed one hatch at a time
# rather than all at once.
#
# Usage: tools/leniency.sh [hatch ...]      (default: all three)
set -u
cd "$(dirname "$0")/.."

run_hatch() {
  printf '=== %s ===\n' "$1"
  # The binary MUST live in the project directory. Built to /tmp it cannot
  # resolve `import io` — modules.nim looks for std/ relative to the binary —
  # so every example importing the stdlib fails for a reason that has nothing
  # to do with the hatch under test. That mistake inflated the first run of
  # this script from 3 failures to 18.
  if ! nim c --hints:off --warnings:off -d:"$1" -o:"./tuck_$1" tuck.nim 2>/dev/null
  then
    printf '  BUILD FAILED\n\n'
    return
  fi
  for f in examples/*.tuck; do
    "./tuck_$1" ch "$f" >/dev/null 2>&1 || printf '  %s\n' "$(basename "$f")"
  done
  rm -f "./tuck_$1"
  printf '\n'
}

for hatch in "${@:-strictUnknown strictNumeric strictKind}"; do
  run_hatch "$hatch"
done
