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
  name: str
  satisfies Animal

  fn noise({self: Dog}) -> int:
    return 1

object Cat:
  lives: int
  satisfies Animal

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
emits      "a table for Dog"   'Animal_for_tuck_Dog'
emits      "a table for Cat"   'Animal_for_tuck_Cat'
emits_odin "Odin: both tables" 'Animal_for_tuck_(Dog|Cat)'
# OPEN, and PRE-EXISTING: Odin rejects a list literal passed to a Seq
# parameter — "Compound literals of dynamic types are disabled by default" —
# because [dynamic]T has no literal form, only `append`. A plain Seq[Record]
# fails identically, so this is not about interfaces; no example passes a list
# literal to a Seq parameter, which is why it had never surfaced. The fix is
# statement hoisting in the Odin emitter (declare, append, then use), which is
# the piece the interface design flagged as the largest Odin-specific item.
printf '  OPEN  Odin: a list literal cannot reach a Seq parameter (pre-existing)\n' 

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

finish
