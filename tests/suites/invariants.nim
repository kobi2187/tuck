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
## THE OPT-OUT IS NOT SYMMETRIC, and that is recorded rather than asserted:
## the 2026-08-25 ruling made invariants survive `--release` behind a
## `tuckNoInvariants` opt-out. Nim honours it and `--nim:` can set it; D emits
## the guard but `tuck build` has no `--dmd:` to reach it; Odin emits a bare
## `assert` with no guard at all. See the bugOpen at the end.

import ../harness

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

  # --- gap 2: a pool hands out an unvalidated slot -------------------------
  # `acquire` yields a zeroed slot. With an invariant the zero value violates,
  # the program can read a value of the type that breaks its own contract —
  # which is the one thing an invariant exists to prevent.
  t.src """
type Live:
  n: int
  invariant:
    n > 0

pool Slots = Live [count: 2]

fn main() -> int:
  let s = Slots.acquire
  if s.ok:
    return s.value.n
  return 7
"""
  t.quietly: t.runs "a pool slot is validated before it is handed out", 1
  t.bugOpen "a pool slot is validated before it is handed out"

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
  t.runs "...and a violated invariant still aborts", 1

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

  t.finish()
