#!/bin/bash
# A collection of interface values: `Seq[Animal]` holding mixed concrete types.
#
# A list literal synthesizes its element type from the FIRST item, so `[d, c]`
# was `Seq[Dog]` and a `Seq[Animal]` parameter rejected it. Each element has to
# be wrapped in its own two-word pair — same as a scalar argument, once per
# element — and each pair carries its own table, which is what makes the
# elements uniform in size while dispatching differently.
cd "$(dirname "$0")/.."
. tests/lib.sh

IFACE='interface Animal:
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
'

# --- the feature ----------------------------------------------------------

# 1 + 41 = 42, a number neither implementation reaches alone: only per-element
# tables produce it.
src <<EOF
$IFACE
fn total({xs: Seq[Animal]}) -> int:
  var s = 0
  for a in xs:
    s = s + a.noise
  return s

fn main() -> int:
  var d = {name: "rex"} Dog
  var c = {lives: 9} Cat
  return {xs: [d, c]} total
EOF
ok_check "a mixed list reaches a Seq[Animal] parameter"
runs     "each element dispatches to its own implementation"  42
emits      "a branch for Dog"  'tuck_DogVal'
emits      "a branch for Cat"  'tuck_CatVal'
emits_odin "Odin: both branches" 'tuck_(Dog|Cat)Val'
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
src <<EOF
$IFACE
fn total({xs: Seq[Animal]}) -> int:
  var s = 0
  for a in xs:
    s = s + a.noise
  return s

fn main() -> int:
  var d = {name: "rex"} Dog
  var c = {name: "tom"} Cat
  return {xs: [d, c]} total
EOF
# Asserted at the EMISSION level, because lib.sh cannot run `odin build` (only
# odin_backend.sh can). The observable is the inline BRACED COMPOUND LITERAL at
# the call site — `tuck_total({Animal{...}})` — which is precisely what Odin
# rejects with "Compound literals of dynamic types are disabled by default".
# The fix is statement hoisting: declare a temp, append to it, pass the temp.
# When that lands this literal disappears and the assertion flips.
try omits_odin "" 'tuck_total\(\{'
bug_open "Odin: a list literal can reach a Seq parameter"

# A single-element list still works — the common degenerate case.
src <<EOF
$IFACE
fn total({xs: Seq[Animal]}) -> int:
  var s = 0
  for a in xs:
    s = s + a.noise
  return s

fn main() -> int:
  var d = {name: "rex"} Dog
  return {xs: [d]} total
EOF
ok_check "a one-element list of one concrete type"
runs     "and it runs"  1

# Order does not matter: the element type comes from the PARAMETER, not from
# whichever item happens to be first.
src <<EOF
$IFACE
fn total({xs: Seq[Animal]}) -> int:
  var s = 0
  for a in xs:
    s = s + a.noise
  return s

fn main() -> int:
  var d = {name: "rex"} Dog
  var c = {lives: 9} Cat
  return {xs: [c, d]} total
EOF
ok_check "the first element does not fix the list's type"
runs     "and the sum is the same either way"  42

# --- still rejected -------------------------------------------------------

# An object that does not satisfy cannot ride in the list.
src <<EOF
$IFACE
object Rock:
  weight: int

fn total({xs: Seq[Animal]}) -> int:
  return 0

fn main() -> int:
  var d = {name: "rex"} Dog
  var r = {weight: 5} Rock
  return {xs: [d, r]} total
EOF
bad_check "a non-satisfying element is rejected" "Rock|satisfies|Animal"

# A plain Seq of a concrete type is unaffected — the regression guard.
src <<EOF
$IFACE
fn count({xs: Seq[Dog]}) -> int:
  var s = 0
  for d in xs:
    s = s + 1
  return s

fn main() -> int:
  var a = {name: "rex"} Dog
  var b = {name: "fido"} Dog
  return {xs: [a, b]} count
EOF
ok_check "a Seq of a concrete type is untouched"
runs     "and still runs"  2

# --- what copy semantics unlocked ---------------------------------------
#
# All three were compile errors under the borrowing representation: the value
# pointed AT the object, so it could not outlive it. Copying removes the
# question entirely.

src <<EOF
$IFACE
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
EOF
ok_check "returning an interface value made from a local"
runs     "and the copy outlives the local"  1

src <<EOF
$IFACE
object Keeper:
  pet: Animal

fn main() -> int:
  return 0
EOF
ok_check "an interface value in a field"

src <<EOF
$IFACE
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
  return {xs: {} makeMany} total
EOF
ok_check "returning a Seq of interface values built from locals"
runs     "and every element survives"  42

finish
