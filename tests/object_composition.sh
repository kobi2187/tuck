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
emits_odin "Odin: merged too"                  'x: int'
omits_odin "Odin: not nested either"           'tuck_A: tuck_A'
frozen     "so the emitted code compiles"
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
frozen     "and the result compiles"
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
frozen     "and compile together"
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
frozen     "and still compiles"
# A `..` chain followed by a `.` call. The chain lowers to STATEMENTS, so the
# call must be sequenced after them — not spliced into its argument list,
# which emitted `startAudio(self = loadEp(self, n))`: an assignment inside a
# call, rejected by Nim as "expression is immutable, not 'var'" and by Odin
# equally. `runs` is the real assertion here; `ok_check` alone passed
# throughout, because the defect was in emission rather than in typing.
src <<'EOF'
fn loadEp({self: App, n: int}) -> App:
  self

fn startAudio({self: App}) -> void:
  return

object App:
  n: int
  fn play({n: int}) -> void:
    self ..loadEp {n} .startAudio

fn main() -> int:
  var a = {n: 1} App
  return 0
EOF
ok_check "a builder chain followed by a terminal call"
frozen     "and lowers to sequenced statements, not a nested call"
omits    "the terminal call does not write back to the base"  'self = tuck_loadEp'

# A chain BOUND to a variable. `a` must be left alone — the chain threads a
# temp and the binding reads it. This emitted `var b =     a = tuck_setN(a, 5)`
# (an assignment inside an assignment, rejected by Nim) AND clobbered `a`.
src <<'EOF'
fn setN({self: App, n: int}) -> App:
  self

object App:
  n: int

fn main() -> int:
  var a = {n: 0} App
  var b = a ..setN {n: 5} ..setN {n: 7}
  return b.n
EOF
ok_check "a chain bound to a variable"
frozen     "and compiles"
omits    "the bound chain leaves its base alone"  'a = tuck_setN'
emits    "each step reads the previous step's result"  'tuckChain1 = tuck_setN\(tuckChain1'

finish
