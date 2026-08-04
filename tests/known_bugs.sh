#!/bin/bash
# Regression tests for known bugs — both the ones still open and the ones
# already fixed.
#
# Each entry states the CORRECT behaviour as a real assertion, plus a marker
# saying whether the compiler does that yet:
#
#   bug_open  -> the bug is open. The suite reports it and expects the
#                assertion to fail. If it starts PASSING, the suite fails and
#                tells you to flip the marker: that is how a fix gets locked in.
#   bug_fixed -> the bug is fixed. The assertion is now a permanent regression
#                guard and fails like any normal test.
#
# So fixing a bug is a two-line change — fix it, flip the marker — and from
# then on the same assertion protects it forever. Nothing gets deleted, so a
# bug that returns is caught by the test written when it was first found.
#
# Converted from tests/known_bugs.nim, which already drove the tuck BINARY via
# execCmdEx — it was a Nim program purely for its harness, and paid a full
# compiler rebuild for the privilege.
cd "$(dirname "$0")/.."
. tests/lib.sh

echo "=== known bugs: each OPEN line below is a bug that still reproduces ==="

# 1. Integer division is `/i`, and it really is integer division.
# Found 2026-07-22: `a /= 4` on an int lowered to Nim's `/`, which returns
# float, so the emitted code did not compile. FIXED 2026-07-28 by ruling R1
# rather than by patching the emitter: a bare `/` no longer exists, `/i` is
# integer divide and `/f` is float divide. Nim spells integer divide `div` and
# Odin spells it `/` — that divergence is why the source must say which.
src <<'TUCKEOF'
fn main() -> int:
  var a = 10
  a /i= 4
  return a
TUCKEOF
try runs "" 2
bug_fixed "'/i=' on ints uses integer division"

# 2. `toStr` + string concatenation picked the numeric `+`. Two causes: an
# UNQUALIFIED call to an imported fn never resolved a return type (only the
# qualified key existed in fnSigs), and postfix application only recognized a
# LITERAL receiver, so `n.toStr` was not treated as a call at all.
src <<'TUCKEOF'
import str

fn main() -> int:
  let n = 3
  let s = n.toStr + " bottles"
  return 0
TUCKEOF
try runs "" 0
bug_fixed "'toStr' result stays a str under '+'"

# 3. `if` has no expression form (ruling R2). Nim has a real if-expression;
# Odin has none and gets its ternary.
src <<'TUCKEOF'
fn main() -> int:
  let a = 5
  let x = if a > 0: 1 else: 2
  return x
TUCKEOF
try ok_check ""
bug_fixed "'if' works as an expression"

# 4. `[saturating]` clamps instead of wrapping. Was: no compile error, no
# runtime trap, just a wrong value (70000 into a u16 became 4464). Root cause
# was in the PARSER: `type X = u16 [saturating]` had its trailing attrs
# clobbered by the pre-`=` ones, so the attribute never reached the backend.
src <<'TUCKEOF'
type SafeRPM = u16 [saturating]

fn main() -> int:
  let s = 70000 SafeRPM
  if s == 65535 SafeRPM:
    return 1
  return 2
TUCKEOF
try runs "" 1
bug_fixed "'[saturating]' clamps at the maximum"

# 4b. A saturating chain clamps against the FINAL value. `a + b - c` (all
# 60000) is 60000, which fits. Per-operator saturation would clamp a+b to
# 65535 and yield 5535; the store-guard design clamps only where a value is
# stored, so transient intermediates do not corrupt the result.
src <<'TUCKEOF'
type SafeRPM = u16 [saturating]

fn main() -> int:
  let a = 60000 SafeRPM
  let b = 60000 SafeRPM
  let c = 60000 SafeRPM
  let r = a + b - c
  if r == 60000 SafeRPM:
    return 1
  return 2
TUCKEOF
try runs "" 1
bug_fixed "saturating chain clamps on the result, not each operator"

# 4c. The Odin backend must clamp too: the same program wrapping on one
# backend and clamping on the other is the divergence the parity commitment
# exists to stop. The Odin RUNTIME had tuckSat all along — only the emitter
# never called it. Assert the clamp is CALLED; "70000 is absent" would be
# wrong, since it legitimately appears as the argument: rt.tuckSat(u16, ...).
src <<'TUCKEOF'
type SafeRPM = u16 [saturating]

fn main() -> int:
  let s = 70000 SafeRPM
  return 0
TUCKEOF
try emits_odin "" 'tuckSat\(u16'
bug_fixed "Odin backend clamps [saturating] too"

# 5. OPEN — a type argument named like an attribute fails to parse. The
# attribute-vs-generic decision is a hardcoded 19-name word list, so any type
# argument sharing a name with an attribute — error, stack, queue, align,
# priority, volatile … — is misread.
# Fix: decide by declared set, not a literal list (compiler/parser.nim).
src <<'TUCKEOF'
type Box[T]:
  v: T

fn take({b: Box[error]}) -> int:
  return 0

fn main() -> int:
  return 0
TUCKEOF
try ok_check ""
bug_open "type argument may be named like an attribute"

# 6. The diagnostic for bug 5 named a token, not the problem. `Box[error]`
# used to fail with "Expected token 'tkColon' but got 'tkRBracket'". The parse
# still fails (bug 5 above), but the message now explains why and what to do.
src <<'TUCKEOF'
type Box[T]:
  v: T

fn take({b: Box[error]}) -> int:
  return 0

fn main() -> int:
  return 0
TUCKEOF
try bad_check "" 'is an attribute name'
bug_fixed "attribute/type-argument clash explains itself"

# 7. Block-bodied match arms indent correctly. Was blocking example 20: the
# arm emitter hardcoded `"  of "` and `"\n    "` as if the case sat at column
# 0, while a block body self-indents from ctx.indent.
# 7b. ...and a tail match whose arms RETURN is not re-wrapped: injectTailReturn
# assumed a trailing match always had value arms, so it emitted
# `return (case ...)` over branches that never yield a value.
src <<'TUCKEOF'
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
TUCKEOF
try runs "" 2
bug_fixed "block-bodied match arms indent correctly"
try runs "" 2
bug_fixed "tail match with returning arms is not double-wrapped"

# 8. `.fn {args}` on an UNDECLARED fn emitted a bare field access —
# `buf.copyFrom {data}` became `self.buf.copyFrom`, dropping the argument
# entirely. Ruling 2026-07-23: a brace after `.name` is ALWAYS a call, so an
# undeclared callee is a clean checker error, not a silent field read.
src <<'TUCKEOF'
actor Driver [queue: 8]:
  buf: Seq[u8]

  on send({data: Seq[u8]}) -> void:
    buf.copyFrom {data}

fn main() -> int:
  return 0
TUCKEOF
try bad_check "" 'copyFrom'
bug_fixed "'.fn {args}' on an undeclared fn is reported, not silently a field read"

# 9. An early-return guard narrows a result. The checker recognised only
# `if r.ok:`. `if not r.ok: return` proves presence for everything after it
# just as well, and is the flat form the spec itself uses (7.2's pool
# example) — but reading .value after it was rejected. Affects !T and ?T alike.
src <<'TUCKEOF'
fn readIt({n: int}) -> !{v: int} [io]:
  return {v: n}

fn main() -> int [io]:
  let r = {n: 5} readIt
  if not r.ok:
    return 0
  return r.value.v
TUCKEOF
try runs "" 5
bug_fixed "early-return guard narrows a result"

# 10. `elif` was lexed but never parsed. tkElif was in the lexer's keyword
# table from the start, but parseExpr's if-branch only looked for tkElse, so a
# natural `elif` chain died with "Expected expression but got: tkElif". Found
# by the rosetta corpus, where two independent authors reached for elif
# writing ordinary grading/guard code. Fix: `elif C: B` parses as
# `else: (if C: B)` — pure sugar, so no AST/checker/codegen change was needed.
src <<'TUCKEOF'
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
TUCKEOF
try runs "" 2
bug_fixed "elif chains parse"

# 11. An overflow attribute implies `distinct` on the Nim backend but not on
# Odin. codegen.nim's genAliasType treats distinct/saturating/wrapping/trapping
# alike — the ATTRIBUTE is what changes behaviour, and it is meaningless on a
# bare alias. codegen_odin.nim's genAliasType matches only "distinct", so
# `u16 [saturating]` emits `SafeRPM :: u16`: a plain alias, freely mixable with
# any other u16, where Nim gives a type the compiler keeps separate.
# The clamping itself is right on both (tuckSat is emitted either way); what
# Odin loses is the type distinction.
src <<'TUCKEOF'
type SafeRPM = u16 [saturating]

fn main() -> int:
  var r = SafeRPM(70000)
  return 0
TUCKEOF
try emits_odin "" 'SafeRPM :: distinct u16'
bug_open "an overflow attribute implies distinct on the Odin backend too"

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
src <<'TUCKEOF'
actor Accumulator [queue: 64]:
  total: int = 0

  on select:
    | add -> {n: int}:  total += n

fn main() -> int:
  Accumulator send add {n: 1}
  return 0
TUCKEOF
try emits_odin "" 'sendAdd_tuck_Accumulator :: proc'
bug_open "an 'on select' actor emits its send procs on the Odin backend"

finish
