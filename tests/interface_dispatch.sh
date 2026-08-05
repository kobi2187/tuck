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
  satisfies Animal
  name: str

  fn noise({self: Dog}) -> int:
    return 1

fn hear({a: Animal}) -> int:
  return a.noise

fn main() -> int:
  var d = {name: "rex"} Dog
  return {a: d} hear
EOF
ok_check "the program checks"
emits "a tag enum for the interface"       'AnimalTag'
emits "the value is a variant over its types" 'case tag'
emits "the payload is the object itself"   'tuck_DogVal'
emits "dispatch is a case on the tag"      'case .*\.tag'
omits "no function table"                  'AnimalVT'
omits "no thunks"                          'Animal_tuck_Dog_noise'
runs  "and the program runs"               1

# Both backends, or it is not a feature. The parity commitment is explicit in
# codegen.nim's header: share the logic, never share the syntax.
emits_odin "Odin: a tag enum"          'AnimalTag'
emits_odin "Odin: a variant struct"    'tag: AnimalTag'
emits_odin "Odin: dispatch switches"   'switch v\.tag'
omits_odin "Odin: no function table"   'AnimalVT' 

# --- dispatch actually selects per object ---------------------------------

# 1 + 41 = 42, reachable only if each element carried its own table. Either
# impl alone gives 2 or 82.
src <<'EOF'
interface Animal:
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

fn hear({a: Animal}) -> int:
  return a.noise

fn main() -> int:
  var d = {name: "rex"} Dog
  var c = {lives: 9} Cat
  return ({a: d} hear) + ({a: c} hear)
EOF
ok_check "two objects, one interface parameter"
runs     "each dispatches to its own implementation"  42
emits    "a branch for Dog"  'Animal_is_tuck_Dog'
emits    "a branch for Cat"  'Animal_is_tuck_Cat'

# Every satisfying type is a branch of the variant, whether or not a program
# wraps one — the type has to hold any of them. That replaces the old
# demand-driven table emission, which existed because a table per (object,
# interface) pair was only needed where a wrap actually happened.
src <<'EOF'
interface Animal:
  fn noise({self: Self}) -> int

object Dog:
  satisfies Animal
  name: str
  fn noise({self: Dog}) -> int:
    return 1

object Ghost:
  satisfies Animal
  n: int
  fn noise({self: Ghost}) -> int:
    return 99

fn hear({a: Animal}) -> int:
  return a.noise

fn main() -> int:
  var d = {name: "rex"} Dog
  return {a: d} hear
EOF
ok_check "an object may satisfy without ever being wrapped"
emits    "it is still a branch of the variant"  'tuck_GhostVal'
runs     "and the program runs"                 1

finish
