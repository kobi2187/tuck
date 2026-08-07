#!/bin/bash
# What does each of `compatible`'s escape hatches actually cost?
#
# The checker is lenient in four separate places, and "too lenient" is not
# actionable until each one has a number. This builds a compiler per hatch,
# with that hatch closed and the others left open, and counts how many of the
# examples stop checking.
#
#   strictUnknown — an Unknown on either side matches anything
#   strictAny     — void / unit / Self / fn match anything
#   strictNumeric — any numeric widens to any other numeric
#   strictKind    — two types of the same KIND match, whatever they are
#
# A high count is not automatically bad: some leniency is deliberate (a
# pending fn's callers must keep compiling). The point is to know which
# examples each one is holding up, so they can be fixed one hatch at a time
# rather than all at once.
#
# Usage: tools/leniency.sh [hatch ...]      (default: all four)
set -u
cd "$(dirname "$0")/.."

run_hatch() {
  printf '=== %s ===\n' "$1"
  if ! nim c --hints:off --warnings:off -d:"$1" -o:/tmp/tuck_$1 tuck.nim 2>/dev/null
  then
    printf '  BUILD FAILED\n\n'
    return
  fi
  for f in examples/*.tuck; do
    /tmp/tuck_$1 ch "$f" >/dev/null 2>&1 || printf '  %s\n' "$(basename "$f")"
  done
  printf '\n'
}

for hatch in "${@:-strictUnknown strictAny strictNumeric strictKind}"; do
  run_hatch "$hatch"
done
