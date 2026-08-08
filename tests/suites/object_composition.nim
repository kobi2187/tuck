## Object composition is set union (spec §4.5), the same as type composition.
##
## `type M = A + B` flattens A's and B's fields into M. `object O: + A` did NOT
## — it emitted a NESTED field (`tuck_A: tuck_A`) while the checker went on
## treating the composed fields as the object's own. So `self.x` on a composed
## field typechecked, emitted `self.x`, and Nim rejected it:
##
##   Error: undeclared field: 'x'
##
## Same `+`, same spec section, two different meanings.

import ../harness

proc run*(t: var T) =
  # --- the case that was broken --------------------------------------------

  t.src """
type A = {x: int}

object Obj:
  + A

  fn get({self: Obj}) -> int:
    return self.x

fn main() -> int:
  return 0
"""
  t.okCheck "a composed field is reachable by its own name"
  t.emits     "and the object carries it directly", "x\\*: int"
  t.omits     "not as a nested record", "tuck_A\\*: tuck_A"
  t.emitsOdin "Odin: merged too", "x: int"
  t.omitsOdin "Odin: not nested either", "tuck_A: tuck_A"
  t.frozen    "so the emitted code compiles"
  # Two records merge, and both their fields land.
  t.src """
type A = {x: int}
type B = {y: int}

object Obj:
  + A
  + B

  fn total({self: Obj}) -> int:
    return self.x + self.y

fn main() -> int:
  return 0
"""
  t.okCheck "two composed records both contribute"
  t.frozen  "and the result compiles"
  # The object's own fields and composed fields coexist.
  t.src """
type A = {x: int}

object Obj:
  own: int
  + A

  fn total({self: Obj}) -> int:
    return self.own + self.x

fn main() -> int:
  return 0
"""
  t.okCheck "own fields and composed fields coexist"
  t.frozen  "and compile together"
  # A composed MIXIN contributes fns, not fields — it must not become a field.
  t.src """
type A = {x: int}

mixin Helpers:
  fn double({self: Self}) -> int:
    return self.x + self.x

object Obj:
  + A
  + Helpers

fn main() -> int:
  return 0
"""
  t.okCheck "a mixin composes without adding a field"
  t.omits   "no field named after the mixin", "helpers|Helpers\\*:"

  # Type composition, the form that already worked — a regression guard.
  t.src """
type A = {x: int}
type B = {y: int}
type M = A + B

fn use({m: M}) -> int:
  return m.x + m.y

fn main() -> int:
  return 0
"""
  t.okCheck "type composition still flattens"
  t.frozen  "and still compiles"
  # A `..` chain followed by a `.` call. The chain lowers to STATEMENTS, so the
  # call must be sequenced after them — not spliced into its argument list,
  # which emitted `startAudio(self = loadEp(self, n))`: an assignment inside a
  # call, rejected by Nim as "expression is immutable, not 'var'" and by Odin
  # equally. `runs` is the real assertion here; `ok_check` alone passed
  # throughout, because the defect was in emission rather than in typing.
  t.src """
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
"""
  t.okCheck "a builder chain followed by a terminal call"
  t.frozen  "and lowers to sequenced statements, not a nested call"
  t.omits   "the terminal call does not write back to the base", "self = tuck_loadEp"

  # A chain BOUND to a variable. `a` must be left alone — the chain threads a
  # temp and the binding reads it. This emitted `var b =     a = tuck_setN(a, 5)`
  # (an assignment inside an assignment, rejected by Nim) AND clobbered `a`.
  t.src """
fn setN({self: App, n: int}) -> App:
  self

object App:
  n: int

fn main() -> int:
  var a = {n: 0} App
  var b = a ..setN {n: 5} ..setN {n: 7}
  return b.n
"""
  t.okCheck "a chain bound to a variable"
  t.frozen  "and compiles"
  t.omits   "the bound chain leaves its base alone", "a = tuck_setN"
  t.emits   "each step reads the previous step's result", "tuckChain1 = tuck_setN\\(tuckChain1"

  t.finish()
