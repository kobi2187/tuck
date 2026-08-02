#!/bin/bash
# An interface-typed parameter accepts only objects that satisfy it, and the
# call site is where the concrete type is recorded (spec §5.3).
#
# An interface name in type position is not a value type — it is the two-word
# pair {data, table}. The table is chosen HERE, where the compiler still knows
# the argument's concrete type; by the time the callee runs, that knowledge is
# gone. Recording the (object, interface) pair at the call site is also what
# makes emission demand-driven: a `satisfies` nobody ever passes as costs the
# conformance check and nothing else.
cd "$(dirname "$0")/.."
. tests/lib.sh

# --- accepted: the object satisfies the interface -------------------------

src <<'EOF'
interface Animal:
  fn noise({self: Self}) -> int

object Dog:
  name: str
  satisfies Animal

  fn noise({self: Dog}) -> int:
    return 1

fn hear({a: Animal}) -> int:
  return 0

fn main() -> int:
  var d = {name: "rex"} Dog
  return {a: d} hear
EOF
ok_check "an object satisfying the interface may be passed as one"

# Two different objects, one interface parameter — the point of the feature.
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
  return 0

fn main() -> int:
  var d = {name: "rex"} Dog
  var c = {lives: 9} Cat
  return ({a: d} hear) + ({a: c} hear)
EOF
ok_check "two different objects may reach one interface parameter"

# --- rejected: the object does not satisfy it -----------------------------

# OPEN, both cases below: rejecting a non-satisfying object needs the checker
# to know the ARGUMENT's concrete type, and it does not.
#
# synthesize's exkVar arm resolves a name against locals and fnSigs only. It
# knows nothing of objects, pools, registries, actors, registers, sum-type
# variants, `Error` or `result` — every one of those synthesizes as Unknown,
# and Unknown is compatible with everything, so the argument check has nothing
# to reject. Same root cause as the undeclared-assignment-target hole
# (tests/actor_result.sh) and the loop-variable hole that was fixed by giving
# the loop variable its real element type.
#
# The positive cases above pass for the right reason: an object that DOES
# declare `satisfies` is accepted, and the wrap is recorded.
src <<'EOF'
interface Animal:
  fn noise({self: Self}) -> int

object Rock:
  weight: int

fn hear({a: Animal}) -> int:
  return 0

fn main() -> int:
  var r = {weight: 5} Rock
  return {a: r} hear
EOF
try bad_check "an object that does not satisfy is rejected" "Rock|satisfies|Animal"
bug_open "a non-satisfying object is not rejected (argument type is Unknown)"

# Declaring `satisfies` is what admits an object — having the right members by
# coincidence is not enough. Conformance is explicit (spec §5.2).
src <<'EOF'
interface Animal:
  fn noise({self: Self}) -> int

object Robot:
  id: int

  fn noise({self: Robot}) -> int:
    return 7

fn hear({a: Animal}) -> int:
  return 0

fn main() -> int:
  var r = {id: 1} Robot
  return {a: r} hear
EOF
try bad_check "structural match without a satisfies line is still rejected" "Robot|satisfies|Animal"
bug_open "a structural match without satisfies is not rejected (same cause)"

# A non-object value cannot be an interface either.
src <<'EOF'
interface Animal:
  fn noise({self: Self}) -> int

fn hear({a: Animal}) -> int:
  return 0

fn main() -> int:
  return {a: 5} hear
EOF
bad_check "a plain value is not an interface" "Animal|int"

finish
