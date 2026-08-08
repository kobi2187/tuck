## `result` inside an actor handler carries the handler's declared return type.
##
## It was bound to nothing at all, so it synthesized as Unknown — and Unknown is
## compatible with everything, so `result = <anything>` was accepted and every
## later use went unchecked. One of the gaps a strict-typing experiment
## surfaced; the sentinel had been hiding it.
##
## A handler with NO return type gets no binding, which is why `result = ...`
## there should be an undeclared-name error — still open below, because
## undeclared names are unchecked generally (not an actor problem).

import ../harness

proc run*(t: var T) =
  t.src """
actor Counter:
  count: int = 0

  on get() -> {count: int}:
    result = {count}

fn main() -> int:
  return 0
"""
  t.okCheck "assigning the declared shape to result is fine"

  t.src """
actor Counter:
  count: int = 0

  on get() -> {count: int}:
    result = "not a record"

fn main() -> int:
  return 0
"""
  t.badCheck "assigning the wrong type to result is caught", "result|count|str"

  # A handler with no return type has no result to assign.
  t.src """
actor Counter:
  count: int = 0

  on bump({n: int}):
    result = {count}

fn main() -> int:
  return 0
"""
  t.quietly: t.badCheck("a void handler has no result", "result")
  t.bugFixed "a void handler's result is rejected (same cause)"

  # The actor's own fields still resolve inside a handler — a regression guard,
  # since binding result must not disturb the field scope.
  t.src """
actor Counter:
  count: int = 0

  on bump({n: int}):
    count += n

fn main() -> int:
  return 0
"""
  t.okCheck "actor fields still resolve in a handler"

  # Assigning to a name nothing declares — not actor-specific, it is unchecked in
  # a plain fn too. The assignment target synthesizes as Unknown and Unknown
  # accepts anything, so the typo never surfaces.
  t.src """
actor Counter:
  count: int = 0

  on bump({n: int}):
    nosuchfield += n

fn main() -> int:
  return 0
"""
  t.quietly: t.badCheck("an unknown actor field is caught", "nosuchfield")
  t.bugFixed "an undeclared assignment target is caught in a handler"

  t.src """
fn f({n: int}) -> void:
  nosuchvar += n

fn main() -> int:
  return 0
"""
  t.quietly:
    t.badCheck("an undeclared assignment target is caught in a plain fn too",
               "nosuchvar")
  t.bugFixed "...and the same in a plain fn, which is where the fix landed"

  t.finish()
