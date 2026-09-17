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

  # A `.field` access on a register is not an ordinary field: the register
  # is a raw pointer, so it has none. genRegister/genDRegister already
  # generate real `<reg>_<field>_get`/`_set` accessors doing the mask/shift
  # math — the bug was that Odin/D field
  # ACCESS SITES never called them, and emitted raw `.field` syntax instead
  # (confirmed directly: `'DAC_CR' of type '^u32' has no field 'EN'`
  # building example 20's own Odin output). No `runs` check here: a
  # register's address is real MMIO hardware, unsafe to dereference on a
  # test machine — codegen-shape coverage is what a raw pointer's semantics
  # allow.
  t.src """
register CTRL at 0x40007400:
  EN: bit 0 [read, write]
  MODE: bits 3..5 [read, write]

fn main() -> int:
  CTRL ..EN {true}
  let en = CTRL.EN
  CTRL ..MODE {5}
  let m = CTRL.MODE
  return 0
"""
  t.emitsOdin "register: a chain-mutate write calls the generated setter",
              r"tuck_CTRL_EN_set\(true\)"
  t.emitsOdin "register: a plain read calls the generated getter",
              r"tuck_CTRL_EN_get\(\)"
  t.omitsOdin "register: never raw field syntax on the pointer",
              r"CTRL\.EN"
  t.emitsD "register: a chain-mutate write calls the generated setter",
           r"tuck_CTRL_EN_set\(true\)"
  t.emitsD "register: a plain read calls the generated getter",
           r"tuck_CTRL_EN_get\(\)"
  t.omitsD "register: never raw field syntax on the pointer",
           r"CTRL\.EN"
  # NIM HAD NO ASSERTIONS HERE, which is exactly how it stayed broken: it
  # emitted a `registerMMIO` macro call whose generated procs did not match
  # the field access codegen emitted, so every register read and write failed
  # with "undeclared field". Ruling 2026-09-12: drop the macro, emit ordinary
  # code like the other two. `hostBuilds` is the half that matters — the
  # macro version EMITTED fine and only failed when nim compiled the result,
  # and no register example has an `fn main`, so nothing ever compiled one.
  t.emits "register: Nim calls the generated setter too",
          r"tuck_CTRL_EN_set\(true\)"
  t.emits "register: Nim calls the generated getter too",
          r"tuck_CTRL_EN_get\(\)"
  t.omits "register: Nim never emits raw field syntax either", r"CTRL\.EN"
  t.hostBuilds "register: every backend's host compiler accepts the accessors"

  # An event registry whose event carries a PAYLOAD. Two defects lived here,
  # both invisible for the same reason as the register ones: no registry
  # example has an `fn main`, so `tuck build` was a library build that never
  # handed the emitted Nim to nim.
  #   1. the generated type indented `kind*` by four spaces and its payload
  #      fields by two — "invalid indentation", so it never compiled at all
  #   2. handler procs were forward-declared a SECOND time by the registry,
  #      on top of the file's own forward-declaration block. A proc declared
  #      twice is what the emitted file's `codeReordering` pragma rejects:
  #      "implementation of X expected", with the implementation right there
  #      further down
  t.src """
registry SystemEvents:
  | PlaybackStarted()
  | HardwareError({code: u8})

on SystemEvents.PlaybackStarted():
  let a = 1

on SystemEvents.HardwareError({code: u8}):
  let b = code

fn main() -> int:
  return 0
"""
  t.okCheck "a registry with a payload-carrying event checks"
  # `tuckTag`, not `kind`: the registry type flattens every event's payload
  # fields in beside its discriminator, so an event payload named `kind` used
  # to emit the field twice. Codegen's own name moved; see codegen_common.
  t.emits "the registry type indents every field alike", r"\n  tuckTag\*: "
  # The duplicate forward declaration has no emitted-text assertion: what
  # made it a defect is that nim REFUSES it, so hostBuilds below is the guard
  # that actually holds — and is the one this whole family was missing.
  t.hostBuilds "...and every backend's host compiler accepts it"
  t.runs "...and it runs", 0

  # An early `return` inside a FALLIBLE TASK. genDFnDecl set the D backend's
  # return context (retWrapped/retInnerD) and genDTaskDecl did not, so a bare
  # return in a `task ... -> !void` emitted `return;` from a function typed
  # rt.TuckResult — "`return` expression expected". Nim and Odin accepted the
  # same shape, which is why only D ever said so.
  t.src """
pool BufferPool = Array[512, u8] [count: 2]

task streamReader({streamId: u8, chunks: Seq[u32]}) -> !void [io]:
  for i in chunks:
    let buf = BufferPool.acquire
    if not buf.ok:
      return
    BufferPool.release {buf.value}

fn main() -> int:
  return 0
"""
  t.okCheck "an early return inside a fallible task checks"
  t.emitsD "D wraps it in the carrier rather than returning nothing",
           r"return rt\.tokVoid\(\)"
  t.hostBuilds "...and every backend's host compiler accepts it"
  t.runs "...and it runs", 0

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

  # --- pools and arenas, §7.2 / §7.3 (TK-TY03, TK-ME01) --------------------
  #
  # Both exist so the footprint is STATIC, which makes the numbers part of the
  # declaration's meaning rather than decoration. A pool over an undeclared
  # type used to reach Nim as a spell suggestion about generated code.

  t.src """
pool P = NoSuchType [count: 4]

fn main() -> int:
  return 0
"""
  t.badCheck "a pool over an undeclared element type is rejected", "TK-TY03"

  t.src """
arena A [size: 0]:
  discard

fn main() -> int:
  return 0
"""
  t.badCheck "an arena of size 0 is rejected", "TK-ME01"

  t.src """
type Conn:
  fd: int

pool P = Conn [count: 4]

fn main() -> int:
  return 0
"""
  t.okCheck "a pool over a declared record is accepted"

  # A primitive element type is not in typeDecls (primitives are a closed set
  # the backends know), so the rule keys on Capitalization — this case is why.
  t.src """
pool P = Array[64, u8] [count: 8]

fn main() -> int:
  return 0
"""
  t.okCheck "a pool over a primitive array is accepted"

  t.src """
arena A [size: 2048]:
  discard

fn main() -> int:
  return 0
"""
  t.okCheck "an arena with a real size is accepted"

  # --- a type may not contain itself by value -------------------------------
  #
  # Was caught only by the BACKEND, in the backend's words: `tuck ch` passed,
  # then Nim said `illegal recursion in type 'tuck_Expr'` — a mangled name in
  # a generated file. (FRICTIONS #4.)
  #
  # A recursive SUM is no longer among them, as of the recursive-types work:
  # its variants end the chain, so it is finite once its edges are handles,
  # and lowering_recursive makes them handles. This assertion said "rejected"
  # and is kept, inverted, rather than deleted — the behaviour it pinned is
  # exactly what changed. `tests/suites/recursive_types.nim` carries the
  # positive cases end to end.

  t.src """
type Expr:
  | Lit({v: int})
  | Add({lhs: Expr, rhs: Expr})

fn main() -> int:
  return 0
"""
  t.okCheck "a sum variant containing its own type is ACCEPTED (was rejected)"

  t.src """
type Cell = {next: Cell, v: int}

fn main() -> int:
  return 0
"""
  t.badCheck "a record field of its own type is rejected too", "field 'next'"

  # Array is INLINE storage — N values, not a handle — so it does not break
  # the cycle. Verified by building before the check existed.
  t.src """
type Tree:
  | Leaf({v: int})
  | Node({kids: Array[4, Tree]})

fn main() -> int:
  return 0
"""
  t.badCheck "Array does not break a containment cycle", "contains itself"

  # An indirect cycle names the ROUTE, not a field that stores something else.
  t.src """
type Inner = {back: Outer, n: int}
type Outer = {mid: Inner}

fn main() -> int:
  return 0
"""
  t.badCheck "an indirect cycle reports the route it takes",
             "Inner -> Outer -> Inner"

  # THE ESCAPE HATCH. A Seq is a growable handle, so this is finite and must
  # keep building — it is how the corpus writes trees.
  t.src """
type Node:
  | Leaf({v: int})
  | Branch({kids: Seq[Node]})

fn main() -> int:
  return 0
"""
  t.okCheck "recursion through Seq stays legal"

  # --- effect markers are reported the way they are SPELLED -----------------
  #
  # Two sites derived the name from the enum mechanically, which drops the
  # underscore: `[may_block]` was reported as `[mayblock]`, a word that is not
  # in the language, so a reader could not search for it.

  t.src """
fn slow({n: int}) -> int [may_block]:
  return n

fn handler({n: int}) -> int [irq_safe]:
  return {n: n} slow

fn main() -> int:
  return 0
"""
  t.badCheck "an irq_safe fn may not call a may_block one", "may_block"

  t.src """
fn slow({n: int}) -> int [may_block]:
  return n

fn middle({n: int}) -> int:
  return {n: n} slow

fn main() -> int:
  return 0
"""
  t.badCheck "the obligation propagates to an undeclared caller",
             "requires effect \\[may_block\\]"

  t.src """
fn slow({n: int}) -> int [may_block]:
  return n

fn middle({n: int}) -> int [may_block]:
  return {n: n} slow

fn main() -> int:
  return 0
"""
  t.okCheck "declaring the effect satisfies the budget"

  # Mutually recursive types THROUGH `Seq` are finite and legal — a Seq is a
  # handle. Nim resolves mutual type references only within ONE `type` block
  # and each emit site writes its own, so this failed with
  # `undeclared identifier: 'tuck_B'`. Odin and D always resolved module-wide.
  t.src """
type A = {b: Seq[B]}
type B = {a: Seq[A]}

fn main() -> int:
  return 0
"""
  t.runs "mutually recursive types through Seq build", 0

  # An actor may be generic (spec 9.1, ruled 2026-09-13): the type parameter is
  # forwarded to the actor's own fields, so an actor whose machinery says
  # nothing about what it carries is written once and reused per element type.
  # Ruled again 2026-09-17 on the half that was missing — an actor is a
  # compile-time singleton, so what BINDS the parameter is one singleton per
  # instantiation: `Box[int]` and `Box[str]` are two actors with two mailboxes
  # (#18). That machinery is not built, so the checker refuses the parameter
  # for now rather than dropping it — dropping is what emitted `last*: T` with
  # T declared nowhere.
  #
  # These two assert the PARSE, which is what they were always for: type params
  # come BEFORE attributes, the same order and the same two procs `type Name[T]
  # [attrs]` uses — both are bracket groups, told apart by case. parseDeclAttrs
  # used to eat the FIRST group whatever it was, so `actor Box[T]:` parsed with
  # T recorded as an ATTRIBUTE (it looked supported and meant nothing) and
  # `actor Box[T] [queue: 4]` failed with "Expected `Colon` here, found `[`".
  # Reaching a TYPE error is itself proof the parse got that far — a parse
  # failure would report as one.
  t.src """
actor Box[T] [queue: 4]:
  n: int = 0

  on go():
    n = 1

fn main() -> int:
  return 0
"""
  t.badCheck "an actor takes type params AND attributes", "TK-TY28"

  t.src """
actor Box[T]:
  n: int = 0

  on go():
    n = 1

fn main() -> int:
  return 0
"""
  t.badCheck "...type params alone", "TK-TY28"

  t.src """
actor Box [queue: 4]:
  n: int = 0

  on go():
    n = 1

fn main() -> int:
  return 0
"""
  t.okCheck "...attributes alone"

  t.src """
actor Box:
  n: int = 0

  on go():
    n = 1

fn main() -> int:
  return 0
"""
  t.okCheck "...and neither"

  # A generic actor PARSES (that much is #18's own finding), and used to
  # typecheck clean and then emit `last*: T` with T declared nowhere — so the
  # author's mistake surfaced as the HOST compiler's "undeclared identifier:
  # 'T'", in generated code they never wrote. The type parameter was recorded
  # by the parser and read by nothing but the Array-size check.
  #
  # An actor is a compile-time singleton, so the parameter needs a binding
  # rule. The ruling is one singleton per instantiation — `Box[int]` and
  # `Box[str]` as two actors, two mailboxes, two drains — which is not built.
  # Until it is, this is refused rather than dropped.
  t.src """
actor Box[T] [queue: 4]:
  last: T

  on put({v: T}):
    last = v

fn main() -> int:
  return 0
"""
  t.badCheck "a generic actor USING its parameter is refused too", "TK-TY28"

  # --- `...`, the unwritten body ------------------------------------------
  #
  # `...` used to emit a bare `discard`, so a fn declared `-> int` RETURNED A
  # SILENT ZERO — a plausible wrong answer indistinguishable from a computed
  # one, with nothing said at build time or at run time. Meanwhile `pending:`
  # already did the job properly. Two mechanisms meant "not implemented" and
  # only one of them said so out loud; `...` is now the inline spelling of the
  # other (ast_query.markUnimplemented).
  t.src """
fn half({n: int}) -> int:
  ...

fn main() -> int:
  return {n: 10} half
"""
  t.emits "an unwritten `-> int` body announces itself instead of returning 0",
          "TUCK PENDING"
  t.omits "...and does not fall through to a bare `discard`", "= 0"
  t.hostRuns "...on every backend", 0, "TUCK PENDING: tuck_half"

  # An actor body is not a fn body: there is no return value to stub and no
  # PENDING entry to make, so `...` there stays the no-op it always was.
  # (examples/15 declares exactly this.)
  t.src """
actor UartDriver [queue: 8]:
  ...

fn main() -> int:
  return 4
"""
  t.okCheck "`...` as an ACTOR body stays a plain no-op"
  t.omits "...with no PENDING entry, since an actor has no return value",
          "TUCK PENDING"
  # #61: the entry point registered EVERY dkActor, while genActor defines
  # registerActor<Name> only for an actor that has something to receive — so a
  # handler-less one emitted a call to a symbol nobody declared. D already had
  # the right query (actorHasMessages) and its own comment said both sites must
  # ask it; the query now lives in codegen_common and all three backends do.
  t.runs "a handler-less actor builds", 4
  t.hostRuns "...on every backend", 4
  t.bugFixed "a handler-less actor builds"

  # A `self` member keeps the old empty body: every backend's pending stub is
  # a free generic `(payload: T)`, which would drop both the receiver and the
  # owning type's name from the emitted symbol.
  t.src """
mixin Bulk:
  fn setMany(self, {n: int}) -> void:
    ...

fn main() -> int:
  return 5
"""
  t.omits "a `self` member is NOT turned into a free pending stub",
          "TUCK PENDING"
  t.hostRuns "...and still builds", 5

  t.finish()
