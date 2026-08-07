#!/bin/bash
# Duplicate declarations must be REJECTED, with the diagnostic naming the
# duplicate.
#
# Found by fuzzing (fuzz/README.md). Every case here was ACCEPTED by the whole
# front end and typechecker, reached codegen, and emitted invalid target code:
#
#   duplicate fn      -> two `proc tuck_f*(): int` in one Nim module
#   duplicate field   -> `x*: int` twice in one object
#   duplicate variant -> `enum Red, Red`
#
# So the user saw a Nim error about generated code they never wrote, at the
# BACKEND, instead of a Tuck error pointing at their own duplicate. That is
# the worst outcome the fuzzing was looking for: not a crash, not an ugly
# message, but a program the compiler was happy to mis-translate.
cd "$(dirname "$0")/.."
. tests/lib.sh

# --- top-level declarations -------------------------------------------------

src <<'TUCKEOF'
fn f() -> int:
  return 1

fn f() -> int:
  return 2

fn main() -> int:
  return 0
TUCKEOF
bad_check 'duplicate fn' 'f'

src <<'TUCKEOF'
type T:
  x: int

type T:
  y: int

fn main() -> int:
  return 0
TUCKEOF
bad_check 'duplicate type' 'T'

src <<'TUCKEOF'
object O:
  a: int

object O:
  b: int

fn main() -> int:
  return 0
TUCKEOF
bad_check 'duplicate object' 'O'

src <<'TUCKEOF'
const C = 1
const C = 2

fn main() -> int:
  return 0
TUCKEOF
bad_check 'duplicate const' 'C'

# A type and a fn share the call namespace — `{x: 1} F` is ambiguous between
# constructing the type and calling the fn.
src <<'TUCKEOF'
type F:
  x: int

fn F() -> int:
  return 1

fn main() -> int:
  return 0
TUCKEOF
bad_check 'type and fn with the same name' 'F'

# --- members ---------------------------------------------------------------

src <<'TUCKEOF'
type T:
  x: int
  x: str

fn main() -> int:
  return 0
TUCKEOF
bad_check 'duplicate field in a type' 'x'

src <<'TUCKEOF'
object O:
  a: int
  a: str

fn main() -> int:
  return 0
TUCKEOF
bad_check 'duplicate field in an object' 'a'

src <<'TUCKEOF'
type L:
  | Red
  | Red

fn main() -> int:
  return 0
TUCKEOF
bad_check 'duplicate variant' 'Red'

src <<'TUCKEOF'
fn f({a: int, a: str}) -> int:
  return 1

fn main() -> int:
  return 0
TUCKEOF
bad_check 'duplicate parameter' 'a'

# --- things that must still be ACCEPTED -------------------------------------
# The check must not over-reach: the same name in two different SCOPES is
# fine, and is how ordinary code is written.

src <<'TUCKEOF'
type Point:
  x: int
  y: int

type Size:
  x: int
  y: int

fn main() -> int:
  return 0
TUCKEOF
ok_check 'the same field name in two different types'

src <<'TUCKEOF'
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
TUCKEOF
ok_check 'the same member fn name in two different objects'

src <<'TUCKEOF'
fn f({a: int}) -> int:
  return a

fn g({a: int}) -> int:
  return a

fn main() -> int:
  return 0
TUCKEOF
ok_check 'the same parameter name in two different fns'

# Composition is set union (spec 4.5), and a union with a name in both members
# is a compile error — resolved by RENAMING at the composition site (spec 2.5),
# never by the compiler picking a winner. Accepted silently, both fields reached
# the same Nim object and the user got `Error: attempt to redefine: 'x'` naming
# generated code they never wrote.
src <<'TUCKEOF'
type A:
  x: int

type B:
  x: str

object C:
  + A
  + B

fn main() -> int:
  return 0
TUCKEOF
bad_check 'composed field collision' 'x'

src <<'TUCKEOF'
type A:
  x: int

type B:
  x: str

type C = A + B

fn main() -> int:
  return 0
TUCKEOF
bad_check 'union field collision' 'x'

# The remedy the error names must actually work.
src <<'TUCKEOF'
type A:
  x: int

type B:
  x: str

type C = A + B {x -> bx}

fn main() -> int:
  return 0
TUCKEOF
ok_check 'a rename resolves the collision'

src <<'TUCKEOF'
type A:
  a: int

type B:
  b: str

object C:
  + A
  + B

fn main() -> int:
  return 0
TUCKEOF
ok_check 'composition without a collision'

finish
