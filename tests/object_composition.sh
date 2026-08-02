#!/bin/bash
# Object composition is set union (spec §4.5), the same as type composition.
#
# `type M = A + B` flattens A's and B's fields into M. `object O: + A` did NOT
# — it emitted a NESTED field (`tuck_A: tuck_A`) while the checker went on
# treating the composed fields as the object's own. So `self.x` on a composed
# field typechecked, emitted `self.x`, and Nim rejected it:
#
#   Error: undeclared field: 'x'
#
# Same `+`, same spec section, two different meanings.
cd "$(dirname "$0")/.."
. tests/lib.sh

# --- the case that was broken --------------------------------------------

src <<'EOF'
type A = {x: int}

object Obj:
  + A

  fn get({self: Obj}) -> int:
    return self.x

fn main() -> int:
  return 0
EOF
ok_check "a composed field is reachable by its own name"
emits    "and the object carries it directly"  'x\*: int'
omits    "not as a nested record"              'tuck_A\*: tuck_A'
runs     "so the emitted code compiles"        0

# Two records merge, and both their fields land.
src <<'EOF'
type A = {x: int}
type B = {y: int}

object Obj:
  + A
  + B

  fn total({self: Obj}) -> int:
    return self.x + self.y

fn main() -> int:
  return 0
EOF
ok_check "two composed records both contribute"
runs     "and the result compiles"  0

# The object's own fields and composed fields coexist.
src <<'EOF'
type A = {x: int}

object Obj:
  own: int
  + A

  fn total({self: Obj}) -> int:
    return self.own + self.x

fn main() -> int:
  return 0
EOF
ok_check "own fields and composed fields coexist"
runs     "and compile together"  0

# A composed MIXIN contributes fns, not fields — it must not become a field.
src <<'EOF'
type A = {x: int}

mixin Helpers:
  fn double({self: Self}) -> int:
    return self.x + self.x

object Obj:
  + A
  + Helpers

fn main() -> int:
  return 0
EOF
ok_check "a mixin composes without adding a field"
omits    "no field named after the mixin"  'helpers|Helpers\*:'

# Type composition, the form that already worked — a regression guard.
src <<'EOF'
type A = {x: int}
type B = {y: int}
type M = A + B

fn use({m: M}) -> int:
  return m.x + m.y

fn main() -> int:
  return 0
EOF
ok_check "type composition still flattens"
runs     "and still compiles"  0

finish
