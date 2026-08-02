#!/bin/bash
# Interface dispatch, end to end (spec §5.3).
#
# An interface value is two words: a reference to the data and a reference to
# that concrete type's function table. Both are filled where the compiler still
# knows the concrete type — at the wrap site — so nothing is resolved at run
# time. No object header, no runtime type, no hierarchy, no name lookup.
#
# The tables are emitted on DEMAND: only the (object, interface) pairs some
# wrap site actually asked for. A `satisfies` nobody passes as costs the
# conformance check and nothing else.
cd "$(dirname "$0")/.."
. tests/lib.sh

# --- the shape of the emission --------------------------------------------

src <<'EOF'
interface Animal:
  fn noise({self: Self}) -> int

object Dog:
  name: str
  satisfies Animal

  fn noise({self: Dog}) -> int:
    return 1

fn hear({a: Animal}) -> int:
  return a.noise

fn main() -> int:
  var d = {name: "rex"} Dog
  return {a: d} hear
EOF
ok_check "the program checks"
emits "a table type for the interface"     'AnimalVT'
emits "a two-word pair for the value"      'data.*vt|vt.*data'
emits "a thunk for the pair in use"        'Animal_tuck_Dog_noise'
emits "one static table per pair"          'Animal_for_tuck_Dog'
emits "the call reads the table"           'vt\.noise|\.vt\['
runs  "and the program runs"               1

# --- dispatch actually selects per object ---------------------------------

# 1 + 41 = 42, reachable only if each element carried its own table. Either
# impl alone gives 2 or 82.
src <<'EOF'
interface Animal:
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

fn hear({a: Animal}) -> int:
  return a.noise

fn main() -> int:
  var d = {name: "rex"} Dog
  var c = {lives: 9} Cat
  return ({a: d} hear) + ({a: c} hear)
EOF
ok_check "two objects, one interface parameter"
runs     "each dispatches to its own implementation"  42
emits    "a thunk for Dog"  'Animal_tuck_Dog_noise'
emits    "a thunk for Cat"  'Animal_tuck_Cat_noise'

# --- emission is demand-driven --------------------------------------------

# Ghost satisfies Animal but is never passed as one, so no table and no thunk
# should be emitted for it.
src <<'EOF'
interface Animal:
  fn noise({self: Self}) -> int

object Dog:
  name: str
  satisfies Animal
  fn noise({self: Dog}) -> int:
    return 1

object Ghost:
  n: int
  satisfies Animal
  fn noise({self: Ghost}) -> int:
    return 99

fn hear({a: Animal}) -> int:
  return a.noise

fn main() -> int:
  var d = {name: "rex"} Dog
  return {a: d} hear
EOF
ok_check "an object may satisfy without ever being passed as one"
emits    "the used pair is emitted"      'Animal_for_tuck_Dog'
omits    "the unused pair is not"        'Animal_for_tuck_Ghost'

finish
