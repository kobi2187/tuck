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
  Sink.waitUntil {pred: :done}
  {} scheduler::stop
  return Sink.hits
"""
  t.quietly: t.frozen "a -> void task can be fire-and-forget"
  t.bugFixed "a -> void task can be fire-and-forget"

  # 14. FIXED 2026-08-14, but NOT as this entry originally demanded — the
  # ruling it was pinned against was re-ruled instead.
  #
  # The bug: `{fields} TypeName` construction never checked the supplied field
  # set against the DECLARED fields, so a missing field became whatever the
  # backend zero-inits. Pinned against the 2026-07-09 ruling "types with
  # fields require every field at construction".
  #
  # Enforcing that literally would have rejected the builder pattern —
  # construct partial, fill by chain, then read — which works and is worth
  # keeping. So construction stays legal and the UNSUPPLIED FIELD carries a
  # compile-time `<uninit>` marker instead: reading it is the error, assigning
  # it clears it, never reading it is fine. See ROADMAP.md (RE-RULED) and
  # tests/suites/uninit.nim for the full rule set.
  #
  # The original snippet — `{} Config` with the field never read — is now
  # CORRECT and compiles. The assertion moved to the read, which is where the
  # defect always actually bit.
  t.src """
type Config:
  port: int
  timeout: int

fn main() -> int:
  let c = {} Config
  return c.timeout
"""
  t.quietly: t.badCheck "reading a field the construction skipped is rejected", "uninit"
  t.bugFixed "reading a field the construction skipped is rejected"

  # 15. FIXED. An `on select` arm shape the emitter did not recognise silently
  # compiled to a no-op `discard` — the entire handler body dropped, with NO
  # compile error, NO warning, not even a PENDING report entry. codegen's
  # select lowering handled only a plain `read <fd>` / `timeout <ms>` pair;
  # anything else (including this program, close to spec §9.3's OWN worked
  # example) fell through to a bare `discard` with a code comment as the only
  # trace. A program that looks correct, compiles clean and does nothing at
  # the deadline is the worst outcome available.
  #
  # Two defects sat here and only ONE is fixed. Typed select sources
  # (`timeout.5s`) remain unlowered — that is G3, an unbuilt feature, and
  # being unbuilt is acceptable. The SILENCE was the bug, and it is gone: the
  # CHECKER now refuses any arm the backends cannot lower
  # (typecheck.nim failIfUnlowerableArm), so `tuck ch` reports it rather than
  # the user discovering it at runtime.
  #
  # Rejection lives in the checker, not codegen, for two reasons: codegen has
  # no failure path at all (by the time you reach it the program is supposed
  # to be valid), and an error raised there would never surface from `tuck ch`
  # — the user would still see OK, then get a surprise one stage later.
  #
  # The string compares that caused it are gone too. The parser concatenates a
  # dotted source into one opaque string, so `arm.source == "timeout"` never
  # matched `timeout.5s`. Arms are now classified once into SelectSourceKind
  # (ast_query.sourceKind) and matched EXHAUSTIVELY, so a new source kind
  # cannot be added without deciding whether it can be lowered.
  #
  # The assertion is badCheck, not omits: the program no longer reaches
  # emission at all, which is the point.
  t.src """
task handleConn({conn: int}) -> void:
  on select:
    | timeout.5s -> {}: return

fn main() -> int:
  return 0
"""
  t.quietly: t.badCheck "an unrecognised 'on select' arm does not silently discard its body", "not yet lowered|unsupported .on select"
  t.bugFixed "an unrecognised 'on select' arm does not silently discard its body"

  # 16. FIXED. `alias(...)` never checked its RESULT for field-name
  # collisions: `ext alias(trackId: title, category: title)` (two sources
  # renamed to the SAME target) type-checked clean AND emitted a Nim tuple
  # with 'title' written twice, which `nim check` rejects outright ("field
  # initialized twice") — a diagnostic about generated code the user never
  # wrote.
  #
  # The guard already existed: failIfDuplicateField, used by asMergeCall
  # twenty lines below asAliasCall — and defined AFTER it, so alias could not
  # see it without a forward declaration. That ordering accident is the most
  # likely reason it was never applied. Fix: the guard moved above both, took
  # `op`/`source` params so each caller keeps an accurate message, and every
  # path that BUILDS a field set now routes additions through it. `+`
  # composition keeps its own failIfComposedCollision (spec §2.5).
  #
  # The message says "duplicate", not "collides": this pin's pattern is
  # /twice|collis|already|duplicate/, and "collides" matches NONE of those —
  # `collis` is a prefix of "collision", not of "collides". Merge's old
  # wording had the same hole and was never caught because no pin ran against
  # it.
  t.src """
fn main() -> int:
  let ext = {trackId: 42, category: 7}
  let normalized = ext alias(trackId: title, category: title)
  return 0
"""
  t.quietly: t.badCheck "alias() rejects two renamed fields colliding on the same target name", "twice|collis|already|duplicate"
  t.bugFixed "alias() rejects two renamed fields colliding on the same target name"

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
  t.bugFixed "a qualified mutator in a chain does not emit a field-set on the function"
  # FIXED 2026-09-12, exactly where the entry said it had to be — parse time.
  # `..mod::fn` was parsed as a `..` step whose target was the bare `mod`,
  # after which the chain loop saw `::` and handed chainQualified the WHOLE
  # CHAIN. That failed its `exkVar` test, so the module name became "" and it
  # returned a fresh node, discarding the receiver. The `::` belongs to the
  # step's target, so chainMutation reads it there; chainQualified now
  # refuses a non-name left side instead of rebuilding from an empty module.
  t.emits "...it calls the qualified mutator and threads the receiver",
          r"bigmod\.tuck_withDefaults\(tuck_cfg\)"

  # 18. FIXED. Odin: an imported TYPE was emitted unqualified, so it did not
  # resolve. The emitter qualified an imported FN correctly
  # (`bigmod.tuck_withDefaults(cfg)`) but wrote the type from the same module
  # bare — `cfg := tuck_Big{...}` — and Odin answered `Undeclared name:
  # tuck_Big`, so any program whose type came from another module failed to
  # build on that backend.
  #
  # Nim is unaffected: its own `import` brings the name into scope
  # unqualified, which is exactly the assumption baked into the shared
  # emitter path. Odin's `import bigmod "./mod_bigmod"` does not, so the
  # package name has to be written.
  #
  # Root cause: a construction reaches text through `e.callee.name` in
  # genRecordCtor -> genericCtorName, which never passed through odinType and
  # so never met importedTypeQualifier. Fix: qualify the base name there.
  #
  # This ALSO restored the missing `import bigmod "./mod_bigmod"` line, which
  # was absent entirely. Import emission is gated on a substring search for
  # `pkg & "."` over the generated body (codegen_odin.nim ~2394), so the
  # missing qualification suppressed the import as well — one fault, two
  # symptoms. Verified with a real `odin build`, not just this text
  # assertion: before, `Undeclared name: tuck_Big`; after, it compiles, links
  # and runs.
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
  t.bugFixed "an imported type is qualified with its package on Odin"

  # 19. A fn could write through its own parameter to the CALLER's record.
  # The checker bound every param mutable ("`set` functions legitimately use
  # `..` on them" — for a `set` prefix that was never implemented and has
  # since been dropped), so codegen emitted `var T` for record params. In Nim
  # `var` on a PARAMETER is not write permission, it is a by-reference pass,
  # so this returned 70 instead of 100:
  #
  #   fn afterFee({acct: Account, fee: int}) -> int:
  #     acct ..balance {acct.balance - fee}   # spends the caller's money
  #
  # It was also a backend divergence: codegen_odin.nim always passed records
  # by value, so Odin rejected the same program outright ("Cannot assign to
  # 'acct.balance' which is a procedure parameter") while Nim silently
  # miscomputed. Ruling 2026-08-12: a parameter is an immutable binding of a
  # value (spec §7.1); `self` in an object member and an actor's own fields
  # stay mutable, because those are state the callee owns.
  #
  # Fixed by giving Binding an `isParam` flag, rejecting `..` on it with
  # TK-TY15, and dropping `var` from emitted record params. Free at the
  # machine level: the emitted C signature is byte-identical either way
  # (both `Big*`). tests/suites/value_semantics.nim holds the full guarantee.
  t.src """
type Account:
  balance: int

fn afterFee({acct: Account, fee: int}) -> int:
  acct ..balance {acct.balance - fee}
  return acct.balance

fn main() -> int:
  var savings = {balance: 100} Account
  let preview = {acct: savings, fee: 30} afterFee
  return savings.balance
"""
  t.quietly: t.badCheck "a fn cannot mutate its caller's record through a parameter", "TK-TY15"
  t.bugFixed "a fn cannot mutate its caller's record through a parameter"

  # A task body is LOWERED like any other body.
  # Found 2026-08-15 while removing `else: discard`. lowerModule walked
  # `allFns()` and top-level `dkExpr` and nothing else — but a task keeps its
  # body in `taskBody`, an Expr rather than a member Decl, so `allFns` (which
  # reaches nested fns via `members()`) never sees it. Every lowering therefore
  # skipped task bodies: a registry raise inside a task kept its pre-lowering
  # shape and emitted `LowMemory(tuck_AppEvents.raise)(42)`, which is not valid
  # Nim. In a plain fn the same line lowered to `raise_tuck_AppEvents_LowMemory`.
  #
  # rewriteModule had already hit this and walks dkTask separately; its comment
  # named lowerModule as having the same gap, and it stayed open. Fixed by
  # giving lowerModule the same third loop.
  t.src """
registry AppEvents:
  | LowMemory({remaining: u32})

task monitor():
  AppEvents.raise LowMemory {remaining: 42}

on AppEvents.LowMemory({remaining: u32}):
  let left = remaining

fn main() -> int:
  return 0
"""
  t.quietly: t.emits("a registry raise in a task body is lowered",
                     r"raise_tuck_AppEvents_LowMemory\(42\)")
  t.bugFixed "a registry raise in a task body is lowered"

  # A PAYLOAD-FREE registry raise emitted swapped, nonsensical code.
  # Found 2026-09-01 chasing example 20: `Registry.raise Event` (no
  # payload) parses to a DIFFERENT, single-level exkCall shape than
  # `Registry.raise Event {payload}` does (the shape the fix above
  # already covered) — flattenRegistryRaise's guard only ever matched the
  # with-payload shape, so a payload-free raise fell through untouched and
  # codegen read the event name as the CALLEE and `Registry.raise` as its
  # one argument: `PlaybackStarted(tuck_SystemEvents.raise)`. Nim's own
  # `discard` keyword-coincidence trick that masked other bugs this
  # session did NOT apply here — this one was broken on all three
  # backends identically, since lowering is shared.
  t.src """
registry Sys:
  | Started

on Sys.Started():
  discard

fn main() -> int:
  Sys.raise Started
  return 0
"""
  t.quietly: t.emits("a payload-free registry raise is lowered",
                     r"raise_tuck_Sys_Started\(\)")
  t.bugFixed "a payload-free registry raise is lowered"

  # FIELD ACCESS ON A PRIMITIVE IS CHECKED.
  #
  # `s.wibble` on a str typechecks clean and becomes <unknown>. The cause is
  # in missingFieldMessage: it declines to report when the receiver has no
  # declared fields ("anything else falls through to gradual typing"), which
  # is deliberate for SUM types but means every primitive receiver accepts
  # every name.
  #
  # Found 2026-08-29 while investigating why `s.len` types as <unknown>.
  # That turned out not to be about `len` at all: `len` is declared NOWHERE
  # — not in std/str.tuck, not in std/seq.tuck, not in the runtime — so it
  # has been resolving by luck in whichever backend spells it the same way.
  # The Nim backend emits `.len` and lets NIM's len answer; the D backend had
  # to hardcode the type because it could not.
  #
  # The fix is two steps and neither is small: declare `len` in std (which
  # collides — `len` in both seq and str is ambiguous the moment a program
  # imports both, and `Seq[T]` did not bind against `Seq[int]` in the
  # attempt), and then make this rejection real.
  t.src """
fn main() -> int:
  let s = "abcd"
  let n = s.wibble
  return 0
"""
  t.quietly: t.badCheck("field access on a primitive is rejected",
                        "TK-TY")
  t.bugFixed "field access on a primitive is rejected"

  # N. A bare `return` inside a `?T`/`!?T`-returning fn read back as PRESENT
  # with zero-valued fields, not absent. `TuckStatus`'s first variant is
  # `tsOk`, so a Nim proc falling through a bare `return` defaulted its
  # zero-valued `TuckResult` to `status: tsOk`. `tnone[T]()` existed for
  # exactly this and no codegen path ever emitted it — silently wrong output,
  # no error, no crash. Found 2026-09-04 by the stdlib-project dogfooding
  # pass. FIXED 2026-09-04: `genReturn` (all three backends) now emits
  # `tnone[T]()` for a bare return when the declared return type is `?T`/
  # `!?T` — tracked separately from plain `retWrapped`, which a bare `!T`
  # (no absence, only Ok/Err) also sets and must keep meaning "return
  # success with a zero value".
  t.src """
fn find({n: int}) -> ?int:
  if n > 0:
    return n
  return

fn main() -> int:
  let r = {n: -1} find
  if r.ok:
    return 1
  return 0
"""
  t.quietly: t.runs("a bare return in a ?T fn reads back as absent, not present", 0)
  t.bugFixed "a bare return in a ?T fn reads back as absent, not present"

  # N+1. `match`-narrowed field access on a payload sum read the FIRST
  # declared variant's storage, not the matched arm's — `v.field` inside
  # EVERY arm of `match v: A: ... B: ...` emitted `v.a.field` regardless of
  # which arm matched, because `variantOwningField` picks whichever variant
  # declares that field name first with no notion of "which arm is this".
  # Typechecks clean, crashes at runtime the moment the wrong variant's tag
  # doesn't match: Nim's `FieldDefect`. Found 2026-09-04 by the
  # stdlib-project dogfooding pass. FIXED 2026-09-04: codegen now tracks,
  # per match arm, which variant the subject is narrowed to (keyed by the
  # subject's own emitted text, so `match r.value:` narrows as well as
  # `match v:`) and consults that before falling back to the first-match
  # scan. All three backends (Nim keyed by matchNarrowed; Odin already got
  # this right via its per-case `switch v in value` union bind; D given the
  # same fix as Nim).
  t.src """
import console

type V:
  | A {field: str}
  | B {field: str}

fn describe({v: V}) -> str:
  match v:
    A: return v.field
    B: return v.field

fn main() -> int:
  var b = V.B {field: "bee"}
  let line2 = {v: b} describe
  {text: line2} printLine
  return 0
"""
  t.quietly: t.outputs("a match arm reads its OWN variant's field, not the first declared one",
                        "bee")
  t.bugFixed "a match arm reads its OWN variant's field, not the first declared one"

  # N+2. Bare `Type.Variant {payload}` sum construction silently dropped
  # every field: `genFieldAccess`'s "bare Type.Variant" branch called
  # `sumVariantCtor(..., nil)` unconditionally, discarding `e.dotArg` — the
  # `{payload}` a caller actually wrote. Found alongside N+1 while
  # reproducing it (the SAME source above prints an empty line without this
  # fix, since `V.B {field: "bee"}` built a fieldless `B` regardless of the
  # match-narrowing fix). FIXED 2026-09-04: pass `e.dotArg` through instead
  # of `nil` in all three backends (`sumVariantCtor`/`dSumVariantCtor` all
  # had the same bug at this call site).
  t.quietly: t.omits("bare variant construction is not built fieldless",
                     "tuck_V\\(kind: B\\)\\)")
  t.bugFixed "bare variant construction is not built fieldless"

  # O. `xs[i]` is GRAMMAR, so it must work with no `import seq` — it used to
  # resolve to a qualified `seq::at`, which typechecked as <unknown> (no
  # signature in scope to look up) and then emitted `seq_at`, an identifier
  # that exists nowhere. Now it lowers to the reserved runtime intrinsics
  # tuckAt/tuckSetAt, which every emitted file already links via tuck_rt —
  # no import, no module qualification, no collision with a user's own `at`.
  # Found 2026-09-04 by the stdlib-project dogfooding pass (sudoku-solver).
  t.src """
import console
import str

fn main() -> void [io]:
  var xs = [1, 2, 3]
  xs[0] = 99
  {text: xs[0].toStr} printLine
"""
  t.quietly: t.outputs("bracket indexing needs no 'import seq'", "99\n")
  t.bugFixed "bracket indexing needs no 'import seq'"
  t.emits "...and lowers to the reserved intrinsic, not a qualified seq call",
          r"tuckSetAt\(tuck_xs, 0, 99\)"
  t.omits "...so no seq_at identifier is ever emitted", "seq_at"

  # P. `distinct X = f32/f64` could not build on the Nim backend at all:
  # genAliasType borrowed `div`/`mod` for EVERY distinct type, and Nim has
  # neither for floats, so the type failed to compile the moment it was
  # declared. That blocked LANGUAGE-OVERVIEW's own recommended unit-safety
  # pattern (distinct Miles = f64, mirroring std/time's u32 durations) for
  # every non-integer unit. Found 2026-09-04 (math-toolkit-cli).
  t.src """
import console

distinct Miles = f64

fn asMiles(value: f64) -> Miles:
  value Miles

fn main() -> void [io]:
  let d = 12.5 asMiles
  {text: "ok"} printLine
"""
  t.quietly: t.outputs("a distinct over a float base builds", "ok\n")
  t.bugFixed "a distinct over a float base builds"
  t.omits "...and borrows no integer div for it", r"`div`\*\(a, b: tuck_Miles\)"
  t.emits "...while still borrowing the ops floats do have", r"`\+`\*\(a, b: tuck_Miles\)"

  # Q. An UNQUALIFIED call to a runtime-backed extern collided with Nim's
  # own auto-exported proc of the same name: `import fs` + `{path: ...}
  # readFile` typechecked clean, then failed the Nim compile with "ambiguous
  # call; both syncio.readFile and tuck_rt.readFile match" — a name the
  # author never wrote and cannot see. Runtime externs now emit qualified
  # (tuck_rt.name), which is what Odin and D already did with rt.name.
  # Found 2026-09-04 (diff-patch).
  t.src """
import fs
import console

fn main() -> void [io]:
  let w = {path: "/tmp/tuck-rtextern.txt", content: "hi"} writeFile
  if w.ok:
    let r = {path: "/tmp/tuck-rtextern.txt"} readFile
    if r.ok:
      {text: r.value.content} printLine
"""
  t.quietly: t.outputs("an unqualified runtime extern does not collide with Nim's own", "hi\n")
  t.bugFixed "an unqualified runtime extern does not collide with Nim's own"
  t.emits "...because runtime externs emit qualified", r"tuck_rt\.readFile\("
  t.emits "...writeFile too, the other name Nim auto-exports", r"tuck_rt\.writeFile\("

  # R. `const b = a + 1` — a const naming ANOTHER const — was rejected as
  # "not a pure compile-time expression", though LANGUAGE-OVERVIEW §1's own
  # definition of pure excludes only [io] calls and record construction.
  # constCheck simply had no exkVar case, so any bare name fell to the
  # blanket rejection. Found 2026-09-04 (diff-patch).
  t.src """
import console
import str

const a = 8
const b = a + 1

fn main() -> void [io]:
  {text: b.toStr} printLine
"""
  t.quietly: t.outputs("a const may name another const", "9\n")
  t.bugFixed "a const may name another const"

  # ...but a name that is NOT a const still has no compile-time value.
  t.src """
fn f({x: int}) -> int:
  return x

const bad = x + 1

fn main() -> int:
  return 0
"""
  t.badCheck "a const naming a non-const is still rejected, by name",
             "names 'x', which is not a const"

  # S. A fallible call used as an implicit tail-return DOUBLE-WRAPPED when the
  # enclosing fn already returns that same !T: genWrappedReturn wrapped
  # unconditionally, building TuckResult[TuckResult[tuple[]]]. Typechecked
  # clean, failed the Nim compile. A value whose own type is already the
  # carrier is a pass-through. Found 2026-09-04 (git-lite).
  t.src """
import fs
import console

fn save({path: str, body: str}) -> !void [io, error: FsError]:
  return {path: path, content: body} writeFile

fn main() -> void [io]:
  let ok = {path: "/tmp/tuck-tailret.txt", body: "hi"} save
  if ok.ok:
    {text: "wrote"} printLine
  let bad = {path: "/nonexistent-dir-xyz/f.txt", body: "hi"} save
  if not bad.ok:
    {text: "failure propagated"} printLine
"""
  t.quietly: t.outputs("a fallible tail-return is not double-wrapped",
                       "wrote\nfailure propagated\n")
  t.bugFixed "a fallible tail-return is not double-wrapped"
  t.omits "...and the pass-through is not re-wrapped in tok",
          r"tok\(tuck_rt\.writeFile"

  # T. `xs[i].field = v` assigned into a COPY. The read path resolves a
  # bracket to tuckAt(), which returns by value, so an assignment target
  # built on one emitted `tuckAt(xs, 0).done = true` — rejected by the
  # backend ("cannot be assigned to") after the checker passed it clean.
  # An assignment TARGET now addresses the element directly. Found
  # 2026-09-06 grilling todo-cli; all three backends had it.
  t.src """
import seq
import console
import str

type Task:
  title: str
  done: bool

fn main() -> void [io]:
  var tasks = [{title: "a", done: false} Task, {title: "b", done: false} Task]
  tasks[0].done = true
  {text: tasks[0].done.toStr} printLine
"""
  t.quietly: t.outputs("an indexed element's field can be assigned", "true\n")
  t.bugFixed "an indexed element's field can be assigned"
  t.emits "...addressing the element, not a tuckAt copy", r"tuck_tasks\[0\]\.done = true"

  # U. A wildcard match arm emitted `of _:` on the Nim backend. `_` is Nim's
  # ignore-identifier and illegal as a branch label, so the catch-all failed
  # to compile after typechecking clean. Odin and D already emitted their
  # `default:`. Found 2026-09-06 grilling todo-cli.
  t.src """
type P:
  | A
  | B

fn main() -> int:
  let p = P.A
  var n = 0
  match p:
    A: n = 1
    _: discard
  return n
"""
  t.quietly: t.runs("a wildcard match arm is the catch-all", 1)
  t.bugFixed "a wildcard match arm is the catch-all"
  t.emits "...emitted as else, not `of _`", r"else:"
  t.omits "...so no `of _` branch label is emitted", r"of _:"

  # 12. An attribute name is reserved only INSIDE brackets — that is what the
  # TK-PA08 diagnostic itself says: "Attribute names like `error` and
  # `priority` are NOT restricted here: they are reserved only inside
  # brackets, so they stay usable as fields, parameters and function names."
  # A field really is allowed. A function name and a parameter name are not,
  # so two thirds of that sentence is false. Found 2026-09-12 writing
  # `bake {key: :priority}` in core/cmp's API doc.
  t.src """
type T:
  priority: int

fn priority({x: int}) -> int:
  return x

fn main() -> int:
  return {x: 1} priority
"""
  t.quietly: t.okCheck "an attribute name is free outside brackets"
  t.bugOpen "an attribute name is free outside brackets"

  # 13. A fn that declares no return type still accepts `return x`, and the
  # emitted Nim is `proc tuck_f*(x: int): void = return x`, which nim rejects
  # with "no return type declared". `tuck ch` says OK, so the gap reaches
  # codegen. Correct either way: whether omitting `->` should be rejected
  # outright or should mean void, returning a VALUE from such a fn is wrong.
  # Found 2026-09-12 checking TUTORIAL.md's "must declare a return type".
  t.src """
fn f({x: int}):
  return x

fn main() -> int:
  return 0
"""
  t.quietly: t.badCheck "a value returned from a fn with no return type is rejected", "return"
  t.bugOpen "a value returned from a fn with no return type is rejected"

  # 14. Register access permissions are enforced in one direction only.
  # Reading a `[write]` field is TK-RE02, as tuck-spec 8.1 says; WRITING a
  # `[read]` field is accepted, and the emitted Nim is
  # `tuck_RCC_HSIRDY_get() = true` — nim answers "cannot be assigned to",
  # because a read-only field emits no setter. Found 2026-09-12 checking the
  # spec's claim that both directions are compile errors.
  t.src """
register RCC at 0x40021000:
  HSION:  bit 0
  HSIRDY: bit 1     [read]

fn main() -> int:
  RCC.HSIRDY = true
  return 0
"""
  t.quietly: t.badCheck "writing a [read] register field is rejected", "read"
  t.bugOpen "writing a [read] register field is rejected"

  # 15. Group conformance resolved the required provider BY NAME and took the
  # last registered, ignoring the receiver — so with two providers in play,
  # whichever came first was checked against the other one's `self` and
  # reported as not conforming. Issue #38.
  #
  # TWO MODULES, not two decls in one. A group takes FREE fns (an object's own
  # member is the interface/satisfies mechanism, pinned below), and two free
  # fns of one name in a single module is a Structure Error — "every top-level
  # name is declared once". So the multi-provider case is by construction the
  # cross-module one, which is also the stdlib's shape: a module per
  # implementation.
  #
  # The blocker is no longer conformance SELECTION. It is that the bounded
  # verb's own body calls `reads` unqualified, and two imports exporting that
  # name trip the ambiguous-import rule before group dispatch is consulted:
  #
  #   Type Error: 'reads' is exported by 2 imports (sensa, sensb) —
  #               call it as 'sensa::reads' to say which
  #
  # Qualifying is exactly what the verb must not do — it has to reach whichever
  # provider matches T. requirementKey's own doc comment anticipates the
  # situation ("a program may import two implementations of the same
  # contract"); the call site simply never asks it.
  t.src """
import sensa
import sensb

group Sensing:
  fn reads({self: Self}) -> int

fn one[T: Sensing]({x: T}) -> int:
  return {self: x} reads

fn main() -> int:
  let p = {a: 1} A
  return {x: p} one
"""
  t.addFile("sensa.tuck", """public:
  A
  reads

type A:
  a: u8

fn reads({self: A}) -> int:
  return 1
""")
  t.addFile("sensb.tuck", """public:
  B
  reads

type B:
  b: u8

fn reads({self: B}) -> int:
  return 20
""")
  t.quietly: t.okCheck("a group bound picks the provider of the RECEIVER's type")
  t.bugOpen "a group bound picks the provider of the RECEIVER's type"

  # A type providing nothing at all is still refused — selection by receiver
  # must not turn a genuine non-conformance into silence.
  t.src """
group Sensing:
  fn reads({self: Self}) -> int

type A:
  a: u8

type C:
  c: u8

fn reads({self: A}) -> int:
  return 1

fn one[T: Sensing]({x: T}) -> int:
  return {self: x} reads

fn main() -> int:
  let r = {c: 3} C
  return {x: r} one
"""
  t.badCheck "...and a type providing nothing is still refused",
             "Conformance\\ Error"

  # 16. On NIM ONLY, an assignment to a register field lowers to the GETTER:
  # `R.W = true` emits `tuck_R_W_get() = true`, which nim answers with
  # "cannot be assigned to". The setter is emitted correctly right above it
  # and simply never called. Odin and D both emit `tuck_R_W_set(true)` from
  # the same source, so this is one backend's lowering, not the checker.
  #
  # The `..` chain form is fine on every backend — `R ..W {true}` emits the
  # setter — which is why the corpus never caught it: examples/20 uses the
  # chain form throughout.
  t.src """
register R at 0x40011000:
  W: bit 0 [read, write]

fn plain() -> void:
  R.W = true
  return

fn main() -> int:
  {} plain
  return 0
"""
  t.hostBuilds "a register field assignment emits the setter"
  t.bugFixed "a register field assignment emits the setter"

  # 17. On ODIN ONLY, the dispatch closure for an interface method is typed
  # `-> int` regardless of what the method returns, so any interface method
  # returning an enum (or anything else non-int) fails to compile:
  #   Cannot assign value '(proc(v: Detector) -> int)(d)' of type 'int'
  #   to 'tuck_Demand' in return statement
  # Nim and D build the same source. Odin has no switch expression, so its
  # dispatch is wrapped in a closure (docs/interfaces.md) — the closure's
  # return type is what is wrong.
  t.src """
type Demand:
  | quiet
  | busy

interface Detector:
  fn reads({self: Self}) -> Demand

object Loop:
  satisfies Detector
  lane: u8
  fn reads({self: Loop}) -> Demand:
    return Demand.busy

fn poll({d: Detector}) -> Demand:
  return d.reads

fn main() -> int:
  let l = {lane: 1} Loop
  let d = {d: l} poll
  match d:
    quiet: return 0
    busy: return 1
"""
  t.quietly: t.hostBuilds "an interface method may return an enum"
  t.bugOpen "an interface method may return an enum"

  # 18. An actor's message envelope carries a generated `kind` discriminator,
  # and a handler payload field of the same name lands beside it — so the
  # emitted struct declares `kind` twice and every backend refuses it:
  #   nim  "attempt to redefine: 'kind'"
  # `tuck ch` says OK. `kind` is an ordinary field name for anything carrying
  # tagged data (a NAL kind, a message kind, an event kind), so this is a
  # name a real program reaches for. Found 2026-09-13 writing an H.264
  # capture driver whose handler took `{kind: NalKind}`.
  #
  # The generated name is at codegen_decl.nim:398 (`kind*: <Actor>MsgKind`).
  # Same class as TK-PA12's host keywords — a name the author cannot see
  # colliding with one codegen owns — but for a GENERATED name, which that
  # guard does not cover.
  t.src """
type NalKind:
  | idr
  | sps

actor Pipe:
  seen: int
  on nal({kind: NalKind}):
    self.seen = self.seen + 1

fn main() -> int:
  return 0
"""
  t.hostBuilds "an actor handler payload may have a field named 'kind'"
  t.bugFixed "an actor handler payload may have a field named 'kind'"

  # 19. On D ONLY, an actor's send helper constructs the message envelope
  # POSITIONALLY, so a second handler's payload lands in the first handler's
  # field. The envelope is {kind, lvl, n}; `bump {n: 2}` emits
  #   tuck_SinkMsg(tuck_SinkMsgKind.msgBump, n)
  # and dmd answers "cannot implicitly convert expression `n` of type `long`
  # to `tuck_Level`". Nim emits `tuck_SinkMsg(kind: msgBump, n: 2)` — named,
  # and correct — and Odin builds too.
  #
  # It needs TWO handlers with non-empty payloads of different types, which is
  # why examples/20 survives: its later handlers take empty payloads, so
  # positional and named agree. Found 2026-09-13 writing an H.264 driver.
  t.src """
type Level:
  | low
  | high

actor Sink:
  seen: int

  on setLevel({lvl: Level}):
    self.seen = self.seen + 1

  on bump({n: int}):
    self.seen = self.seen + n

fn main() -> int:
  Sink send bump {n: 2}
  return 0
"""
  t.hostBuilds "an actor may have two handlers with different payloads"
  t.bugFixed "an actor may have two handlers with different payloads"

  # 20. `release` frees the wrong slot, and a slot leaks. The runtime matches
  # the item back to its cell BY VALUE (`pool.storage[i] == item`, all three
  # runtimes, deliberately mirrored) — but `acquire` hands out a COPY and
  # nothing ever writes a slot, so every slot holds the same zero value and
  # the scan always matches slot 0. Releasing two items frees slot 0 twice;
  # slot 1 stays occupied forever.
  #
  # Observable without leaving Tuck: acquire both slots of a count-2 pool,
  # release both, and only one comes back.
  #
  # The Nim runtime's own comment says "Compare by address within the storage
  # array" — which is what it should do and does not. Found 2026-09-13 while
  # writing an H.264 frame-buffer pool.
  t.src """
type Cell:
  n: int

pool Cells = Cell [count: 2]

fn take() -> int:
  let s = Cells.acquire
  if s.ok:
    return 1
  return 0

fn main() -> int:
  let a = Cells.acquire
  let b = Cells.acquire
  if not a.ok:
    return 9
  if not b.ok:
    return 9
  Cells.release {a.value}
  Cells.release {b.value}
  return ({} take) + ({} take)
"""
  t.runs "releasing every slot makes every slot available again", 2
  t.hostBuilds "...on every backend"
  t.bugFixed "releasing every slot makes every slot available again"

  # 21. A pool slot cannot yet be READ or WRITTEN. `acquire` now answers with
  # a handle that names the cell (which is what fixed release), but there is
  # no spelling for "the cell this handle names" — so a pool still cannot be
  # a DMA target, a frame buffer, or anything hardware or another task fills
  # in place, which is what a pool is FOR. examples/25 says "hand b.value to
  # the DMA controller"; b.value is the handle, and nothing takes it further.
  #
  # The design question is open (issue #45): a read/write pair through the
  # handle, and a sanctioned way to hand a cell's ADDRESS to an extern for
  # the DMA case, which is the one place a raw pointer is legitimate.
  t.src """
type Cell:
  n: int

pool Cells = Cell [count: 2]

fn main() -> int:
  let a = Cells.acquire
  if not a.ok:
    return 90
  Cells.write {h: a.value, value: {n: 42} Cell}
  let back = Cells.read {h: a.value}
  return back.n
"""
  t.quietly: t.runs "a pool slot can be read and written through its handle", 42
  t.bugOpen "a pool slot can be read and written through its handle"

  # 22. An `errors` handler body was never mangled, so calling any fn from it
  # failed to build on all three backends (issue #48). The DECLARATION was
  # renamed to `tuck_record`; the call inside the handler still said `record`.
  #
  # Root cause: `dkErrors` sat in the `discard` arm of `ast_ops.childDecls`,
  # so `d.errHandler` was reached by NOTHING built on that iterator — mangle,
  # assignIds, clearIds and the checker's type-ref resolution alike. The
  # exhaustive `case` did not catch it: the kind WAS listed, it just yielded
  # nothing.
  #
  # This is spec 4.9's own example — the handler is documented as "the hook
  # for diagnostics machinery", every use of which is a call.
  #
  # The assertion RUNS and reads stdout rather than checking: the program
  # passed `tuck ch` cleanly all along and died in nim/odin/dmd, and a build
  # alone would not prove the handler's call actually happens at runtime.
  t.src """
import console

type E:
  | Boom

errors [policy: continue]:
  on unhandled({code: u16, site: str}):
    {code: code} record

fn record({code: u16}) -> void [io]:
  {text: "handler called a fn"} printLine
  return

fn mayFail({n: int}) -> !int [io, error: E]:
  if n > 0:
    return n
  return err E.Boom

fn main() -> int [io]:
  {n: -1} mayFail
  return 0
"""
  t.runs "an errors handler may call a fn", 0
  t.outputs "...and the call actually runs", "handler\\ called\\ a\\ fn"
  t.hostBuilds "...on every backend"
  t.bugFixed "an errors handler may call a fn"

  # 23. A group-bounded generic BUILDS AND RUNS when the provider is a free
  # fn — which is the form spec 5.5 actually specifies: "the compiler looks
  # for a FREE FUNCTION matching the group's required signature". Nothing
  # covered this before, on any backend, because A4 made every realistic
  # group program unreachable. It is the mechanism the whole v2 stdlib rests
  # on, so it is pinned here as a passing guard rather than left to the
  # check-only assertions in `groups`.
  t.src """
group Sensing:
  fn reads({self: Self}) -> int

object A:
  a: u8

fn reads({self: A}) -> int:
  return 7

fn one[T: Sensing]({x: T}) -> int:
  return {self: x} reads

fn main() -> int:
  let p = {a: 1} A
  return {x: p} one
"""
  t.runs "a group bound dispatches to a free fn", 7
  t.hostBuilds "...on every backend"

  # 24. An object's own member does NOT satisfy a group (ruled 2026-09-13).
  # Tuck has two contract mechanisms split by what they abstract over:
  # `interface` for role objects, which opt in with `satisfies` and compose
  # with `+`; `group` for plain types, which is the generics-facing one a
  # bound uses. A fn declared inside an object belongs to that object, so
  # offering it to a group mixes the two.
  #
  # It used to CHECK and then emit code no backend could build — the member
  # emitted under a name the call site did not use, with a `var` receiver a
  # generic param cannot fill. Saying it at the group bound says the same
  # thing in the language the author wrote rather than in generated Nim.
  t.src """
group Sensing:
  fn reads({self: Self}) -> int

object A:
  a: u8
  fn reads({self: A}) -> int:
    return 7

fn one[T: Sensing]({x: T}) -> int:
  return {self: x} reads

fn main() -> int:
  let p = {a: 1} A
  return {x: p} one
"""
  t.badCheck "an object member does not satisfy a group", "object\\ member"
  t.badCheck "...and the message offers both real routes", "satisfies"
  t.bugFixed "an object member satisfying a group is settled one way or the other"

  # An ACTOR FIELD on the left of an in-place append or a MOVED twin call.
  # Found 2026-09-20 by writing an application (benches/apps), recorded as
  # EV-9 in KNOWN-BUGS-EVENTS.md.
  #
  # Both spellings take a FAST PATH in genAssign that bypasses the normal
  # field handling and spelled the target as a bare `e.target.name`. The
  # value on the right is built by the ordinary expression emitter, which
  # DOES qualify, so a handler emitted `xs.add(px)` and
  # `st = f(self.st, px)` — bare on the left, `self.` on the right. No host
  # compiler takes either.
  #
  # It needs all three legs because the two paths split the backends between
  # them: Nim was correct on the moved call and wrong on the append, D and
  # Odin the other way round. A one-backend assertion would have reported
  # green on whichever half it happened to miss.
  #
  # And it needs an ACTOR: every existing chain and move test binds a local
  # or a parameter, where there is no `self.` to lose. That intersection —
  # a Seq or Seq-carrying field, on an actor, as an assignment target — is
  # what nothing covered, and `tuck ch` says OK for all of it.
  t.src """
import seq

type BookState:
  fills: Seq[int]
  total: int

fn applyBuy({b: BookState, px: int}) -> BookState:
  var f = b.fills
  f = {items: f, value: px} push
  return {fills: f, total: b.total + px} BookState

actor Book [queue: 8]:
  st: BookState
  xs: Seq[int]
  n: int = 0

  on buy({px: int}):
    st = {b: st, px: px} applyBuy
    xs = {items: xs, value: px} push
    n = n + 1

fn ready() -> bool:
  return Book.n == 1

fn main() -> int:
  Book send buy {px: 7}
  Book.waitUntil {pred: :ready}
  return Book.st.total
"""
  t.quietly: t.okCheck "an actor field survives an append and a moved call"
  t.quietly: t.hostRuns("an actor field survives an append and a moved call", 7)
  t.bugFixed "an actor field survives an append and a moved call"

  # A loop that copies does not accumulate the copies. Odin only: that
  # backend emits no `delete` anywhere, so every `tuckSeqCopy` is live until
  # the process exits — 75 KB per message on a real program, OOM-killed at
  # 13.6 GB where Nim and D use 17-21 MB. EV-12, issue #77.
  #
  # Stated as the CORRECT behaviour and expected to fail, which is the only
  # honest shape for it: the program is right, the answer it prints is right,
  # and every other assertion in the tree passes. Only the memory is wrong,
  # and until `hostPeakRss` existed nothing here could say so.
  #
  # 20 000 copies of a 1024-element ladder is 160 MB of garbage. Nim finishes
  # in ~1.6 MB and D in ~7 MB; Odin reached 482 MB.
  t.src """
import seq

fn zeroed({levels: int}) -> Seq[int]:
  var out = [0]
  var i = 1
  for i < levels:
    out = {items: out, value: 0} push
    i = i + 1
  return out

fn bump({xs: Seq[int]}) -> Seq[int]:
  var ys = xs
  ys[0] = ys[0] + 1
  return ys

fn main() -> int:
  var xs = {levels: 1024} zeroed
  var i = 0
  for i < 20000:
    let ns = {xs: xs} bump
    xs = ns
    i = i + 1
  if xs[0] != 20000:
    return 1
  return 0
"""
  t.quietly: t.hostPeakRss("a copy-per-iteration loop does not accumulate copies", 65536)
  t.bugFixed "a copy-per-iteration loop does not accumulate copies"

  # 18. On ODIN ONLY, every heap `str` leaks — the whole category, not one
  # site. `copyableContainer` excludes `str` deliberately and for a good
  # reason: it is immutable in both D and Odin, so sharing its buffer cannot
  # be observed. But that is an argument about ALIASING, and it was taken as
  # settling OWNERSHIP too — so `str` is outside the copy machinery, outside
  # the twin machinery, and outside the (single) `delete` the backend emits.
  #
  # Found with valgrind on the SMALLEST example in the tree.
  # `examples/24-stdlib` loses 30 bytes in one block, and the stack names
  # `os::read_entire_file_from_path` inside `tuckrt::fileWorker`: `readFile`
  # transmutes the buffer to a `str`, hands it to Tuck, and nothing frees it.
  # `41-tostr-concat` loses 46 from `strings::Builder`, which is the `toStr`
  # and concat path. Both are the same category, and it is linear — 272,
  # 2 343 and 23 044 bytes for 10, 100 and 1 000 `toStr` calls.
  #
  # Nim is clean (ARC) and D reports nothing definitely lost (its GC
  # collects), so one budget separates them: the same program peaks at
  # 1.7 MB on Nim and 3.9 MB on D against 33 MB on Odin.
  #
  # Distinct from A19 above, which is about `Seq` intermediates. This one
  # reaches programs that touch no container at all — anything that formats.
  t.src """
import str

fn churn({n: int}) -> int:
  var acc = 0
  var i = 0
  for i < n:
    let s = i.toStr
    acc = acc + s.len
    i = i + 1
  return acc

fn main() -> int:
  let acc = {n: 1000000} churn
  if acc < 1:
    return 1
  return 0
"""
  t.hostPeakRss("a million temporary strings do not accumulate", 12288)
  t.bugFixed "a million temporary strings do not accumulate"

  # The exit status of `fn main() -> int` is its LOW BYTE on every backend.
  # Nim's `quit` clamps to int8 instead, so 132 exited 127 on Nim and 132 on
  # Odin and D — found 2026-09-25 when a chain test answered 127 on Nim
  # alone and looked like a wrong answer.
  t.src """
fn main() -> int:
  return 200
"""
  t.quietly: t.hostRuns("main's exit status is its low byte everywhere", 200)
  t.bugFixed "main's exit status is its low byte everywhere"

  # ...nor do the strings a CONCATENATION reads, or builds on the way. Found
  # by benches/memory, not by review: `let t = s + "-" + s` in a loop leaked
  # two strings a turn on Odin (123 MB at two million turns, 244 MB at four)
  # while Nim and D held under 4 MB.
  #   * `s` looked escaped: the `str` rule let a binding's seal flow through
  #     the allocating concatenation into its operands, though the result it
  #     binds holds none of them (ownership_escape: an exempt call blocks it).
  #   * `s + "-"` had no name, so no local owned it; it is named now
  #     (lowering_strtemps) and freed like one.
  t.src """
import str

fn churn({n: int}) -> int:
  var acc = 0
  var i = 0
  for i < n:
    let s = i.toStr
    let t = s + "-" + s
    acc = acc + t.len
    i = i + 1
  return acc

fn main() -> int:
  let acc = {n: 1000000} churn
  if acc < 1000000:
    return 1
  return 0
"""
  t.hostPeakRss("the strings a concatenation reads and builds do not accumulate", 12288)
  t.bugFixed "the strings a concatenation reads and builds do not accumulate"

  # 19. EV-14 / issue #82: the dead intermediates of a THREADING CHAIN.
  #
  # `relight` is the world_server shape reduced: a record with two Seq fields
  # is threaded through two calls, and only ONE field of the last result is
  # returned. Everything else each step allocated is abandoned. On Odin that
  # was 4 948 MB for the real application and 322 MB here; Nim's ARC and D's
  # GC both sit at 10 MB, so one budget separates them.
  #
  # TWO RULES CLOSED IT, and both are about GRANULARITY rather than analysis:
  # a twin frees its parameter PER SLOT (it used to be all-or-nothing, so one
  # returned field that aliases the parameter kept every other field alive),
  # and a local's escape is asked PER SLOT too (`c.light` escapes, `c.height`
  # does not).
  #
  # Verified to be measuring the leak rather than a build failure:
  # `TUCK_NO_SEQ_FREE=1` puts it back at 322 MB and this assertion fails.
  t.src """
import seq

type Flood:
  height: Seq[int]
  light:  Seq[int]
  n:      int

fn zeroed({levels: int}) -> Seq[int]:
  var out = [0]
  var i = 1
  for i < levels:
    out = {items: out, value: 0} push
    i = i + 1
  return out

fn step({f: Flood}) -> Flood:
  var l = f.light
  l[0] = l[0] + 1
  return {height: f.height, light: l, n: f.n + 1} Flood

fn relight({h: Seq[int], l: Seq[int]}) -> Seq[int]:
  let a = {height: h, light: l, n: 0} Flood
  let b = {f: a} step
  let c = {f: b} step
  return c.light

fn spin({h: Seq[int], l: Seq[int], rounds: int}) -> int:
  var i = 0
  var acc = 0
  for i < rounds:
    let out = {h: h, l: l} relight
    acc = acc + out[0]
    i = i + 1
  return acc

fn main() -> int:
  let h = {levels: 1024} zeroed
  let l = {levels: 1024} zeroed
  let acc = {h: h, l: l, rounds: 20000} spin
  if acc != 40000:
    return 1
  return 0
"""
  t.hostPeakRss("a threading chain does not accumulate its intermediates", 65536)
  t.bugFixed "a threading chain does not accumulate its intermediates"

  # 20. A `str` a body RETURNS must not be freed by that body.
  #
  # EV-20's escape test answered "could this destination be carrying a str"
  # with FALSE for `str` itself, reasoning that the runtime procs which
  # answer one allocate rather than passing a string through. That is true of
  # a CALL and false of a RETURN, and the difference is a use-after-free:
  #
  #     tuck_label :: proc (n: int) -> string {
  #       tuck_s := str.toStr(n)
  #       defer delete(tuck_s)
  #       return tuck_s            // <- freed, then returned
  #     }
  #
  # It printed garbage. Nothing caught it: every `str` in the corpus is
  # consumed where it is built, so no example returns one it allocated. That
  # gap is what this assertion closes, and it is the SHAPE that matters —
  # allocate, bind to a name, return the name.
  t.src """
import str
import console

fn label({n: int}) -> str:
  let s = n.toStr
  return s

fn main() -> int:
  let a = {n: 42} label
  {text: a} console::printLine
  return {t: a} byteCount
"""
  t.okCheck "a fn may return a str it allocated"
  # ASSERTED ON STDOUT, NOT THE EXIT CODE, and that distinction is the whole
  # assertion. A use-after-free reads memory that is usually still intact, so
  # `byteCount` answers 2 whether the buffer was freed or not — the first
  # version of this guard passed against the bug it was written for. Printing
  # the string is what forces the allocator to reuse the block: freed it
  # prints nothing, live it prints 42.
  # ON EVERY BACKEND, and matched on OUTPUT rather than the exit code. Both
  # halves were wrong in the first two attempts at this guard, and each made
  # it pass against the bug it was written for:
  #   * `runs`/`outputs` run on NIM, which has ARC and never emits the free,
  #     so the backend with the bug was never asked;
  #   * a use-after-free reads memory that is usually still intact, so
  #     `byteCount` answers 2 either way. Printing forces the allocator to
  #     reuse the block: freed it prints nothing, live it prints 42.
  t.hostRuns("...and every backend's caller can still read it", 2, "42")
  t.bugFixed "a returned str is not freed by the body that built it"

  # A MOVED TWIN FREED ITS PARAMETER TWICE. Inside `peek_moved`, `let t = xs`
  # reads through the moved parameter, and the EMITTER suppressed the copy
  # there — but the copy pass had marked the site, so the ownership pass
  # read "copied, therefore ours" and emitted `defer delete(t)` beside the
  # twin's own `defer delete(xs)`: one buffer, two frees, SIGSEGV on Odin.
  # The suppression was a copy decision made in the emitter, invisible to
  # everything that reads the copy pass's record. Found 2026-09-25 reading
  # `afterBinding`'s account of that same emitter rule.
  t.src """
import seq

fn peek({xs: Seq[int]}) -> Seq[int]:
  let t = xs
  let n = t.len
  return {items: xs, value: n} push

fn main() -> int:
  var a = [1, 2, 3]
  a = {xs: a} peek
  let b = {xs: a} peek
  return a[3] + b[4] + b.len
"""
  t.quietly: t.hostRuns("a twin frees what it read through its param once", 12)
  t.bugFixed "a twin frees what it read through its param once"

  # #21 — a type the checker SYNTHESIZED had no declaration edge. A record
  # construction's type was built bare, so asking for its fields while the
  # body was being checked fell back to scanning the decl list by name — the
  # scan that made emit quadratic (#23). Every named type is now made by
  # `typecheck_collect.namedType`, and lowering ASSERTS on a miss the decl
  # list would have answered, so the regression is a crash in `tuck c`, not a
  # silent slowdown. Constructed on every backend, since each lowers its own
  # copy.
  #
  # The assertion found the second half at once: an IMPORTED type's injected
  # declaration had no id, and `resolveTypeTo` returned silently on one — so
  # `d: Milliseconds` from std/time was "found" and never linked. Guarded by
  # examples/32 in odin_backend and by the cross_module suite, which is where
  # it surfaced.
  t.src """
type Config:
  port: int
  name: str

fn make({port: int}) -> Config:
  return {port: port, name: "srv"} Config

fn main() -> int:
  let c = {port: 7} make
  return c.port
"""
  t.quietly: t.emits("a construction's type carries its declaration edge", "")
  t.bugFixed "a construction's type carries its declaration edge (#21)"
  t.quietly: t.emitsOdin("...on Odin too", "")
  t.bugFixed "a construction's type carries its declaration edge on Odin (#21)"
  t.runs "...and the program computes it", 7

  t.finish()
