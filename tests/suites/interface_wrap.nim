## An interface-typed parameter accepts only objects that satisfy it, and the
## call site is where the concrete type is recorded (spec §5.3).
##
## An interface name in type position is not a value type — it is the two-word
## pair {data, table}. The table is chosen HERE, where the compiler still knows
## the argument's concrete type; by the time the callee runs, that knowledge is
## gone. Recording the (object, interface) pair at the call site is also what
## makes emission demand-driven: a `satisfies` nobody ever passes as costs the
## conformance check and nothing else.

import ../harness

proc run*(t: var T) =
  # --- accepted: the object satisfies the interface -------------------------

  t.src """
interface Animal:
  fn noise({self: Self}) -> int

object Dog:
  satisfies Animal
  name: str

  fn noise({self: Dog}) -> int:
    return 1

fn hear({a: Animal}) -> int:
  return 0

fn main() -> int:
  var d = {name: "rex"} Dog
  return {a: d} hear
"""
  t.okCheck "an object satisfying the interface may be passed as one"

  # Two different objects, one interface parameter — the point of the feature.
  t.src """
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
  return 0

fn main() -> int:
  var d = {name: "rex"} Dog
  var c = {lives: 9} Cat
  return ({a: d} hear) + ({a: c} hear)
"""
  t.okCheck "two different objects may reach one interface parameter"

  # --- rejected: the object does not satisfy it -----------------------------

  # Rejecting a non-satisfying object needs the ARGUMENT's concrete type, which
  # means `{fields} Obj` has to produce one. It used to yield Unknown — objects
  # were missing from the construction path — and Unknown is compatible with
  # everything, so there was nothing to reject.
  t.src """
interface Animal:
  fn noise({self: Self}) -> int

object Rock:
  weight: int

fn hear({a: Animal}) -> int:
  return 0

fn main() -> int:
  var r = {weight: 5} Rock
  return {a: r} hear
"""
  t.badCheck "an object that does not satisfy is rejected", "Rock|satisfies|Animal"

  # Declaring `satisfies` is what admits an object — having the right members by
  # coincidence is not enough. Conformance is explicit (spec §5.2).
  t.src """
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
"""
  t.badCheck "structural match without a satisfies line is still rejected",
             "Robot|satisfies|Animal"

  # A non-object value cannot be an interface either.
  t.src """
interface Animal:
  fn noise({self: Self}) -> int

fn hear({a: Animal}) -> int:
  return 0

fn main() -> int:
  return {a: 5} hear
"""
  t.badCheck "a plain value is not an interface", "Animal|int"

  t.finish()
