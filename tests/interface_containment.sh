#!/bin/bash
# An interface value may not outlive the object it borrows.
#
# The data half of the two-word pair points AT the object, not a copy — that is
# what makes a wrap cost two stores and no allocation, and what makes mutation
# through an interface visible to the original. It is sound only while the
# object outlives the interface value.
#
# This covers the one case that is unambiguously wrong with NO analysis: a
# FIELD. A record, object or actor outlives any scope, so an interface value
# stored in one always outlives the object it borrows.
#
# Deliberately NOT covered yet: returning an interface value, and Seq[Animal]
# as a return type. Those are only unsafe when the data came from a LOCAL —
# returning a borrow of a PARAMETER is fine, and forbidding it outright would
# rule out the mixed-collection case. Deciding that needs a real look at
# whether the value escapes, which is its own design pass.
cd "$(dirname "$0")/.."
. tests/lib.sh

# The shared preamble: an interface and one object satisfying it. A variable,
# not a function piped into `src` — a pipe runs src in a SUBSHELL, so the
# scratch-dir it sets is lost and every later assertion reads the wrong path.
IFACE='interface Animal:
  fn noise({self: Self}) -> int

object Dog:
  name: str
  satisfies Animal

  fn noise({self: Dog}) -> int:
    return 1
'


# --- legal: parameter and local -------------------------------------------

src <<EOF
$IFACE
fn hear({a: Animal}) -> int:
  return a.noise

fn main() -> int:
  var d = {name: "rex"} Dog
  return {a: d} hear
EOF
ok_check "an interface value is legal as a fn parameter"
runs     "and the program runs"  1

# --- illegal: every way it could outlive the object ------------------------


src <<EOF
$IFACE
type Holder = {a: Animal}

fn main() -> int:
  return 0
EOF
bad_check "an interface value in a record field is rejected" "Animal|outlive|parameter"

src <<EOF
$IFACE
object Keeper:
  pet: Animal

fn main() -> int:
  return 0
EOF
bad_check "an interface value in an object field is rejected" "Animal|outlive|parameter"

src <<EOF
$IFACE
actor Zoo:
  resident: Animal

  on feed({n: int}):
    return

fn main() -> int:
  return 0
EOF
bad_check "an interface value in an actor field is rejected" "Animal|outlive|parameter"




finish
