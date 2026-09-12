## A collection of interface values: `Seq[Animal]` holding mixed concrete types.
##
## A list literal synthesizes its element type from the FIRST item, so `[d, c]`
## was `Seq[Dog]` and a `Seq[Animal]` parameter rejected it. Each element has to
## be wrapped in its own two-word pair — same as a scalar argument, once per
## element — and each pair carries its own table, which is what makes the
## elements uniform in size while dispatching differently.

import ../harness

const IFACE = """interface Animal:
  fn noise({self: Self}) -> int

object Dog:
  satisfies Animal
  name: str

  fn noise({self: Dog}) -> int:
    return 1

object Cat:
  satisfies Animal
  lives: int

  fn noise({self: Cat}) -> int:
    return 41
"""

proc run*(t: var T) =
  # --- the feature ----------------------------------------------------------

  # 1 + 41 = 42, a number neither implementation reaches alone: only per-element
  # tables produce it.
  t.src IFACE & """
fn total({xs: Seq[Animal]}) -> int:
  var s = 0
  for a in xs:
    s = s + a.noise
  return s

fn main() -> int:
  var d = {name: "rex"} Dog
  var c = {lives: 9} Cat
  return {xs: [d, c]} total
"""
  t.okCheck "a mixed list reaches a Seq[Animal] parameter"
  t.frozen     "each element dispatches to its own implementation"
  t.emits      "a branch for Dog", "tuck_DogVal"
  t.emits      "a branch for Cat", "tuck_CatVal"
  t.emitsOdin "Odin: both branches", "tuck_(Dog|Cat)Val"
  # PRE-EXISTING: Odin rejects a list literal passed to a Seq parameter —
  # "Compound literals of dynamic types are disabled by default" — because
  # [dynamic]T has no literal form, only `append`. A plain Seq[Record] fails
  # identically, so this is not about interfaces; no example passes a list
  # literal to a Seq parameter, which is why it had never surfaced. The fix is
  # statement hoisting in the Odin emitter (declare, append, then use), which is
  # the piece the interface design flagged as the largest Odin-specific item.
  #
  # Was a bare `printf '  OPEN  ...'`, which can never fail — it would have gone
  # on announcing the bug forever after a fix. Stated as the CORRECT behaviour
  # with a bug_open marker instead, so fixing it makes the suite demand the flip.
  t.src IFACE & """
fn total({xs: Seq[Animal]}) -> int:
  var s = 0
  for a in xs:
    s = s + a.noise
  return s

fn main() -> int:
  var d = {name: "rex"} Dog
  var c = {lives: 9} Cat
  return {xs: [d, c]} total
"""
  # FIXED 2026-09-12, and not by the statement hoisting this comment used to
  # predict. Two separate things were wrong:
  #
  # 1. `#+feature dynamic-literals` (already emitted) answers the
  #    "Compound literals of dynamic types are disabled by default" half.
  # 2. The real defect was the ELEMENT TYPE. checkIfaceElems wrapped each
  #    element into the variant but left the list's own type as `Seq[Dog]` —
  #    the first element's concrete type — so Odin emitted
  #    `[dynamic]tuck_Dog{Animal{...}, Animal{...}}`: an element type naming
  #    one implementation, holding values of the variant. Odin spells a
  #    dynamic array literal's element type out, which is why it was the one
  #    backend that could not paper over the mismatch.
  #
  # The snippet above ALSO constructed `Cat` with `{name: "tom"}` while Cat
  # declares `lives: int`. That is a plain type error; it rode in on Unknown,
  # and removing the sentinel turned it into the hard error it always was —
  # which is why this assertion could not pass even once the emitter was
  # right.
  t.quietly: t.omitsOdin "", "tuck_total\\(\\{"
  t.bugFixed "Odin: a list literal can reach a Seq parameter"
  t.emitsOdin "...the element type is the INTERFACE, not the first element's type",
              r"\[dynamic\]Animal\{"

  # A single-element list still works — the common degenerate case.
  t.src IFACE & """
fn total({xs: Seq[Animal]}) -> int:
  var s = 0
  for a in xs:
    s = s + a.noise
  return s

fn main() -> int:
  var d = {name: "rex"} Dog
  return {xs: [d]} total
"""
  t.okCheck "a one-element list of one concrete type"
  t.frozen     "and it runs"
  # Order does not matter: the element type comes from the PARAMETER, not from
  # whichever item happens to be first.
  t.src IFACE & """
fn total({xs: Seq[Animal]}) -> int:
  var s = 0
  for a in xs:
    s = s + a.noise
  return s

fn main() -> int:
  var d = {name: "rex"} Dog
  var c = {lives: 9} Cat
  return {xs: [c, d]} total
"""
  t.okCheck "the first element does not fix the list's type"
  t.frozen     "and the sum is the same either way"
  # --- still rejected -------------------------------------------------------

  # An object that does not satisfy cannot ride in the list.
  t.src IFACE & """
object Rock:
  weight: int

fn total({xs: Seq[Animal]}) -> int:
  return 0

fn main() -> int:
  var d = {name: "rex"} Dog
  var r = {weight: 5} Rock
  return {xs: [d, r]} total
"""
  t.badCheck "a non-satisfying element is rejected", "Rock|satisfies|Animal"

  # A plain Seq of a concrete type is unaffected — the regression guard.
  t.src IFACE & """
fn count({xs: Seq[Dog]}) -> int:
  var s = 0
  for d in xs:
    s = s + 1
  return s

fn main() -> int:
  var a = {name: "rex"} Dog
  var b = {name: "fido"} Dog
  return {xs: [a, b]} count
"""
  t.okCheck "a Seq of a concrete type is untouched"
  t.frozen     "and still runs"
  # --- what copy semantics unlocked ---------------------------------------
  #
  # All three were compile errors under the borrowing representation: the value
  # pointed AT the object, so it could not outlive it. Copying removes the
  # question entirely.

  t.src IFACE & """
fn pick({a: Animal}) -> Animal:
  return a

fn makeOne() -> Animal:
  var d = {name: "rex"} Dog
  return {a: d} pick

fn hear({a: Animal}) -> int:
  return a.noise

fn main() -> int:
  var a = {} makeOne
  return {a: a} hear
"""
  t.okCheck "returning an interface value made from a local"
  t.frozen     "and the copy outlives the local"
  t.src IFACE & """
object Keeper:
  pet: Animal

fn main() -> int:
  return 0
"""
  t.okCheck "an interface value in a field"

  t.src IFACE & """
fn makeMany() -> Seq[Animal]:
  var d = {name: "rex"} Dog
  var c = {lives: 9} Cat
  return [d, c]

fn total({xs: Seq[Animal]}) -> int:
  var s = 0
  for a in xs:
    s = s + a.noise
  return s

fn main() -> int:
  return {xs: makeMany} total
"""
  t.okCheck "returning a Seq of interface values built from locals"
  t.frozen     "and every element survives"
  # An INLINE list literal reaching a Seq[Interface] slot wraps each element,
  # same as pre-bound variables did. Was: the wrap was emitted only for
  # exkVar, so `[{n: 1} A, {n: 2} B]` passed its constructions through raw and
  # Nim typed the seq from the first one — "got tuck_B but expected tuck_A",
  # after typechecking clean. Found 2026-09-04 (config-schema-validator).
  t.src """
interface Rule:
  fn check({self: Self}) -> int

object A:
  satisfies Rule
  n: int
  fn check({self: A}) -> int:
    return 1

object B:
  satisfies Rule
  n: int
  fn check({self: B}) -> int:
    return 2

fn total({rules: Seq[Rule]}) -> int:
  var s = 0
  for r in rules:
    s = s + r.check
  return s

fn main() -> int:
  return {rules: [{n: 1} A, {n: 2} B]} total
"""
  t.runs "an inline list literal wraps each element for a Seq[Interface]", 3
  t.emits "...each with its own tag, not passed through raw",
          r"Rule\(tag: Rule_is_tuck_B, tuck_BVal: tuck_B\(n: 2\)\)"

  t.finish()
