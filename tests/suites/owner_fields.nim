## A bare name inside a member can be the OWNER's field — an object member's,
## an actor handler's, an invariant's — or a param or local that shadows it.
##
## Only the checker's scopes can tell those apart: it binds the owner's fields
## in a scope outside the body, so a param or `let` of the same name wins. The
## backends used to decide instead, by asking whether the name was in a set of
## field names, which cannot see shadowing:
##   * an object member's bare field read emitted a bare `n` that no backend
##     declared — nothing seeded the set for objects at all;
##   * an actor handler's param named like a field read the FIELD, so a
##     handler storing its payload stored the old value back and the program
##     waited forever.
## Now the checker records each bare name that resolves to the owner's field
## (Resolution.ownerFields), and every backend prints what it recorded.

import ../harness

proc run*(t: var T) =
  t.src """
object Counter:
  n: int

  fn get() -> int:
    return n

fn main() -> int:
  let c = {n: 5} Counter
  return c.get
"""
  t.hostRuns "an object member reads its field bare", 5

  t.src """
object Counter:
  n: int

  fn pick({n: int}) -> int:
    return n

fn main() -> int:
  let c = {n: 5} Counter
  return c.pick {n: 9}
"""
  t.hostRuns "a member's param shadows the field it is named like", 9

  t.src """
object Counter:
  n: int

  fn get() -> int:
    let n = 3
    return n

fn main() -> int:
  let c = {n: 5} Counter
  return c.get
"""
  t.hostRuns "a member's local shadows the field it is named like", 3

  t.src """
object Counter:
  n: int

  fn bump() -> int:
    n = n + 2
    return self.n

fn main() -> int:
  var c = {n: 5} Counter
  return c.bump
"""
  t.hostRuns "an object member writes its field bare", 7

  t.src """
actor Acc [queue: 8]:
  total: int = 0

  on put({total: int}):
    Acc.total = total

fn done() -> bool:
  return Acc.total == 5

fn main() -> int:
  Acc send put {total: 5}
  Acc.waitUntil {pred: :done}
  return Acc.total
"""
  t.hostRuns "an actor handler's param shadows the field it is named like", 5

  t.src """
actor Acc [queue: 8]:
  total: int = 0

  on add({v: int}):
    total = total + v

fn done() -> bool:
  return Acc.total == 7

fn main() -> int:
  Acc send add {v: 3}
  Acc send add {v: 4}
  Acc.waitUntil {pred: :done}
  return Acc.total
"""
  t.hostRuns "an actor handler reads and writes its field bare", 7

  t.src """
type Pos:
  n: int
  invariant:
    n > 0

fn main() -> int:
  let p = {n: 4} Pos
  return p.n
"""
  t.hostRuns "an invariant reads its type's field bare", 4

  t.finish()
