#!/bin/bash
# A bare sum-type variant carries its sum type.
#
# `Red` in `state: {Red, Yellow, Green} = Red` synthesized as Unknown, because
# exkVar resolves names against locals and fnSigs only — a variant is neither.
# Unknown is compatible with everything, so the initializer was never checked
# against the field, and neither was any later use.
cd "$(dirname "$0")/.."
. tests/lib.sh

# --- a bare variant is its sum type ---------------------------------------

src <<'EOF'
type Light:
  | Red
  | Yellow
  | Green

fn pick() -> Light:
  return Red

fn main() -> int:
  return 0
EOF
ok_check "a bare variant satisfies its own sum type"

src <<'EOF'
type Light:
  | Red
  | Yellow

type Colour:
  | Blue

fn pick() -> Colour:
  return Red

fn main() -> int:
  return 0
EOF
try bad_check "a variant of another sum type is rejected" "Red|Colour|Light"
# NOT caused by bare variants: two different sum types were compatible with
# each other generally — `fn pick({l: Light}) -> Colour: return l` passed too,
# with no bare variant involved. Fixed in `compatible`, which now rejects two
# differently-named sums BEFORE resolving them (resolving destroyed the names,
# and the fallthrough `a.kind == e.kind` then saw tkSum == tkSum).
bug_fixed "two different sum types are not compatible"

src <<'EOF'
type Light:
  | Red
  | Yellow

fn pick() -> int:
  return Red

fn main() -> int:
  return 0
EOF
bad_check "a variant where an int is expected is rejected" "Red|int|Light"

# --- what must keep working ------------------------------------------------

# An inline sum type on an actor field, initialized with a bare variant —
# examples/08-actors_isolated_state.tuck's exact shape.
src <<'EOF'
actor Signal:
  state: {Red, Yellow, Green} = Red

  on step():
    state = Green

fn main() -> int:
  return 0
EOF
ok_check "an inline sum field initializes from a bare variant"

# Qualified form still resolves.
src <<'EOF'
type Light:
  | Red
  | Green

fn pick() -> Light:
  return Light.Red

fn main() -> int:
  return 0
EOF
ok_check "the qualified form still works"

# A decision table's outcomes are bare variants too.
src <<'EOF'
type Queue:
  | QueueFast
  | QueueSlow

decision route({urgent: bool}) -> Queue:
  | true  -> QueueFast
  | false -> QueueSlow

fn main() -> int:
  return 0
EOF
ok_check "decision-table outcomes may be bare variants"

finish
