# tests/known_bugs.nim
# Regression tests for known bugs — both the ones still open and the ones
# already fixed.
#
# Each entry states the CORRECT behaviour as a real assertion, plus a `fixed`
# flag saying whether the compiler does that yet.
#
#   fixed = false -> the bug is open. The suite reports it and expects the
#                    assertion to fail. If it starts PASSING, the suite fails
#                    and tells you to flip the flag: that is how a fix gets
#                    locked in.
#   fixed = true  -> the bug is fixed. The assertion is now a permanent
#                    regression guard: if the bug ever comes back, the suite
#                    fails like any normal test.
#
# So fixing a bug is a two-line change — fix it, flip the flag — and from then
# on the same assertion protects it forever. Nothing gets deleted, so a bug
# that returns is caught by the test written when it was first found.

import os, osproc, strutils

let repoRoot = currentSourcePath.parentDir.parentDir
let tuckBin = repoRoot / "tuck"

var failures = 0
var stillBroken = 0

proc build(src: string): tuple[ok: bool, output: string] =
  ## Compile a snippet all the way to a binary. ok=false when any stage fails.
  let dir = getTempDir() / "tuck_known_bugs"
  removeDir(dir)
  createDir(dir)
  let f = dir / "t.tuck"
  writeFile(f, src)
  let (outp, code) = execCmdEx(tuckBin & " build " & f & " -o:" & dir / "out")
  result = (code == 0, outp)

proc run(src: string): tuple[built: bool, exitCode: int] =
  ## Build and run; exitCode is the process result (Tuck main's return value).
  let dir = getTempDir() / "tuck_known_bugs_run"
  removeDir(dir)
  createDir(dir)
  let f = dir / "t.tuck"
  writeFile(f, src)
  let (_, code) = execCmdEx(tuckBin & " build " & f & " -o:" & dir / "out")
  if code != 0: return (false, -1)
  let (_, rc) = execCmdEx(dir / "out" / "t")
  (true, rc)

proc check(src: string): string =
  let dir = getTempDir() / "tuck_known_bugs_check"
  removeDir(dir)
  createDir(dir)
  let f = dir / "t.tuck"
  writeFile(f, src)
  let (outp, _) = execCmdEx(tuckBin & " ch " & f)
  outp

template bug(name, why, fixWhere: string, fixed: bool, correct: untyped) =
  ## `correct` asserts the behaviour we WANT. `fixed` says whether we have it.
  let ok = correct
  if fixed and ok:
    echo "PASS           ", name
    echo "               (regression guard — this bug was fixed and stays fixed)"
  elif fixed and not ok:
    echo "REGRESSED!     ", name
    echo "               ", why
    echo "               This was FIXED and has come back. Look at: ", fixWhere
    failures.inc
  elif ok:
    echo "NOW PASSING!   ", name
    echo "               This bug appears to be fixed — that is GOOD."
    echo "               Set fixed = true on this entry to lock the fix in,"
    echo "               so the suite catches it if it ever returns."
    failures.inc
  else:
    echo "OPEN (known)   ", name
    echo "               ", why
    echo "               fix: ", fixWhere
    stillBroken.inc

echo "=== known bugs: each line below is a bug that still reproduces ==="
echo ""

# ---------------------------------------------------------------------------
# 1. `/=` on integers emits Nim's float-returning `/`
# ---------------------------------------------------------------------------
# Found 2026-07-22 while collapsing the five compound-assign branches.
# Verified pre-existing at bd335c3, so it predates that refactor.
block:
  let (ok, outp) = build("""
fn main() -> int:
  var a = 10
  a /= 4
  return a
""")
  bug(
    "`/=` on ints uses integer division",
    "`a /= 4` on an int lowers to Nim's `/`, which returns float, so the " &
      "generated code does not compile. Integer division should emit `div`.",
    "compiler/codegen.nim binary emission — boDiv on integer operands",
    fixed = false,
    ok)   # correct = it compiles

# ---------------------------------------------------------------------------
# 2. `toStr` + string concatenation picks the numeric `+`
# ---------------------------------------------------------------------------
# From the 2026-07-20 expressibility audit; investigation was in flight when
# that session ended. `n.toStr` alone works; it only breaks under `+`.
block:
  let (ok, outp) = build("""
fn main() -> int:
  let n = 3
  let s = n.toStr + " bottles"
  return 0
""")
  bug(
    "`toStr` result stays a str under `+`",
    "`n.toStr + \" bottles\"` picks the numeric `+` overload instead of " &
      "tuckConcat. The concat branch tests e.left's type, which is not str " &
      "here — either the type is unset or the expression parses as " &
      "`n.(toStr + ...)`.",
    "compiler/codegen.nim:469 / :772 concat condition — dump the AST first",
    fixed = false,
    ok)   # correct = it compiles

# ---------------------------------------------------------------------------
# 3. `if` has no expression form
# ---------------------------------------------------------------------------
block:
  let outp = check("""
fn main() -> int:
  let a = 5
  let x = if a > 0: 1 else: 2
  return x
""")
  bug(
    "`if` works as an expression",
    "`let x = if c: a else: b` is a parse error. Nim (the target) supports " &
      "if-expressions natively, so this is a parser gap, not a lowering one.",
    "compiler/parser.nim — allow exkIf in expression position",
    fixed = false,
    "Parse Error" notin outp)   # correct = it parses

# ---------------------------------------------------------------------------
# 4. FIXED 2026-07-22 — `[saturating]` clamps instead of wrapping
# ---------------------------------------------------------------------------
# Was: no error at compile time, no trap at runtime, just a wrong value
# (70000 into a u16 became 4464). Root cause was in the PARSER, not codegen:
# `type X = u16 [saturating]` had its trailing attrs clobbered by the
# pre-`=` ones, so the attribute never reached the backend at all.
block:
  # 70000 into a u16 should clamp to 65535. If it wraps it becomes 4464.
  let (built, rc) = run("""
type SafeRPM = u16 [saturating]

fn main() -> int:
  let s = 70000 SafeRPM
  if s == 65535 SafeRPM:
    return 1
  return 2
""")
  bug(
    "`[saturating]` clamps at the maximum",
    "70000 into a `u16 [saturating]` should clamp to 65535; it wraps to " &
      "4464 instead. Codegen emits a bare `SafeRPM(70000)` with no clamp, " &
      "and drops `distinct` as well. Silent wrong value — no error, no trap.",
    "compiler/parser.nim type-alias attrs + codegen saturatingBase",
    fixed = true,
    built and rc == 1)   # correct = 70000 clamped to 65535

# ---------------------------------------------------------------------------
# 4b. FIXED 2026-07-22 — a saturating chain clamps against the FINAL value
# ---------------------------------------------------------------------------
# `a + b - c` (all 60000) is 60000, which fits. Per-operator saturation would
# clamp a+b to 65535 and yield 5535; the store-guard design clamps only where
# a value is stored, so transient intermediates do not corrupt the result.
block:
  let (built, rc) = run("""
type SafeRPM = u16 [saturating]

fn main() -> int:
  let a = 60000 SafeRPM
  let b = 60000 SafeRPM
  let c = 60000 SafeRPM
  let r = a + b - c
  if r == 60000 SafeRPM:
    return 1
  return 2
""")
  bug(
    "saturating chain clamps on the result, not each operator",
    "`a + b - c` with all 60000 must be 60000. Clamping at every operator " &
      "would give 5535 — an intermediate that overshoots and comes back is " &
      "not an overflow.",
    "compiler/codegen.nim genConstruction — clamp at stores only",
    fixed = true,
    built and rc == 1)

# ---------------------------------------------------------------------------
# 4c. OPEN — the Beef backend does not clamp
# ---------------------------------------------------------------------------
block:
  let dir = getTempDir() / "tuck_known_bugs_bf"
  removeDir(dir); createDir(dir)
  let f = dir / "t.tuck"
  writeFile(f, """
type SafeRPM = u16 [saturating]

fn main() -> int:
  let s = 70000 SafeRPM
  return 0
""")
  discard execCmdEx(tuckBin & " build " & f & " --beef -o:" & dir / "out")
  let bf = try: readFile(dir / "out" / "t.bf") except: ""
  bug(
    "Beef backend clamps [saturating] too",
    "The Nim backend clamps; Beef still emits a bare SafeRPM(70000). " &
      "Parity commitment: every codegen change mirrors to Beef.",
    "compiler/codegen_beef.nim — mirror saturatingBase from codegen.nim",
    fixed = false,
    bf.len > 0 and "70000" notin bf)

# ---------------------------------------------------------------------------
# 5. A type argument named like an attribute fails to parse
# ---------------------------------------------------------------------------
# The attribute-vs-generic decision is a hardcoded 19-name word list
# (parser.nim:328). Any type argument sharing a name with an attribute —
# error, stack, queue, align, priority, volatile … — is misread.
block:
  let outp = check("""
type Box[T]:
  v: T

fn take({b: Box[error]}) -> int:
  return 0

fn main() -> int:
  return 0
""")
  bug(
    "type argument may be named like an attribute",
    "`Box[error]` fails because `error` is in the attribute word list, so " &
      "the parser reads the type argument as `[error: ...]`. Same for " &
      "stack, queue, align, priority, volatile and 14 others.",
    "compiler/parser.nim:328 — decide by declared set, not a literal list",
    fixed = false,
    "Parse Error" notin outp)   # correct = it parses

# ---------------------------------------------------------------------------
# 6. FIXED 2026-07-22 — the diagnostic for bug 5 named a token, not the problem
# ---------------------------------------------------------------------------
# `Box[error]` used to fail with "Expected token 'tkColon' but got
# 'tkRBracket'", which tells the user nothing. The parse still fails (bug 5
# above), but the message now explains why and what to do.
block:
  let outp = check("""
type Box[T]:
  v: T

fn take({b: Box[error]}) -> int:
  return 0

fn main() -> int:
  return 0
""")
  bug(
    "attribute/type-argument clash explains itself",
    "The parse error for `Box[error]` must say that `error` is an attribute " &
      "name, not report a raw token mismatch.",
    "compiler/parser.nim — the isAttr branch's guard",
    fixed = true,
    "is an attribute name" in outp and "tkColon" notin outp)

# ---------------------------------------------------------------------------
# 7. FIXED 2026-07-22 — block-bodied match arms indent correctly
# ---------------------------------------------------------------------------
# Was blocking example 20. The arm emitter hardcoded `"  of "` and `"\n    "`
# as if the case sat at column 0, while a block body self-indents from
# ctx.indent — so the two disagreed whenever a match was nested in a fn.
block:
  let (ok, outp) = build("""
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
""")
  bug(
    "block-bodied match arms indent correctly",
    "A match arm with an indented block body emits an over-indented " &
      "`if true:` wrapper followed by an under-indented body, which Nim " &
      "rejects with \"expression expected, but found 'keyword of'\".",
    "compiler/codegen.nim match-arm emission — indentation of block bodies",
    fixed = true,
    ok)

# ---------------------------------------------------------------------------
# 7b. FIXED 2026-07-22 — a tail match whose arms RETURN is not re-wrapped
# ---------------------------------------------------------------------------
# injectTailReturn assumed a trailing `match subject:` always had value arms,
# so it wrapped it as `return (case ...)`. Arms that return on their own
# produce no value, and Nim rejected the case expression as untyped.
block:
  let (ok, outp) = build("""
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
""")
  bug(
    "tail match with returning arms is not double-wrapped",
    "A trailing match whose arms return must not be wrapped in another " &
      "return — `return (case ...)` asks Nim to type a case expression " &
      "whose branches never yield a value.",
    "compiler/codegen.nim injectTailReturn / matchArmsReturn",
    fixed = true,
    ok)

# ---------------------------------------------------------------------------
# 8. OPEN — `.fn {args}` on an UNDECLARED fn emits a bare field access
# ---------------------------------------------------------------------------
# Blocks example 16: `txBuf.copyFrom {data}` emits `self.txBuf.copyFrom`
# — no call, no argument. The checker types the receiver as Unknown (the
# fn is not declared anywhere), so the method form never resolves and
# codegen falls through to plain field access. A sketch-level call should
# still emit a CALL, or the checker should say the fn is undeclared.
block:
  let (ok, outp) = build("""
actor Driver [queue: 8]:
  buf: Seq[u8]

  on send({data: Seq[u8]}) -> void:
    buf.copyFrom {data}

fn main() -> int:
  return 0
""")
  bug(
    "`.fn {args}` on an undeclared fn is a call or an error",
    "`buf.copyFrom {data}` emits `self.buf.copyFrom` — a field access with " &
      "the argument dropped entirely. Either resolve it as a call or " &
      "report copyFrom as undeclared; silently emitting a field read is " &
      "neither.",
    "compiler/typecheck.nim synthFieldAccess + codegen exkField",
    fixed = false,
    ok)

# ---------------------------------------------------------------------------
# 9. FIXED 2026-07-23 — an early-return guard narrows a result
# ---------------------------------------------------------------------------
# The checker recognises only `if r.ok:` as the guard. `if not r.ok: return`
# proves presence for everything AFTER it just as well, and is the flat form
# the spec itself uses (7.2's pool example) — but reading .value after it is
# rejected. Affects !T and ?T alike, so this is general error handling, not
# a pool issue. Found while writing pool usage examples.
block:
  let (ok, outp) = build("""
fn readIt({n: int}) -> !{v: int} [io]:
  return {v: n}

fn main() -> int [io]:
  let r = {n: 5} readIt
  if not r.ok:
    return 0
  return r.value.v
""")
  bug(
    "early-return guard narrows a result",
    "`if not r.ok: return` proves the value is present for the rest of the " &
      "function, so `.value` after it must be legal. Only the nested " &
      "`if r.ok:` form is recognised today, which forces the happy path to " &
      "be indented — the opposite of what early-return is for.",
    "compiler/typecheck.nim — the .ok guard analysis",
    fixed = true,
    ok)

echo ""
echo "open bugs: ", stillBroken
if failures > 0:
  echo ""
  echo failures, " entr(ies) need attention: either a fix landed and its flag"
  echo "needs flipping to fixed = true, or a fixed bug has come back."
  quit(1)
echo "OK — open bugs still open, fixed bugs still fixed."
