## Unit tests for the D backend, grown one milestone at a time — each
## milestone of compiler/codegen_d.nim lands with its assertions here.
##
## Two layers, mirroring odin_backend:
##   * emitsD/omitsD — the emitted text says what the backend decided
##     (cheap, runs in --quick).
##   * dmd build + RUN with an exit code — the decisions actually compute
##     (a compile-only check cannot see a wrong value; exit codes can).
##
## Skips with a notice when dmd is absent, unless TUCK_REQUIRE_D=1.

import std/[os, strutils]
import ../harness

proc runsD(t: var T, name: string, want: int, dmdExe: string) =
  ## Build the current snippet's emitted D with dmd and run it, asserting
  ## the exit code. Chained through the pool: emit -> dmd build -> run.
  let e = t.needD()
  let dir = t.curDir / "dlang"
  let b = t.needCmdAfter(@[dmdExe, "-i", "-I" & dir, dir / "t.d",
                           "-of=" & dir / "prog"],
                         e, proc (dir: string) = discard, dir)
  let r = t.needCmdAfter(@[dir / "prog"], b,
                         proc (dir: string) = discard, dir)
  if t.phase == pCollect: return
  if t.skippedCmd(r): t.skip name; return
  let (brc, bout) = t.resultOf(b)
  if brc != 0:
    t.no name, "dmd build failed: " & bout.strip().splitLines()[^1]
    return
  let (rc, output) = t.resultOf(r)
  if rc == want: t.ok name
  else: t.no name, "exit " & $rc & ", want " & $want & ": " & output.strip()

proc run*(t: var T) =
  let dmdExe = findDmd()
  if dmdExe.len == 0:
    if t.phase != pReport: return
    if getEnv("TUCK_REQUIRE_D") == "1":
      echo "FAIL: dmd not found and TUCK_REQUIRE_D=1"
      t.failed.inc
      return
    echo "SKIP D backend check: dmd not found (set TUCK_REQUIRE_D=1 to require it)."
    echo "d_backend.sh: 0 passed, 0 failed"
    return

  # --- Milestone 1: plumbing ---------------------------------------------
  t.src """
import console

fn main() -> int:
  {text: "hello from tuck"} printLine
  return 7
"""
  t.emitsD "M1: entry module carries a valid D module header", "module t;"
  t.emitsD "M1: cross-module call is qualified through the import alias",
           r"console\.printLine\(""hello from tuck""\)"
  t.emitsD "M1: value-returning fn main IS the exit code, via native int main",
           r"int main\(\) \{\n    return cast\(int\) tuck_main\(\);"
  t.emitsD "M1: Tuck int maps to 64-bit long, never D's 32-bit int",
           r"long tuck_main\(\)"
  t.runsD "M1: hello world builds with dmd and exits 7", 7, dmdExe

  # --- Milestone 2: statements & scalars ---------------------------------
  # T6-T9: declarations, arithmetic, control flow, ranges. The program's
  # exit code is a sum every construct contributes to — a wrong branch, a
  # wrong range bound or 32-bit wrap moves it.
  t.src """
fn main() -> int:
  var acc = 0
  for i in 1 ..< 11:
    acc = acc + i
  let d = 55 /i 5
  let m = 55 % 7
  let neg = 0 - 3
  var w = 0
  for w < 4:
    w = w + 1
  var skipped = 0
  for i in 0 .. 4:
    if i == 2:
      continue
    skipped = skipped + 1
  return acc + d + m + neg + w + skipped
"""
  t.emitsD "M2: first assignment declares with the checker's 64-bit type",
           "long acc = 0;"
  t.emitsD "M2: exclusive range is D's native exclusive foreach",
           r"foreach \(i; 1 \.\. 11\)"
  t.emitsD "M2: inclusive range widens the upper bound by one",
           r"foreach \(i; 0 \.\. 4 \+ 1\)"
  t.emitsD "M2: while-form for emits a native while", r"while \(\(w < 4\)\)"
  t.runsD "M2: control flow and arithmetic compute 77", 77, dmdExe

  # T10 + leftovers: strings, loop:, value-if, list iteration, echo.
  t.src """
import console
import seq

fn main() -> int:
  var s = "ab"
  s = s + "cd"
  {text: s} printLine
  let n = s.len
  var c = 0
  loop:
    c = c + 1
    if c == 3:
      break
  let pick = if c == 3: 10 else: 20
  let xs = [5, 6, 7]
  var total = 0
  for x in xs:
    total = total + x
  var idxSum = 0
  for i, x in xs:
    idxSum = idxSum + i
  total echo
  return n + c + pick + total + idxSum
"""
  t.emitsD "M2: string + is D's native concat, no runtime call",
           r"s = \(s ~ ""cd""\)"
  t.emitsD "M2: len is D's native length, cast back to Tuck's signed int",
           r"cast\(long\) s\.length"
  t.emitsD "M2: value-position if is D's native ternary",
           r"\(\(c == 3\) \? 10 : 20\)"
  t.emitsD "M2: index+value loop is D's native two-variable foreach",
           r"foreach \(i, x; xs\)"
  t.emitsD "M2: echo maps to writeln", r"writeln\(total\)"
  t.omitsD "M2: nothing reaches for a runtime concat helper", "tuckConcat"
  t.runsD "M2: strings, loop and lists compute 38", 38, dmdExe

  # --- Milestone 3: records, calls, objects, aliasing --------------------
  # T11/T15: record shapes hoist as named TRec structs; pending stubs are
  # function templates returning the zero value.
  t.src """
pending:
  fn fetch({url: str}) -> {hits: int, title: str}

fn main() -> int:
  let page = {url: "x"} fetch
  return page.hits
"""
  t.emitsD "M3: record shape hoists as a named TRec struct",
           r"struct TRec_hits_title_[0-9A-F]{4} \{"
  t.emitsD "M3: pending stub is a function template",
           r"tuck_fetch\(T\)\(T payload\) \{"
  t.emitsD "M3: pending stub logs to stderr like the Nim backend",
           r"stderr\.writeln\(""TUCK PENDING: tuck_fetch invoked"
  t.emitsD "M3: pending stub returns the zero value",
           r"return typeof\(return\)\.init;"
  t.runsD "M3: pending walking skeleton runs and returns the stub zero",
          0, dmdExe

  # T16: object member fns are qualified free procs; `self` is a D ref —
  # the mutation must reach the caller's var (1 then 2, not 1 then 1).
  t.src """
object Counter:
  total: int
  step: int

  fn bump({self: Counter}) -> int:
    self ..total {self.total + self.step}
    return self.total

fn main() -> int:
  var c = {total: 0, step: 3} Counter
  let r1 = {self: c} bump
  let r2 = {self: c} bump
  return c.total + r2 - r1
"""
  t.emitsD "M3: object emits a plain struct",
           r"struct tuck_Counter \{"
  t.emitsD "M3: member fn is a qualified free proc with ref self",
           r"long tuck_Counter_bump\(ref tuck_Counter self\)"
  t.emitsD "M3: record construction is a named-argument struct literal",
           r"tuck_Counter\(total: 0, step: 3\)"
  t.runsD "M3: self mutation persists across calls (6+6-3)", 9, dmdExe

  # T17: Tuck Seq assignment copies; a bare D slice assignment would alias.
  t.src """
import seq

fn firstOf({items: Seq[int]}) -> int:
  return items[0]

fn main() -> int:
  var a = [7, 8, 9]
  var b = a
  b[0] = 50
  let x = a firstOf
  return x + a[0] + b[0]
"""
  t.emitsD "M3: Seq assignment restores value semantics with .dup",
           r"long\[\] b = \(a\)\.dup;"
  t.runsD "M3: writing b never writes a (7+7+50)", 64, dmdExe

  # --- Milestone 4: sum types and match ----------------------------------
  # T18/T19, scoped to PAYLOAD-FREE sums: payload-carrying ones do not work
  # end to end in the Nim or Odin backends either (ledger DISCOVERIES), so
  # the authority has to be fixed before a third backend can follow it.
  t.src """
type Color:
  | Red
  | Green
  | Blue

fn rank({c: Color}) -> int:
  match c:
    Red: return 1
    Green: return 2
    Blue: return 3

fn main() -> int:
  let x = Color.Green
  let y = Color.Blue
  return ({c: x} rank) * 10 + ({c: y} rank)
"""
  t.emitsD "M4: a payload-free sum is a plain D enum",
           r"enum tuck_Color \{ Red, Green, Blue \}"
  t.emitsD "M4: match is a final switch — D re-checks the arms are exhaustive",
           r"final switch \(c\) \{"
  t.emitsD "M4: a bare tag qualifies to its enum, which D requires",
           r"case tuck_Color\.Red:"
  t.runsD "M4: match dispatches to the right arm (2*10+3)", 23, dmdExe

  # A match in VALUE position: D has no switch-expression, so the arms go
  # into an immediately-called lambda — which keeps the exhaustiveness check
  # that Odin's chained-ternary lowering loses.
  t.src """
type Color:
  | Red
  | Green
  | Blue

fn main() -> int:
  let c = Color.Green
  let code = match c:
    Red: 1
    Green: 2
    Blue: 3
  return code
"""
  t.emitsD "M4: value-position match keeps the exhaustive switch in a lambda",
           r"\(\(\) \{ final switch \(c\) \{"
  t.omitsD "M4: no chained ternary for a value match", r"\? 1 :"
  t.runsD "M4: value-position match yields the arm's value", 2, dmdExe

  t.finish()
