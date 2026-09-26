## `invariant:` — the runtime asserts the compiler inserts wherever a value of
## the type is PRODUCED (spec 4.7).
##
## The checker-level rules (TK-IV01 a predicate naming a field the type lacks,
## TK-IV02 a non-boolean predicate) live in `declarations`. This suite is the
## other half: does the assert actually fire, at every site the spec claims,
## and is it reachable from every backend.
##
## `cli_smoke` already covers construction, return, `..` mutation and the
## `!T` wrap — on Nim only, because that is the backend it builds. What is
## here is the sites nobody covered, each with `hostBuilds` so a site that
## works on Nim and not elsewhere is a failure rather than a silence.
##
## A VIOLATION IS THE SAME ON EVERY BACKEND: `Invariant violated on <type>:
## <cond>` and exit 1 (the project rule `hostRuns` enforces). Odin used to
## emit a bare `assert` (SIGILL, exit 132) and D to `abort()` (134) — #43.
##
## THE OPT-OUT: the 2026-08-25 ruling made invariants survive `--release`
## behind a `tuckNoInvariants` define, which every backend now emits a guard
## for (Nim `when not defined`, D `version`, Odin `#config`) and which is
## asserted at the end. How `tuck build` sets it is still open (#43): today
## only Nim's `--nim:` passthrough reaches it.

import std/[os, strutils]
import ../harness

proc runsOdinWith(t: var T, name: string, want: int, flags: seq[string],
                  tag: string) =
  ## Build the current snippet's Odin with extra `odin build` flags and run
  ## it — a build MODE asserted, as d_backend's runsDWith does for dmd. The
  ## binary is named per tag so two modes of one snippet do not collide.
  let odinExe = findOdin()
  if odinExe.len == 0:
    if t.phase != pCollect: t.skip name
    return
  let e = t.needOdin()
  let proj = t.curDir / "odinpkg"
  let src = t.curDir / "odin" / "t.odin"
  let bin = proj / ("prog_" & tag)
  let b = t.needCmdAfter(@[odinExe, "build", proj, "-o:none", OdinThreads] &
                         flags & @["-out:" & bin], e,
                         proc (dir: string) = stageOdinPkg(dir, src), proj)
  let r = t.needCmdAfter(@["timeout", "10", bin], b,
                         proc (dir: string) = discard, proj, verb = vRun)
  if t.phase == pCollect: return
  if t.skippedCmd(r): t.skip name; return
  let (brc, bout) = t.resultOf(b)
  if brc != 0:
    t.no name, "odin build failed: " & bout.strip().splitLines()[^1]
    return
  let (rc, _) = t.resultOf(r)
  if rc == want: t.ok name
  else: t.no name, "exit " & $rc & ", want " & $want

proc run*(t: var T) =
  const temp = """
type Temp:
  celsius: int
  invariant:
    celsius >= -273
"""

  # --- a Seq element is a production site ---------------------------------
  t.src temp & """
fn main() -> int:
  let xs = [{celsius: -400} Temp]
  return 0
"""
  t.runs "an invariant fires on a Seq element", 1
  t.outputs "...naming the type and the predicate", "Invariant violated"
  t.hostBuilds "...and every backend emits it"

  # --- a `..` chain validates ONCE, when it ends -----------------------------
  #
  # A builder's intermediate states need not hold the invariant; the value it
  # builds must. `r ..lo {5} ..hi {10}` passes through lo=5, hi=1 on its way
  # to a valid range. Each backend printed the chain itself and each validated
  # at the end; lowered to plain assignments (lowering_chains), a field step
  # would re-validate on its own — so a step is marked `inChain`, and one
  # `exkValidate` closes the chain.
  const rng = """
type Range:
  lo: int
  hi: int
  invariant:
    lo <= hi
"""
  t.src rng & """
fn main() -> int:
  var r = {lo: 0, hi: 1} Range
  r ..lo {5} ..hi {10}
  return r.lo + r.hi
"""
  t.hostRuns "a chain may pass through an invalid state on its way", 15

  t.src rng & """
fn main() -> int:
  var r = {lo: 0, hi: 1} Range
  r ..lo {5}
  return r.lo + r.hi
"""
  t.runs "...but a chain that ENDS invalid fires", 1
  t.outputs "...naming the predicate", "Invariant violated"
  t.hostBuilds "...and every backend emits the check"

  # --- a decision table's cell is a return site ---------------------------
  t.src temp & """
decision pick({hot: bool}) -> Temp:
  | true  -> {celsius: -400} Temp
  | false -> {celsius: 0} Temp

fn main() -> int:
  let t = {hot: true} pick
  return 0
"""
  t.runs "an invariant fires on a decision table's cell", 1
  t.hostBuilds "...on every backend"

  # --- a task's return value ----------------------------------------------
  t.src temp & """
task read() -> Temp [io]:
  return {celsius: -400} Temp

fn main() -> int [io]:
  let t = {} read
  return 0
"""
  t.runs "an invariant fires on a task's return", 1
  t.hostBuilds "...on every backend"

  # --- wrapping into an interface -----------------------------------------
  # The interface copies the value in, which is a production site for the
  # copy. An object carrying a bad field cannot be laundered through a
  # contract.
  t.src temp & """
interface Reads:
  fn value({self: Self}) -> int

object Sensor:
  satisfies Reads
  t: Temp
  fn value({self: Sensor}) -> int:
    return self.t.celsius

fn take({r: Reads}) -> int:
  return r.value

fn main() -> int:
  let bad = {celsius: -400} Temp
  let s = {t: bad} Sensor
  return {r: s} take
"""
  t.runs "an invariant fires before a value reaches an interface", 1
  t.hostBuilds "...on every backend"

  # --- and it does NOT fire where nothing is produced ----------------------
  # A copy of an already-valid value is not a production site: it was checked
  # when it was made. An invariant that fired here would be pure overhead.
  t.src temp & """
fn main() -> int:
  let a = {celsius: 7} Temp
  let b = a
  return b.celsius
"""
  t.runs "copying a valid value does not re-validate", 7
  t.hostBuilds "...on every backend"

  # --- the ASSIGNMENT form of a mutation, fixed 2026-09-13 ----------------
  # `t ..celsius {-400}` always validated; `t.celsius = -400` did not, on any
  # backend, so spec 4.7's "after mutation" was only half true. Both spellings
  # are mutation sites and both now re-validate, through one shared decision
  # (codegen_common.assignInvariantOwner) so the backends cannot drift again.
  t.src temp & """
fn main() -> int:
  var t = {celsius: 0} Temp
  t.celsius = -400
  return 0
"""
  t.runs "an invariant fires after a field assignment", 1
  t.outputs "...with the same message the chain form gives", "Invariant violated"
  t.hostBuilds "...on every backend"
  t.bugFixed "an invariant fires after a field assignment"

  # --- gap 2: a pool handed out an unvalidated slot -------------------------
  # A cell is zeroed storage. With an invariant the zero value violates, the
  # program could read a value of the type that breaks its own contract —
  # the one thing an invariant exists to prevent (issue #42).
  #
  # Ruled 2026-09-26: a cell STARTS ABSENT, so `read` is a `?T` and the zero
  # is never read as a value at all. What a cell does hold was written by
  # `write`, whose value is a construction, validated where it is built; and
  # `addr`, the one way in that skips a construction, is refused for an
  # invariant-carrying element (TK-TY31, tests/suites/pools.nim).
  t.src """
type Live:
  n: int
  invariant:
    n > 0

pool Slots = Live [count: 2]

fn main() -> int:
  let s = Slots.acquire
  if not s.ok:
    return 9
  let c = Slots.read {h: s.value}
  if c.ok:
    return c.value.n
  return 7
"""
  t.quietly: t.hostRuns("a pool slot is validated before it is handed out", 7)
  t.bugFixed "a pool slot is validated before it is handed out"

  # ...and a value written into a cell is a construction, so an invalid one
  # stops at the construction, before it reaches the cell.
  t.src """
type Live:
  n: int
  invariant:
    n > 0

pool Slots = Live [count: 2]

fn main() -> int:
  let s = Slots.acquire
  if not s.ok:
    return 9
  let bad = {n: 0} Live
  Slots.write {h: s.value, value: bad}
  return 0
"""
  t.hostRuns "an invalid value never reaches a cell", 1, "Invariant violated"

  # An invariant is validated ONCE for one construction (issue #51). Two
  # independent rules each wrapped the expression and neither knew the other
  # had: a construction of an invariant-carrying type validates at the
  # construction site, and a fn returning such a type validates on the way
  # out. `return {n: v} Live` satisfied both and got both —
  # `__validated_T(__validated_T(T{...}))`, on a value nothing touched in
  # between.
  #
  # Nothing in examples/ returns a constructed invariant type from a fn, so
  # re-emitting the corpus produced no diff at all and would never have
  # caught this.
  t.src """
type Live:
  n: int
  invariant:
    n > 0

fn make({v: int}) -> Live:
  return {n: v} Live

fn main() -> int:
  let a = {v: 5} make
  return a.n
"""
  t.runs "a constructed invariant type returned from a fn runs", 5
  t.hostBuilds "...on every backend"
  # The SECOND temp only exists when the value was wrapped twice.
  t.omits "...validated once, not twice (Nim)", "tuckInv2"
  t.omitsOdin "...validated once, not twice (Odin)",
              "__validated_tuckˑtypeˑLive\\(__validated_"

  # ...and the invariant still FIRES. Dropping a wrap must not drop the check.
  t.src """
type Live:
  n: int
  invariant:
    n > 0

fn make({v: int}) -> Live:
  return {n: v} Live

fn main() -> int:
  let a = {v: 0} make
  return a.n
"""
  t.hostRuns "...and a violated invariant still aborts", 1,
             "Invariant violated on tuckˑtypeˑLive"

  # A return that is NOT a construction keeps its wrap: nothing proves where
  # that value came from, so it is still checked on the way out.
  t.src """
type Live:
  n: int
  invariant:
    n > 0

fn passThrough({x: Live}) -> Live:
  return x

fn main() -> int:
  let a = {n: 5} Live
  let b = {x: a} passThrough
  return b.n
"""
  t.emits "a variable return is still validated", "validate\\(tuckInv1\\)"
  t.emitsOdin "...on Odin too", "__validated_tuckˑtypeˑLive\\(x\\)"

  # --- the opt-out (#43) ----------------------------------------------------
  # Every backend guards its checks behind `tuckNoInvariants`, so a build may
  # strip them — and only a build that asks. Odin's used to be a bare
  # `assert`: no guard, SIGILL instead of the message, and gone under
  # `-disable-assert` whether or not anyone asked.
  t.src temp & """

fn main() -> int:
  let t = {celsius: -300} Temp
  return 7
"""
  t.hostRuns "a violation reads the same on every backend", 1,
             "Invariant violated on tuckˑtypeˑTemp: \\(self\\.celsius >= -273"
  t.emitsOdin "Odin guards its checks behind the opt-out",
              r"when !#config\(tuckNoInvariants, false\)"
  t.omitsOdin "...and not with `assert`, which -disable-assert strips",
              r"\bassert\("
  t.runsOdinWith "Odin keeps the check under -disable-assert", 1,
                 @["-disable-assert"], "noassert"
  t.runsOdinWith "Odin strips it only when the build opts out", 7,
                 @["-define:tuckNoInvariants=true"], "off"

  t.finish()
