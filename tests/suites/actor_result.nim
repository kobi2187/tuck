## `result` is GONE, and a handler may not declare a return type.
##
## History, because the shape of the fix is the point. `result` was bound
## inside a handler to the handler's declared return type. Nothing bound it
## before that, so it synthesized as Unknown and every assignment was
## accepted; binding it made the type real. But two problems survived:
##
##   1. Nothing ever checked that `result` was ASSIGNED. A path that skipped
##      it yielded whatever the backend zero-inits — exactly what TK-TY16
##      refuses for a record field nobody set. A zero is not a value.
##   2. Nothing COLLECTED it. `handleMsg` returns nothing, so `result = x`
##      emitted a local the emitter then discarded. The declared return type
##      promised a reply the runtime cannot deliver: an actor message is
##      fire-and-forget (spec 9.1) and correlation tokens are designed, not
##      implemented (TODO.md section 1).
##
## Ruling 2026-09-06: reject the return type (TK-AC02), which removes the only
## thing `result` was bound to, and `result` with it. It is now an ordinary
## undeclared name. The reply gap stays visible rather than looking supported.

import ../harness

proc run*(t: var T) =
  # A handler declaring a return type is the construct that cannot be honoured.
  t.src """
actor Counter:
  count: int = 0

  on get() -> {count: int}:
    count = count

fn main() -> int:
  return 0
"""
  t.badCheck "a handler may not declare a return type", "TK-AC02"
  t.badCheck "...and the message says why: no reply channel",
             "cannot reply yet"

  # With nothing to bind it to, `result` is just a name nobody declared.
  t.src """
actor Counter:
  count: int = 0

  on bump({n: int}):
    result = n

fn main() -> int:
  return 0
"""
  t.badCheck "`result` in a handler is an undeclared name", "result"

  # A handler with no return type is the normal shape and still works.
  t.src """
actor Counter:
  count: int = 0

  on bump({n: int}):
    count += n

fn main() -> int:
  return 0
"""
  t.okCheck "a handler with no return type is fine"

  # `-> void` is NOT a reply claim: it carries nothing and means exactly what
  # omitting the type means. Only a type that would carry a VALUE back
  # promises something there is no channel for. The first version of this
  # rule rejected `-> void` too and broke three existing actors.
  t.src """
actor Counter:
  count: int = 0

  on bump({n: int}) -> void:
    count += n

fn main() -> int:
  return 0
"""
  t.okCheck "an explicit `-> void` handler is still fine"

  # The actor's own fields still resolve inside a handler — a regression guard,
  # since removing the `result` binding must not disturb the field scope.
  t.src """
actor Counter:
  count: int = 0

  on bump({n: int}):
    count += n
    self.count += 0

fn main() -> int:
  return 0
"""
  t.okCheck "actor fields still resolve, bare and through self"

  # Assigning to a name nothing declares. Not actor-specific — it is the same
  # rule in a plain fn, which is where the fix landed.
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
