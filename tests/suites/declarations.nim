## The DECLARATION side of the checker.
##
## Call sites were well checked long before declarations were: `send` verifies
## its handler and payload, task results are typed, decision rows are checked
## for gaps and overlaps, transitions against their table. Meanwhile the
## things those refer TO — an actor's queue, an invariant's predicate, the
## event registry, a register's bit layout — were walked by nobody, because
## the checker grew around expressions and a declaration is not one.
##
## Every case here is a rule the SPEC ALREADY STATES. What was missing was
## enforcement, so each rejection below used to be either a Nim error naming
## generated code the user never wrote, or a program that built cleanly and
## then failed at runtime.
##
## Structure per feature: the rules, then what must stay legal. The second
## half matters as much as the first — a checker that rejects real programs
## is worse than one that misses.

import std/strutils
import ../harness

proc run*(t: var T) =
  # --- actors: [queue: N] (TK-AC01) ----------------------------------------
  #
  # The value rode to codegen as a STRING and was never parsed, so `queue: 0`
  # emitted `Mailbox[Msg, 0]`, built a binary, and died on the first send with
  # a division by zero — the ring wraps with `mod Cap`. `queue: -5` built too
  # and died with an index-out-of-bounds. A declaration that cannot work
  # should not reach a backend.

  const actorSrc = """
actor A [queue: $1]:
  n: int = 0

  on take({v: int}) -> void:
    n += v

fn main() -> int:
  return 0
"""
  for bad in ["0", "-5"]:
    t.src actorSrc.replace("$1", bad)
    t.badCheck "an actor queue of " & bad & " is rejected", "TK-AC01"

  t.src actorSrc.replace("$1", "8")
  t.okCheck "a positive actor queue is accepted"

  # No attribute at all is fine — codegen defaults to 8. Only a WRITTEN value
  # is checked, so this must not start failing.
  t.src """
actor A:
  n: int = 0

  on take({v: int}) -> void:
    n += v

fn main() -> int:
  return 0
"""
  t.okCheck "an actor with no queue attribute takes the default"

  # --- invariants (TK-IV01, TK-IV02) ---------------------------------------
  #
  # spec 4.7: a predicate is a yes/no about a value of its type, so it may
  # name that type's own fields and nothing else. A typo used to reach Nim as
  # a spell-suggestion about generated code; a non-boolean predicate became
  # `assert(value + 1, ...)`, a type error in a file the user never wrote.

  t.src """
type Pct:
  value: int
  invariant:
    nosuchfield <= 100

fn main() -> int:
  return 0
"""
  t.badCheck "an invariant naming a field the type lacks is rejected", "TK-IV01"

  t.src """
type Pct:
  value: int
  invariant:
    value + 1

fn main() -> int:
  return 0
"""
  t.badCheck "a non-boolean invariant is rejected", "TK-IV02"

  # The unknown-name rule is checked on the NAMES, not on the predicate's
  # synthesized type: `nosuchfield <= 100` still synthesizes `bool`, so a
  # result-only check would pass exactly the typo case it exists to catch.
  # This case is that regression, pinned.
  t.src """
type Pct:
  value: int
  invariant:
    value >= 0
    value <= 100

fn main() -> int:
  let p = {value: 5} Pct
  return p.value
"""
  t.okCheck "a valid multi-predicate invariant is accepted"

  t.src """
type Range:
  lo: int
  hi: int
  invariant:
    lo <= hi

fn main() -> int:
  let r = {lo: 1, hi: 2} Range
  return r.hi
"""
  t.okCheck "an invariant may relate two of the type's own fields"

  # --- the event registry, Part 10 (TK-RG01..05) ---------------------------
  #
  # Nothing was checked at all. A raise naming a typo'd event reached the
  # backend and became a Nim "invalid indentation" error; an event nobody
  # handled compiled to a signal that silently went nowhere, which is the
  # exact failure the one-registry design exists to prevent.

  t.src """
registry R:
  | Low({n: u32})

on R.Low({n: u32}):
  let x = n

fn f() -> void:
  R.raise NoSuch {n: 1}

fn main() -> int:
  return 0
"""
  t.badCheck "raising an event the registry does not declare is rejected",
             "TK-RG01"

  t.src """
registry R:
  | Low({n: u32})

on R.Low({n: u32}):
  let x = n

on R.NoSuch():
  let q = 1

fn main() -> int:
  return 0
"""
  t.badCheck "handling an event the registry does not declare is rejected",
             "TK-RG01"

  t.src """
registry R:
  | Low({n: u32, why: str})

on R.Low({n: u32, why: str}):
  let x = n

fn f() -> void:
  R.raise Low {n: 1}

fn main() -> int:
  return 0
"""
  t.badCheck "a raise missing a payload field is rejected", "TK-RG02"

  t.src """
registry R:
  | Low({n: u32})

on R.Low({n: u32}):
  let x = n

fn f() -> void:
  R.raise Low {n: 1, bogus: 2}

fn main() -> int:
  return 0
"""
  t.badCheck "a raise with a payload field the event lacks is rejected",
             "TK-RG02"

  t.src """
registry R:
  | Low({n: u32})

fn main() -> int:
  return 0
"""
  t.badCheck "a declared event with no handler is rejected", "TK-RG03"

  # Raising is synchronous, so a handler raising its own event is not a
  # subtle loop — it is an immediate one.
  t.src """
registry R:
  | Low({n: u32})

on R.Low({n: u32}):
  R.raise Low {n: 1}

fn main() -> int:
  return 0
"""
  t.badCheck "a handler raising the event it handles is rejected", "TK-RG04"

  t.src """
registry A:
  | X

on A.X():
  let q = 1

registry B:
  | Y

on B.Y():
  let q = 1

fn main() -> int:
  return 0
"""
  t.badCheck "a second registry is rejected", "TK-RG05"

  # The whole surface, used correctly: declare, raise with the right payload,
  # handle every variant.
  t.src """
registry AppEvents:
  | SensorFailure({port: u8, reason: str})
  | LowMemory({remaining: u32})

fn trigger() -> void:
  AppEvents.raise SensorFailure {port: 1, reason: "timeout"}

on AppEvents.SensorFailure({port: u8, reason: str}):
  let p = port

on AppEvents.LowMemory({remaining: u32}):
  let left = remaining

fn main() -> int:
  return 0
"""
  t.okCheck "a fully handled registry with matching payloads is accepted"

  # --- registers, §8.1 (TK-RE01..04) ---------------------------------------
  #
  # The spec states outright that writing a read-only field is a compile
  # error. It was not one: the write emitted, and on hardware it would be
  # ignored or trigger an undocumented side effect.

  t.src """
register RCC at 0x40021000:
  RDY: bit 1 [read]

fn main() -> void:
  RCC ..RDY {true}
"""
  t.badCheck "writing a [read]-only register field is rejected", "TK-RE01"

  t.src """
register RCC at 0x40021000:
  GO: bit 2 [write]

fn main() -> int:
  let x = RCC.GO
  return 0
"""
  t.badCheck "reading a [write]-only register field is rejected", "TK-RE02"

  t.src """
register RCC at 0x40021000:
  X: bit 99 [read, write]

fn main() -> void:
  discard
"""
  t.badCheck "a bit index past the register's width is rejected", "TK-RE03"

  t.src """
register RCC at 0x40021000:
  X: bits 28..40 [read, write]

fn main() -> void:
  discard
"""
  t.badCheck "a bit RANGE past the register's width is rejected", "TK-RE03"

  # Two fields on one bit means writing either corrupts the other — almost
  # always a transcription slip from the datasheet.
  t.src """
register RCC at 0x40021000:
  A: bits 0..3 [read, write]
  B: bit 2 [read, write]

fn main() -> void:
  discard
"""
  t.badCheck "two register fields claiming one bit are rejected", "TK-RE04"

  t.src """
register RCC at 0x40021000:
  ON: bit 0 [read, write]
  RDY: bit 1 [read]
  TRIM: bits 3..7 [read, write]

fn main() -> int:
  RCC ..ON {true}
  let r = RCC.RDY
  return 0
"""
  t.okCheck "a well-formed register reads and writes normally"

  t.finish()
