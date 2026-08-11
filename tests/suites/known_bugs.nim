## Regression tests for known bugs — both the ones still open and the ones
## already fixed.
##
## Each entry states the CORRECT behaviour as a real assertion, plus a marker
## saying whether the compiler does that yet:
##
##   bug_open  -> the bug is open. The suite reports it and expects the
##                assertion to fail. If it starts PASSING, the suite fails and
##                tells you to flip the marker: that is how a fix gets locked in.
##   bug_fixed -> the bug is fixed. The assertion is now a permanent regression
##                guard and fails like any normal test.
##
## So fixing a bug is a two-line change — fix it, flip the marker — and from
## then on the same assertion protects it forever. Nothing gets deleted, so a
## bug that returns is caught by the test written when it was first found.
##
## Converted from tests/known_bugs.nim, which already drove the tuck BINARY via
## execCmdEx — it was a Nim program purely for its harness, and paid a full
## compiler rebuild for the privilege.

import ../harness

proc run*(t: var T) =
  # 1. Integer division is `/i`, and it really is integer division.
  # Found 2026-07-22: `a /= 4` on an int lowered to Nim's `/`, which returns
  # float, so the emitted code did not compile. FIXED 2026-07-28 by ruling R1
  # rather than by patching the emitter: a bare `/` no longer exists, `/i` is
  # integer divide and `/f` is float divide. Nim spells integer divide `div` and
  # Odin spells it `/` — that divergence is why the source must say which.
  t.src """
fn main() -> int:
  var a = 10
  a /i= 4
  return a
"""
  t.quietly: t.frozen "'/i=' on ints uses integer division"
  t.bugFixed "'/i=' on ints uses integer division"

  # 2. `toStr` + string concatenation picked the numeric `+`. Two causes: an
  # UNQUALIFIED call to an imported fn never resolved a return type (only the
  # qualified key existed in fnSigs), and postfix application only recognized a
  # LITERAL receiver, so `n.toStr` was not treated as a call at all.
  t.src """
import str

fn main() -> int:
  let n = 3
  let s = n.toStr + " bottles"
  return 0
"""
  t.quietly: t.frozen "'toStr' result stays a str under '+'"
  t.bugFixed "'toStr' result stays a str under '+'"

  # 3. `if` has no expression form (ruling R2). Nim has a real if-expression;
  # Odin has none and gets its ternary.
  t.src """
fn main() -> int:
  let a = 5
  let x = if a > 0: 1 else: 2
  return x
"""
  t.quietly: t.okCheck ""
  t.bugFixed "'if' works as an expression"

  # 4. `[saturating]` clamps instead of wrapping. Was: no compile error, no
  # runtime trap, just a wrong value (70000 into a u16 became 4464). Root cause
  # was in the PARSER: `type X = u16 [saturating]` had its trailing attrs
  # clobbered by the pre-`=` ones, so the attribute never reached the backend.
  t.src """
type SafeRPM = u16 [saturating]

fn main() -> int:
  let s = 70000 SafeRPM
  if s == 65535 SafeRPM:
    return 1
  return 2
"""
  t.quietly: t.frozen "'[saturating]' clamps at the maximum"
  t.bugFixed "'[saturating]' clamps at the maximum"

  # 4b. A saturating chain clamps against the FINAL value. `a + b - c` (all
  # 60000) is 60000, which fits. Per-operator saturation would clamp a+b to
  # 65535 and yield 5535; the store-guard design clamps only where a value is
  # stored, so transient intermediates do not corrupt the result.
  t.src """
type SafeRPM = u16 [saturating]

fn main() -> int:
  let a = 60000 SafeRPM
  let b = 60000 SafeRPM
  let c = 60000 SafeRPM
  let r = a + b - c
  if r == 60000 SafeRPM:
    return 1
  return 2
"""
  t.quietly: t.frozen "saturating chain clamps on the result, not each operator"
  t.bugFixed "saturating chain clamps on the result, not each operator"

  # 4c. The Odin backend must clamp too: the same program wrapping on one
  # backend and clamping on the other is the divergence the parity commitment
  # exists to stop. The Odin RUNTIME had tuckSat all along — only the emitter
  # never called it. Assert the clamp is CALLED; "70000 is absent" would be
  # wrong, since it legitimately appears as the argument: rt.tuckSat(u16, ...).
  t.src """
type SafeRPM = u16 [saturating]

fn main() -> int:
  let s = 70000 SafeRPM
  return 0
"""
  t.quietly: t.emitsOdin "", "tuckSat\\(u16"
  t.bugFixed "Odin backend clamps [saturating] too"

  # 5. RULING 2026-08-06, not a bug: attribute names are RESERVED in bracket
  # position, and user type names must be Capitalized. `Box[T]` and
  # `u16 [saturating]` are the same shape, so the parser needs a rule. The
  # attribute set is CLOSED, so a word list was never incomplete — it was
  # AMBIGUOUS, since `error`/`sealed`/`stack` are all good type-parameter names.
  # Case resolves what no list can; the reserved list is the backstop.
  t.src """
type Box[T]:
  v: T

fn take({b: Box[error]}) -> int:
  return 0

fn main() -> int:
  return 0
"""
  t.badCheck "a reserved attribute name is not a type argument", "reserved attribute name"
  t.badCheck "...and the message says how to fix it", "Capitalized and unreserved"

  # The rename the message asks for.
  t.src """
type Box[T]:
  v: T

fn take({b: Box[Err]}) -> int:
  return 0

fn main() -> int:
  return 0
"""
  t.okCheck "a Capitalized, unreserved type argument is accepted"

  # A reserved word is still a legal FIELD name — a field position can never
  # hold an attribute, so the parser accepts it there and reads its value.
  t.src """
type Priority:
  | high
  | low

decision route({priority: Priority, encrypted: bool}) -> int:
  | high  true  -> 1
  | _     _     -> 2

fn main() -> int:
  return {priority: Priority.low, encrypted: false} route
"""
  t.frozen "a reserved word is still a legal field name"

  # And the attribute reading still wins where it must, in the same file shape
  # the corpus uses everywhere.
  t.src """
type SafeRPM = u16 [saturating]

fn main() -> int:
  let s = 70000 SafeRPM
  if s == 65535 SafeRPM:
    return 1
  return 2
"""
  t.frozen "an attribute bracket is still an attribute"

  # A bare marker is a RESERVED WORD now, so it cannot be an ordinary name.
  t.src """
fn main() -> int:
  let sealed = 1
  return sealed
"""
  t.badCheck "a reserved marker cannot be a variable name", "."

  # 5b. The capitalization half of the same ruling. Enforced at DECLARATION, so
  # the error lands where the name is chosen. The corpus already followed this
  # everywhere — one mixin in example 04 was the only violation.
  t.src """
type box[T]:
  v: T

fn main() -> int:
  return 0
"""
  t.badCheck "a lowercase type name is rejected", "must be Capitalized"

  t.src """
object dog:
  name: str

fn main() -> int:
  return 0
"""
  t.badCheck "a lowercase object name is rejected", "must be Capitalized"

  t.src """
mixin helpers:
  fn double({self: Self}) -> int:
    return 1

fn main() -> int:
  return 0
"""
  t.badCheck "a lowercase mixin name is rejected", "must be Capitalized"

  # Primitives stay lowercase — they are a closed set, not user declarations.
  t.src """
type Box[T]:
  v: T

fn take({b: Box[u8]}) -> int:
  return 0

fn main() -> int:
  return 0
"""
  t.okCheck "a primitive is still a legal type argument"

  # 7. Block-bodied match arms indent correctly. Was blocking example 20: the
  # arm emitter hardcoded `"  of "` and `"\n    "` as if the case sat at column
  # 0, while a block body self-indents from ctx.indent.
  # 7b. ...and a tail match whose arms RETURN is not re-wrapped: injectTailReturn
  # assumed a trailing match always had value arms, so it emitted
  # `return (case ...)` over branches that never yield a value.
  t.src """
type Light:
  | Red
  | Green

fn describe({l: Light}) -> int:
  match l:
    Red:
      let a = 1
      return a
    Green:
      let b = 2
      return b

fn main() -> int:
  return {l: Light.Green} describe
"""
  t.quietly: t.frozen "block-bodied match arms indent correctly"
  t.bugFixed "block-bodied match arms indent correctly"
  t.quietly: t.frozen "tail match with returning arms is not double-wrapped"
  t.bugFixed "tail match with returning arms is not double-wrapped"

  # 8. `.fn {args}` on an UNDECLARED fn emitted a bare field access —
  # `buf.copyFrom {data}` became `self.buf.copyFrom`, dropping the argument
  # entirely. Ruling 2026-07-23: a brace after `.name` is ALWAYS a call, so an
  # undeclared callee is a clean checker error, not a silent field read.
  t.src """
actor Driver [queue: 8]:
  buf: Seq[u8]

  on send({data: Seq[u8]}) -> void:
    buf.copyFrom {data}

fn main() -> int:
  return 0
"""
  t.quietly: t.badCheck "", "copyFrom"
  t.bugFixed "'.fn {args}' on an undeclared fn is reported, not silently a field read"

  # 9. An early-return guard narrows a result. The checker recognised only
  # `if r.ok:`. `if not r.ok: return` proves presence for everything after it
  # just as well, and is the flat form the spec itself uses (7.2's pool
  # example) — but reading .value after it was rejected. Affects !T and ?T alike.
  t.src """
fn readIt({n: int}) -> !{v: int} [io]:
  return {v: n}

fn main() -> int [io]:
  let r = {n: 5} readIt
  if not r.ok:
    return 0
  return r.value.v
"""
  t.quietly: t.frozen "early-return guard narrows a result"
  t.bugFixed "early-return guard narrows a result"

  # 10. `elif` was lexed but never parsed. tkElif was in the lexer's keyword
  # table from the start, but parseExpr's if-branch only looked for tkElse, so a
  # natural `elif` chain died with "Expected expression but got: tkElif". Found
  # by the rosetta corpus, where two independent authors reached for elif
  # writing ordinary grading/guard code. Fix: `elif C: B` parses as
  # `else: (if C: B)` — pure sugar, so no AST/checker/codegen change was needed.
  t.src """
fn classify({n: int}) -> int:
  if n < 0:
    return 0
  elif n == 0:
    return 1
  elif n < 10:
    return 2
  else:
    return 3

fn main() -> int:
  return {n: 5} classify
"""
  t.quietly: t.frozen "elif chains parse"
  t.bugFixed "elif chains parse"

  # 11. An overflow attribute implies `distinct` on the Nim backend but not on
  # Odin. codegen.nim's genAliasType treats distinct/saturating/wrapping/trapping
  # alike — the ATTRIBUTE is what changes behaviour, and it is meaningless on a
  # bare alias. codegen_odin.nim's genAliasType matches only "distinct", so
  # `u16 [saturating]` emits `SafeRPM :: u16`: a plain alias, freely mixable with
  # any other u16, where Nim gives a type the compiler keeps separate.
  # The clamping itself is right on both (tuckSat is emitted either way); what
  # Odin loses is the type distinction.
  t.src """
type SafeRPM = u16 [saturating]

fn main() -> int:
  let s = 70000 SafeRPM
  return 0
"""
  t.quietly: t.emitsOdin "", "SafeRPM :: distinct u16"
  t.bugFixed "an overflow attribute implies distinct on the Odin backend too"

  # 12. `on select` actors emit Odin that does not compile. genActor collects
  # message variants from `h.kind == dkFn` only, but an `on select` arm is not a
  # dkFn, so enumVariants comes back EMPTY and the no-handler fallback fires:
  # no message enum, no mailbox, no handleMsg, and a drain that is a bare
  # `for { coroYield() }` spin. Meanwhile the send sites still emit calls to
  # sendAdd_<Actor>, which nothing defines — `odin build` fails with
  # "Undeclared name: sendAdd_tuck_Accumulator".
  #
  # The Nim backend handles this: collectHandlers walks BOTH `on <name>` blocks
  # and `on select` arms. 27-actor-select is absent from odin_backend.sh's
  # odin_compile list, which is why this never surfaced there.
  t.src """
actor Accumulator [queue: 64]:
  total: int = 0

  on select:
    | add -> {n: int}:  total += n

fn main() -> int:
  Accumulator send add {n: 1}
  return 0
"""
  t.quietly: t.emitsOdin "", "sendAdd_tuck_Accumulator :: proc"
  t.bugFixed "an 'on select' actor emits its send procs on the Odin backend"

  # 13. A `-> void` task could not be fire-and-forget. The spawn wrapper always
  # emitted `discard <call>`, so a task returning nothing produced
  # `discard tuck_fire()` over a void proc — "expression has no type (or is
  # ambiguous)". The most natural fire-and-forget task was the one shape that
  # did not compile; found while writing the std/net example, which had to give
  # its tasks a `{n: int}` return they did not want.
  t.src """
import scheduler

actor Sink [queue: 8]:
  hits: int = 0
  on ping({n: int}):
    hits += n

task fire() -> void [io]:
  Sink send ping {n: 5}
  return

fn done() -> bool:
  return Sink.hits == 5

fn main() -> int [io]:
  {} fire
  scheduler::waitUntil {pred: :done}
  {} scheduler::stop
  return Sink.hits
"""
  t.quietly: t.frozen "a -> void task can be fire-and-forget"
  t.bugFixed "a -> void task can be fire-and-forget"

  # 14. Constructing a type with MISSING required fields is silently accepted.
  # `{fields} TypeName` construction (typecheck.nim, the branch that returns
  # early once the callee resolves to a known type/object name) never checks
  # the supplied field set against the type's DECLARED fields — only the
  # function-CALL path does that ("missing required field '...'"). Found while
  # auditing spec §4.8 against a 2026-07-09 ruling ("types with fields require
  # every field at construction; absence must be explicit ?T") that was never
  # wired into the checker, or regressed since. `{}` with zero fields supplied
  # against a two-required-int-field type passes `tuck ch` with no diagnostic
  # at all — the missing fields are whatever the backend zero-inits them to.
  t.src """
type Config:
  port: int
  timeout: int

fn main() -> int:
  let c = {} Config
  return 0
"""
  t.quietly: t.badCheck "constructing a type with missing required fields is rejected", "missing\\ required\\ field"
  t.bugOpen "constructing a type with missing required fields is rejected"

  # 15. An `on select` arm shape the emitter does not recognise silently
  # compiles to a no-op `discard` — the entire handler body is dropped, with NO
  # compile error, NO warning, not even a PENDING report entry. Root cause:
  # codegen.nim's select lowering only handles a plain `read <fd>` / `timeout
  # <ms>` pair; anything else (including this program, which is close to spec
  # §9.3's OWN worked example) falls through to a bare `discard` with a code
  # comment as the only trace. Typed select sources (`timeout.5s`) are tracked
  # as missing (G3) but the SILENCE is the worse half of the gap: a program that
  # looks correct and compiles clean does nothing at the deadline.
  t.src """
task handleConn({conn: int}) -> void:
  on select:
    | timeout.5s -> {}: return

fn main() -> int:
  return 0
"""
  t.quietly: t.omits "an unrecognised 'on select' arm does not silently discard its body", "only read.timeout arms supported"
  t.bugOpen "an unrecognised 'on select' arm does not silently discard its body"

  # 16. `alias(...)` never checks the RESULT for field-name collisions — neither
  # against the receiver's own untouched fields, nor between two renamed-to
  # targets. `ext alias(trackId: title, category: title)` (two sources renamed
  # to the SAME target) type-checks clean today AND emits a Nim tuple literal
  # with the field 'title' written twice, which `nim check` rejects outright
  # ("field initialized twice: 'title'") — exactly the class of bug
  # tests/suites/duplicates.nim's failIfComposedCollision exists to catch for `+`
  # composition (spec §2.5), just not reached here because alias() is a
  # different code path. `tuck ch` gives no hint that anything is wrong; the
  # correct behaviour is a checker error naming the collision, same spirit as
  # failIfComposedCollision's "contributed twice" message.
  t.src """
fn main() -> int:
  let ext = {trackId: 42, category: 7}
  let normalized = ext alias(trackId: title, category: title)
  return 0
"""
  t.quietly: t.badCheck "alias() rejects two renamed fields colliding on the same target name", "twice|collis|already|duplicate"
  t.bugOpen "alias() rejects two renamed fields colliding on the same target name"

  # 17. A QUALIFIED mutator in a `..` chain emits garbage. `cfg ..mod::fn`
  # drops the call entirely and applies the NEXT chain step to the function
  # instead of the receiver:
  #
  #     cfg ..bigmod::withDefaults ..f1 {60}   ->   tuck_withDefaults.f1 = 60
  #
  # The unqualified form (`cfg ..withDefaults`, which works because imported
  # fns are visible unqualified) lowers correctly to
  # `cfg = tuck_withDefaults(cfg)`, so this is specific to the `mod::fn`
  # spelling in chain-step position. It fails loudly one stage later — Nim
  # rejects a field assignment on a proc — but `tuck ch` reports nothing, so
  # the diagnostic the user sees is about emitted code they never wrote,
  # which is exactly what the checker exists to prevent.
  #
  # Either fix is acceptable: lower it like the unqualified form, or reject a
  # qualified name in chain-step position at check time. Whichever lands,
  # flip this marker and point the assertion at the behaviour chosen.
  t.src """
import bigmod

fn main() -> int:
  var cfg = {f0: 1, f1: 2} Big
  cfg ..bigmod::withDefaults ..f1 {60}
  return cfg.f0
"""
  t.addFile("bigmod.tuck", """type Big:
  f0: int
  f1: int

fn withDefaults({self: Big}) -> Big:
  var s = self
  s ..f0 {80}
  return s
""")
  t.quietly: t.omits "a qualified mutator in a chain does not emit a field-set on the function", "tuck_withDefaults\\.f"
  t.bugOpen "a qualified mutator in a chain does not emit a field-set on the function"

  # 18. Odin: an imported TYPE is emitted unqualified, so it does not resolve.
  # The emitter qualifies an imported FN correctly
  # (`bigmod.tuck_withDefaults(cfg)`) but writes the type from the same module
  # bare — `cfg := tuck_Big{...}` — and Odin answers `Undeclared name:
  # tuck_Big`, so any program whose type comes from another module fails to
  # build on that backend.
  #
  # Nim is unaffected: its own `import` brings the name into scope
  # unqualified, which is exactly the assumption baked into the shared
  # emitter path. Odin's `import bigmod "./mod_bigmod"` does not, so the
  # package name has to be written.
  t.src """
import bigmod

fn main() -> int:
  var cfg = {f0: 1} Big
  return cfg.f0
"""
  t.addFile("bigmod.tuck", """type Big:
  f0: int
""")
  t.quietly: t.emitsOdin "an imported type is qualified with its package on Odin", "bigmod\\.tuck_Big"
  t.bugOpen "an imported type is qualified with its package on Odin"

  t.finish()
