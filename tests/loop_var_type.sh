#!/bin/bash
# A `for` loop variable carries the element type.
#
# It used to bind as Unknown (typecheck.nim exkFor: `discard
# tc.synthesize(e.iterable)` then `bindName(..., unknownType(...))`), and
# Unknown is compatible with everything — so EVERY field access on a loop
# variable was unchecked. `for p in people: p.nosuchfield` typechecked clean
# and reached codegen.
#
# This also blocks interface dispatch: `for a in animals: a.makeNoise` needs
# `a`'s real type to find the interface member, and an Unknown receiver falls
# through to a by-name lookup in the flat signature table.
cd "$(dirname "$0")/.."
. tests/lib.sh

# --- the bug: a bad field on a loop variable must be caught ---------------

src <<'EOF'
type P = {n: int}

fn total({xs: Seq[P]}) -> int:
  var s = 0
  for x in xs:
    s = s + x.nosuchfield
  return s

fn main() -> int:
  return 0
EOF
bad_check "unknown field on a loop variable" "nosuchfield|not a field|no field"

# `for idx, item in xs:` — the second binding is the element, same rule
src <<'EOF'
type P = {n: int}

fn total({xs: Seq[P]}) -> int:
  var s = 0
  for i, x in xs:
    s = s + x.nosuchfield
  return s

fn main() -> int:
  return 0
EOF
bad_check "unknown field on an indexed loop variable" "nosuchfield|not a field|no field"

# --- what must keep working ----------------------------------------------

src <<'EOF'
type P = {n: int}

fn total({xs: Seq[P]}) -> int:
  var s = 0
  for x in xs:
    s = s + x.n
  return s

fn main() -> int:
  return {xs: [{n: 3} P, {n: 39} P]} total
EOF
ok_check "a real field on a loop variable still checks"
frozen     "and the loop still computes"
# The index of `for idx, item in xs:` is an int, and the element keeps its type
src <<'EOF'
type P = {n: int}

fn total({xs: Seq[P]}) -> int:
  var s = 0
  for i, x in xs:
    s = s + i + x.n
  return s

fn main() -> int:
  return {xs: [{n: 3} P, {n: 38} P]} total
EOF
ok_check "indexed form binds both"
frozen     "index is an int, element keeps its type"
# Ranges bind an int, not an element type — must not regress
src <<'EOF'
fn main() -> int:
  var s = 0
  for i in 0 ..< 4:
    s = s + i
  return s
EOF
frozen "a range loop still binds an int"
# Nested loops over different element types keep their own bindings
src <<'EOF'
type P = {n: int}
type Q = {m: int}

fn both({ps: Seq[P], qs: Seq[Q]}) -> int:
  var s = 0
  for p in ps:
    for q in qs:
      s = s + p.n + q.m
  return s

fn main() -> int:
  return {ps: [{n: 1} P], qs: [{m: 41} Q]} both
EOF
ok_check "nested loops keep separate element types"
frozen     "and compute correctly"
finish
