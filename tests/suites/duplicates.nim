## Duplicate declarations must be REJECTED, with the diagnostic naming the
## duplicate.
##
## Found by fuzzing (fuzz/README.md). Every case here was ACCEPTED by the whole
## front end and typechecker, reached codegen, and emitted invalid target code:
##
##   duplicate fn      -> two `proc tuck_f*(): int` in one Nim module
##   duplicate field   -> `x*: int` twice in one object
##   duplicate variant -> `enum Red, Red`
##
## So the user saw a Nim error about generated code they never wrote, at the
## BACKEND, instead of a Tuck error pointing at their own duplicate. That is
## the worst outcome the fuzzing was looking for: not a crash, not an ugly
## message, but a program the compiler was happy to mis-translate.

import ../harness

proc run*(t: var T) =
  # --- top-level declarations -------------------------------------------------

  t.src """
fn f() -> int:
  return 1

fn f() -> int:
  return 2

fn main() -> int:
  return 0
"""
  t.badCheck "duplicate fn", "f"

  t.src """
type T:
  x: int

type T:
  y: int

fn main() -> int:
  return 0
"""
  t.badCheck "duplicate type", "T"

  t.src """
object O:
  a: int

object O:
  b: int

fn main() -> int:
  return 0
"""
  t.badCheck "duplicate object", "O"

  t.src """
const C = 1
const C = 2

fn main() -> int:
  return 0
"""
  t.badCheck "duplicate const", "C"

  # A type and a fn share the call namespace — `{x: 1} F` is ambiguous between
  # constructing the type and calling the fn.
  t.src """
type F:
  x: int

fn F() -> int:
  return 1

fn main() -> int:
  return 0
"""
  t.badCheck "type and fn with the same name", "F"

  # --- members ---------------------------------------------------------------

  t.src """
type T:
  x: int
  x: str

fn main() -> int:
  return 0
"""
  t.badCheck "duplicate field in a type", "x"

  t.src """
object O:
  a: int
  a: str

fn main() -> int:
  return 0
"""
  t.badCheck "duplicate field in an object", "a"

  t.src """
type L:
  | Red
  | Red

fn main() -> int:
  return 0
"""
  t.badCheck "duplicate variant", "Red"

  t.src """
fn f({a: int, a: str}) -> int:
  return 1

fn main() -> int:
  return 0
"""
  t.badCheck "duplicate parameter", "a"

  # --- things that must still be ACCEPTED -------------------------------------
  # The check must not over-reach: the same name in two different SCOPES is
  # fine, and is how ordinary code is written.

  t.src """
type Point:
  x: int
  y: int

type Size:
  x: int
  y: int

fn main() -> int:
  return 0
"""
  t.okCheck "the same field name in two different types"

  t.src """
object A:
  n: int
  fn run({self: A}) -> int:
    return n

object B:
  n: int
  fn run({self: B}) -> int:
    return n

fn main() -> int:
  return 0
"""
  t.okCheck "the same member fn name in two different objects"

  t.src """
fn f({a: int}) -> int:
  return a

fn g({a: int}) -> int:
  return a

fn main() -> int:
  return 0
"""
  t.okCheck "the same parameter name in two different fns"

  # Composition is set union (spec 4.5), and a union with a name in both members
  # is a compile error — resolved by RENAMING at the composition site (spec 2.5),
  # never by the compiler picking a winner. Accepted silently, both fields reached
  # the same Nim object and the user got `Error: attempt to redefine: 'x'` naming
  # generated code they never wrote.
  t.src """
type A:
  x: int

type B:
  x: str

object C:
  + A
  + B

fn main() -> int:
  return 0
"""
  t.badCheck "composed field collision", "x"

  t.src """
type A:
  x: int

type B:
  x: str

type C = A + B

fn main() -> int:
  return 0
"""
  t.badCheck "union field collision", "x"

  # The remedy the error names must actually work.
  t.src """
type A:
  x: int

type B:
  x: str

type C = A + B {x -> bx}

fn main() -> int:
  return 0
"""
  t.okCheck "a rename resolves the collision"

  t.src """
type A:
  a: int

type B:
  b: str

object C:
  + A
  + B

fn main() -> int:
  return 0
"""
  t.okCheck "composition without a collision"

  t.finish()
