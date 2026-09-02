## Smoke test for the tuck CLI: runs every command, checks fail-fast.
##
## The one suite that does not use the assertion DSL. Its cases are SEQUENCES —
## write a source, build it, run the binary, grep what it printed, then again
## with a different source — where each step needs the one before. The DSL's
## collect/report split is for assertions whose work is independent, so these
## stay imperative exactly as the bash was, with tests/suites/smokelib.nim
## holding the idioms they repeat.
##
## Each case raises SmokeFail on the first thing that is wrong, which is
## `set -e` plus `exit 1` in a subshell; the runner below catches per case so
## one failure does not hide the other twenty-four.
##
## The cases are independent — each owns tests/.smoke_<name> and shares nothing
## writable — so they run one per core, as the bash ran them as background jobs.
## That matters because this suite is ~31 `tuck build` calls and a build is
## ~1.05s of `nim c` compiling and linking, against ~5ms for a `tuck ch`. The
## builds ARE the suite's runtime, and serially they were 36.6s with five cores
## idle.

import std/[os, strutils]
import ../harness
import smokelib

# --- individual cases ------------------------------------------------------

proc caseInv(w: Work) =
  # invariants: validate() auto-inserted at construction and return sites
  let d = caseDir("inv")
  const body = """
type Temperature:
  celsius: int
  invariant:
    celsius >= -273
"""
  buildOk(d.write("viol.tuck", body & """
fn main() -> void:
  let t = {celsius: -400} Temperature
  return
"""), d / "out")
  mustAbort(d / "out" / "viol", "Invariant violated")

  buildOk(d.write("ok.tuck", body & """
fn freeze() -> Temperature:
  return {celsius: 0} Temperature

fn main() -> void:
  let t = {} freeze
  return
"""), d / "out2")
  mustExit(d / "out2" / "ok", 0)

  # mutation site: `..` on an invariant-carrying var validates after the chain
  buildOk(d.write("mut.tuck", body & """
fn main() -> void:
  var t = {celsius: 0} Temperature
  t ..celsius {-400}
  return
"""), d / "out3")
  mustAbort(d / "out3" / "mut", "Invariant violated")

  # !T-wrapped return: the payload validates before tok() wraps it
  buildOk(d.write("wrap.tuck", body & """
fn read() -> !Temperature [io]:
  return {celsius: -400} Temperature

fn main() -> void [io]:
  let r = {} read
  return
"""), d / "out4")
  mustAbort(d / "out4" / "wrap", "Invariant violated")

  # extern boundary: a call to an extern fn returning an invariant-carrying
  # type validates at the call site (emission check — no rt impl to run)
  discard compileTo(d.write("ext.tuck", body & """
extern:
  fn readSensor({pin: int}) -> Temperature

fn main() -> void:
  let t = {pin: 3} readSensor
  return
"""), d / "out5")
  mustContain(d / "out5" / "ext.nim", "validate(")
  removeDir(d)

proc caseTdl(w: Work) =
  # type-directed lowering: record var as whole payload explodes to params
  let d = caseDir("tdl")
  buildOk(d.write("p.tuck", """
type Player = {position: int, step: int}

fn advance({position: int, step: int}) -> int:
  return position + step

fn main() -> void:
  let p = {position: 10, step: 5} Player
  let n = p advance
  return
"""), d / "out")
  mustContain(d / "out" / "p.nim", "advance(p.position, p.step)")
  mustExit(d / "out" / "p", 0)
  removeDir(d)

proc caseChaintail(w: Work) =
  # `..` chain as the fn's tail: mutate a local copy, which is the chain's
  # implicit result.
  #
  # Was `self ..n {41}` straight on the parameter. That stopped compiling when
  # parameters became immutable values (spec §7.1) — a mutator copies first
  # and returns the copy, so the caller's record is never written through.
  # What this case is actually for (a chain in tail position IS the return
  # value) is unchanged.
  let d = caseDir("chaintail")
  buildOk(d.write("t.tuck", """
import sys

type Counter:
  n: int

fn bump({self: Counter}) -> Counter:
  var s = self
  s ..n {41}

fn main() -> void [io]:
  var c = {n: 0} Counter
  c ..bump ..n {42}
  c.n sys::exit
"""), d / "out")
  mustExit(d / "out" / "t", 42)
  removeDir(d)

proc caseErrmatch(w: Work) =
  # match over r.err: arms compile to hashed code constants, branch correctly
  let d = caseDir("errmatch")
  buildOk(d.write("t.tuck", """
import sys

type ParseError:
  | Empty
  | TooLong

fn parseTitle({raw: str}) -> !str [io, error: ParseError]:
  if raw == "":
    err Empty
  return raw

fn main() -> void [io]:
  let r = {raw: ""} parseTitle
  if r.ok:
    0 sys::exit
  match r.err:
    Empty: 42 sys::exit
    TooLong: 7 sys::exit
"""), d / "out")
  mustExit(d / "out" / "t", 42)
  removeDir(d)

proc caseTour123(w: Work) =
  # toStr + string concat + list literals + for loops (tour gaps 1-3)
  let d = caseDir("tour123")
  buildOk(d.write("t.tuck", """
import console
import str
import sys

type Episode:
  minutes: int

fn main() -> void [io]:
  let name = "tuck"
  {text: "hello, " + name} console::printLine
  let n = 42
  {text: n.toStr} console::printLine
  let eps = [{minutes: 10} Episode, {minutes: 32} Episode]
  var total = 0
  for e in eps:
    total = total + e.minutes
  total sys::exit
"""), d / "out")
  let (rc, outp) = exec(d / "out" / "t")
  if not outp.contains("hello, tuck"): fail "concat output"
  var sawBare42 = false
  for l in outp.splitLines():
    if l.strip() == "42": sawBare42 = true
  if not sawBare42: fail "toStr output"
  if rc != 42: fail "list/for sum exit " & $rc & ", want 42"
  removeDir(d)

proc caseErrname(w: Work) =
  # unhandled report names the error via the reverse table (debug builds)
  let d = caseDir("errname")
  buildOk(d.write("t.tuck", """
errors [policy: continue]:
  on unhandled({code: u16, site: str}):
    ...

type ParseError:
  | Empty

fn parseTitle({raw: str}) -> !str [io, error: ParseError]:
  if raw == "":
    err Empty
  return raw

fn main() -> void [io]:
  {raw: ""} parseTitle
  return
"""), d / "out")
  let (_, outp) = exec(d / "out" / "t")
  if not outp.contains("TUCK ERROR NAME: t/ParseError.Empty"):
    fail "unhandled report missing error name"
  removeDir(d)

proc caseLib(w: Work) =
  # top-level statements are declarations-only violations; library builds
  let d = caseDir("lib")
  let bad = d.write("bad.tuck", "fn f({a: int}) -> int:\n  return a\n\nlet x = {a: 1} f\n")
  let (brc, bout) = check(bad)
  if brc == 0: fail "top-level statement accepted"
  if not bout.contains("top-level statements"): fail "wrong top-level error"

  let libmod = d.write("libmod.tuck", "fn helper({a: int}) -> int:\n  return a\n")
  let (_, lout) = build(libmod, d / "out")
  if not lout.contains("library (no fn main)"): fail "library build message missing"
  if not fileExists(d / "out" / "libmod.nim"): fail "library did not emit Nim"
  if fileExists(d / "out" / "libmod"): fail "library build produced a binary"
  removeDir(d)

  # (the Beef backend was removed in 7c84d1f; its --beef check lived here and
  # went with it. It had been unreachable anyway — the err-match check above
  # aborted this script long before reaching it.)

proc caseCtrlflow(w: Work) =
  # control flow: loop/break, for-cond, continue, ranges, indexed for, fn inline
  let d = caseDir("ctrlflow")
  buildOk(d.write("cf.tuck", """
fn inline bump({x: int}) -> int:
  return x + 1

fn main() -> int:
  var acc = 0
  loop:
    acc += 1
    if acc == 5:
      break
  for acc > 3:
    acc -= 1
  for i in 0 ..< 4:
    if i == 2:
      continue
    acc += i
  for i in 1 .. 3:
    acc += i
  let xs = [10, 20, 30]
  for idx, item in xs:
    acc += idx
  return bump {x: acc}
"""), d / "out")
  mustExit(d / "out" / "cf", 17)
  mustContain(d / "out" / "cf.nim", "{.inline.}")
  removeDir(d)

proc caseValuetype(w: Work) =
  # records are VALUE types (spec §7.1): == compares fields, not identity, a
  # copy is independent of its source, and PASSING one to a fn does not let
  # that fn write back through it.
  #
  # `shift` used to be `p ..x {99}` — mutating the parameter directly, which
  # the emitter turned into a `var` (by-reference) param, so the caller's
  # record changed. The case asserting value semantics was itself violating
  # them. It now copies, and the caller checks its own value survived.
  let d = caseDir("valuetype")
  buildOk(d.write("t.tuck", """
type Point = {x: int, y: int}

fn shift({p: Point}) -> Point:
  var s = p
  s ..x {99}

fn main() -> int:
  let a = {x: 1, y: 2} Point
  let b = {x: 1, y: 2} Point
  var acc = 0
  if a == b:
    acc += 10
  var c = {x: 1, y: 2} Point
  let d = c
  c ..x {50}
  if d.x == 1:
    acc += 7
  var e = {x: 1, y: 2} Point
  let moved = {p: e} shift
  if e.x == 1 and moved.x == 99:
    acc += 5
  return acc
"""), d / "out")
  mustExit(d / "out" / "t", 22)
  mustContain(d / "out" / "t.nim", "= object")
  removeDir(d)

proc caseNullary(w: Work) =
  # spec 2.3: a bare name IS a call — a zero-arg fn referenced bare must be
  # invoked, not taken as a proc reference (`:name` is the fn-ref form)
  let d = caseDir("nullary")
  buildOk(d.write("t.tuck", """
fn getFive() -> int:
  return 5

fn getSeven() -> int:
  return 7

fn main() -> int:
  let a = getFive
  let b = getSeven {}
  return a + b
"""), d / "out")
  mustExit(d / "out" / "t", 12)
  removeDir(d)

proc caseMatchret(w: Work) =
  # a trailing `match subject:` IS the fn's result — its value arms carry no
  # returns of their own, so the implicit-return rewrite must wrap the match
  let d = caseDir("matchret")
  buildOk(d.write("t.tuck", """
type Light:
  | Red
  | Yellow
  | Green

fn code({t: Light}) -> int:
  match t:
    Red: 3
    Yellow: 5
    Green: 9

fn main() -> int:
  return {t: Light.Green} code
"""), d / "out")
  mustExit(d / "out" / "t", 9)
  removeDir(d)

proc caseSeqat(w: Work) =
  # std/seq: indexed read/write as named fns (`at`/`setAt`), not `[]` sugar.
  # Bounds are a precondition — out of range aborts at the call site.
  let d = caseDir("seqat")
  buildOk(d.write("t.tuck", """
import seq

fn main() -> int:
  var xs = [10, 20, 30]
  {items: xs, index: 1, value: 5} seq::setAt
  let a = {items: xs, index: 0} seq::at
  let b = {items: xs, index: 1} seq::at
  let c = {items: xs, index: 2} seq::at
  return a + b + c
"""), d / "out")
  mustExit(d / "out" / "t", 45)

  buildOk(d.write("oob.tuck", """
import seq

fn main() -> int:
  var xs = [10, 20, 30]
  return {items: xs, index: 7} seq::at
"""), d / "oout")
  mustAbort(d / "oout" / "oob", "out of bounds for seq of length 3")
  removeDir(d)

proc caseIndex(w: Work) =
  # bracket sugar: xs[i] reads, xs[i] = v writes, xs[i] += v compounds.
  # All desugar to the seq::at / seq::setAt calls above — same bounds
  # precondition, no new codegen path.
  let d = caseDir("index")
  buildOk(d.write("t.tuck", """
import seq

fn main() -> int:
  var xs = [10, 20, 30]
  xs[1] = 5
  xs[0] += 5
  return xs[0] + xs[1] + xs[2]
"""), d / "out")
  mustExit(d / "out" / "t", 50)

  # the tight-`[` rule must not eat list literals or generic/type brackets
  buildOk(d.write("amb.tuck", """
import seq

fn firstOf[T]({items: Seq[T]}) -> T:
  return {items: items, index: 0} seq::at

fn main() -> int:
  let ys = [1, 2, 3]
  var grid = [7, 8, 9]
  let a = {items: ys} firstOf
  return a + grid[2] + ys[1]
"""), d / "aout")
  mustExit(d / "aout" / "amb", 12)

  # bounds still fire through the sugar
  buildOk(d.write("oob.tuck", """
import seq

fn main() -> int:
  var xs = [10, 20, 30]
  return xs[7]
"""), d / "oout")
  mustAbort(d / "oout" / "oob", "out of bounds for seq of length 3")

  # a non-indexable receiver names the type and the fn to define
  let bad = d.write("bad.tuck", """
fn main() -> int:
  let n = 5
  return n[0]
""")
  let (rc, outp) = check(bad)
  if rc == 0: fail "indexing an int was accepted"
  if not outp.contains("not indexable"): fail "wrong non-indexable error"
  removeDir(d)

proc casePool(w: Work) =
  # spec 7.2 pools: declaration diagnostics, and a real acquire/release cycle.
  let d = caseDir("pool")

  # a pool needs a count — without one it has no static footprint
  block:
    let (rc, outp) = check(d.write("nocount.tuck",
      "pool Bufs = Array[8, u8]\n\nfn main() -> int:\n  return 0\n"))
    if rc == 0: fail "pool without a count was accepted"
    if not outp.contains("needs a slot count"): fail "wrong no-count error"

  # ... and the count must be a number
  block:
    let (rc, outp) = check(d.write("badcount.tuck",
      "pool Bufs = Array[8, u8] [count: many]\n\nfn main() -> int:\n  return 0\n"))
    if rc == 0: fail "non-numeric count accepted"
    if not outp.contains("whole number"): fail "wrong bad-count error"

  # a pool declares an element type
  block:
    let (rc, outp) = check(d.write("noelem.tuck",
      "pool Bufs [count: 8]\n\nfn main() -> int:\n  return 0\n"))
    if rc == 0: fail "pool without an element type accepted"
    if not outp.contains("declares its element type"): fail "wrong no-element error"

  # runtime: acquire to exhaustion, release, acquire again
  buildOk(d.write("t.tuck", """
type Slot:
  id: int

pool Slots = Slot [count: 2]

fn main() -> int:
  let a = Slots.acquire
  let b = Slots.acquire
  if not a.ok:
    return 91
  if not b.ok:
    return 92
  let c = Slots.acquire        # pool of 2 is exhausted
  if c.ok:
    return 93
  Slots.release {a.value}      # give one back
  let d = Slots.acquire        # ... so this must succeed
  if not d.ok:
    return 94
  return 42
"""), d / "out")
  mustExit(d / "out" / "t", 42)
  removeDir(d)

proc example(w: Work) =
  ## The `case_eNN` family: build one example and check its exit code. Nine
  ## near-identical functions in the bash, one proc over a table here.
  let d = caseDir(w.name)
  buildOk(w.src, d / "out")
  mustExit(d / "out" / w.binary, w.want)
  removeDir(d)

proc caseEffects(w: Work) =
  # Effects cross the module boundary, from source AND from the cached index.
  # Both paths must reject identically: a pure fn calling an imported [io] fn is
  # an error whether the callee was just parsed or restored from .tuck-cache.
  # Run twice on purpose — the second run is the one that reads the index.
  let d = caseDir("effects")
  discard d.write("lib.tuck", "fn noisy(value: int) -> int [io]:\n  return value + 1\n")
  let bad = d.write("bad.tuck", """
import lib

fn pure(value: int) -> int:
  return value noisy

fn main() -> void:
  return
""")
  let good = d.write("good.tuck", """
import lib

fn wrapper(value: int) -> int [io]:
  return value noisy

fn main() -> void [io]:
  return
""")
  # warms the index for lib
  if sh(@["./tuck", "ch", good, "--root:" & d]).rc != 0:
    fail "correctly-declared [io] propagation rejected"
  for pass in ["cold", "warm"]:
    let (rc, outp) = sh(@["./tuck", "ch", bad, "--root:" & d])
    if rc == 0: fail "imported [io] not enforced on " & pass & " cache"
    if not outp.contains("requires effect [io]"):
      fail "wrong error for imported [io] on " & pass & " cache"
  if sh(@["./tuck", "ch", good, "--root:" & d]).rc != 0:
    fail "good case broke after index warm"
  removeDir(d)

proc caseBytype(w: Work) =
  # Payload fields matched to params BY TYPE, with a struct LITERAL receiver.
  # The checker matches by name first, then by type for whatever is left
  # (typecheck.nim checkCallArgs pass 2), so `alpha` legitimately feeds `first`.
  # Lowering has to use that mapping rather than re-deriving it by name — when it
  # re-derived, nothing matched and every argument became the literal `none`,
  # which the type checker had already waved through. A variable receiver took a
  # different path and was always correct, which is why this went unnoticed:
  # the exit code below is 42 only if all three arguments arrive in order.
  let d = caseDir("bytype")
  buildOk(d.write("t.tuck", """
import sys

fn pick({first: int, second: str, third: bool}) -> int:
  if third:
    return first
  return 0

fn main() -> void [io]:
  let r = {alpha: 42, beta: "x", gamma: true} pick
  r sys::exit
"""), d / "out")
  mustContain(d / "out" / "t.nim", "tuck_pick(42, \"x\", true)")
  mustExit(d / "out" / "t", 42)
  removeDir(d)

# --- the suite -------------------------------------------------------------

proc run*(t: var T) =
  if t.phase != pReport: return

  # This suite is ~100 SEQUENTIAL `tuck build` + run steps driven through `sh`,
  # which executes immediately and so cannot be filtered by the work pool. It
  # dominates a full run, and every case here is a backend compile by nature,
  # so the cheap modes skip it wholesale rather than pretending to filter it.
  if not buildsAllowed():
    t.skip "cli_smoke (every case builds and runs a binary)"
    t.finish()
    return

  # The CLI's own surface, before the cases: every verb runs, and a type error
  # exits nonzero with a file:line:col prefix.
  block:
    for verb, ex in {"l": "07-comments", "p": "07-comments",
                     "ch": "01-data-flow"}.items:
      if sh(@["./tuck", verb, "examples/" & ex & ".tuck"]).rc != 0:
        t.no "tuck " & verb & " runs", "nonzero exit on examples/" & ex
        t.finish()
        return

    let d = caseDir("cli")
    if sh(@["./tuck", "c", "examples/07-comments.tuck", "-o:" & d]).rc != 0 or
       not fileExists(d / "07-comments.nim"):
      t.no "tuck c emits", "no 07-comments.nim"
      t.finish()
      return

    # --verify-stages: diagnostic assertions (compiler/pipeline.nim) must not
    # false-positive on real, working code. 28-async-task exercises an [io]
    # async task without needing a dedicated fixture.
    #
    # NOT 29-task-timeout (the original fixture here): assertNoUnknownTypes
    # (added 2026-09-01) found it — and 15 other examples — genuinely leak
    # the checker's <unknown> marker past typecheck, via `on select`'s
    # return-type handling in 29's case. Real, pre-existing gaps, not a test
    # fixture problem — see TODO.md's "assertNoUnknownTypes found 16
    # examples leaking <unknown>" entry for the full list before picking a
    # different example back up here.
    if sh(@["./tuck", "c", "examples/28-async-task.tuck", "--verify-stages",
            "-o:" & d, "--root:" & getCurrentDir()]).rc != 0:
      t.no "tuck c --verify-stages", "nonzero exit on a working example"
      t.finish()
      return

    # The other direction: assertNoUnknownTypes must actually FIRE on a real
    # gap. A bare identifier resolving to nothing rides synthBareVariant's
    # silent fallback all the way to `tuck ch` exit 0 WITHOUT the flag; WITH
    # it, the checker's own <unknown> marker on that exact node must be
    # caught before typecheck's caller ever sees a clean result.
    let undefSrc = d.write("undef.tuck",
      "fn main() -> int:\n  totallyUndefinedName\n  0\n")
    if sh(@["./tuck", "ch", undefSrc]).rc != 0:
      t.no "assertNoUnknownTypes: baseline", "an undefined bare name should " &
           "still typecheck clean WITHOUT --verify-stages (checker gap, not fixed here)"
      t.finish()
      return
    let (vrc, vout) = sh(@["./tuck", "ch", undefSrc, "--verify-stages"])
    if vrc == 0 or "<unknown>" notin vout:
      t.no "assertNoUnknownTypes: catches it", "expected a nonzero exit " &
           "naming <unknown>, got rc=" & $vrc & ": " & vout.splitLines()[^1]
      t.finish()
      return

    # 14-task.tuck was one of the 16 examples assertNoUnknownTypes caught
    # (found via rr + a breakpoint on unknownType — the exact call site was
    # asResultIntrospection's `.err` arm, self-documented as "code;
    # enum-typed later" and never finished). Now fixed to yield u16 (the
    # runtime's TuckResult.err field type); this is its regression guard.
    if sh(@["./tuck", "ch", "examples/14-task.tuck", "--verify-stages",
            "--root:" & getCurrentDir()]).rc != 0:
      t.no "assertNoUnknownTypes: .err is typed, not <unknown>",
           "examples/14-task.tuck (err resp.err) should pass --verify-stages now"
      t.finish()
      return

    # tuck dump: a thin driver stopping early in the same pipeline, at two
    # ends of it — a bare parse-adjacent stage and the final emitted source.
    for stage in ["load", "emitting"]:
      let (drc, dout) = sh(@["./tuck", "dump", "examples/07-comments.tuck",
                             "--stage:" & stage, "--root:" & getCurrentDir()])
      if drc != 0 or dout.strip().len == 0:
        t.no "tuck dump --stage:" & stage, "nonzero exit or empty output"
        t.finish()
        return

    # fail-fast: type error must exit nonzero with file:line:col
    let bad = d.write("bad.tuck", "fn f({a: int}) -> int:\n  return \"nope\"\n")
    let (rc, outp) = check(bad)
    if rc == 0:
      t.no "tuck ch fails fast", "expected nonzero exit on type error"
      t.finish()
      return
    if not outp.contains("bad.tuck:2:"):
      t.no "tuck ch fails fast", "no file:line:col prefix"
      t.finish()
      return
    removeDir(d)

  let cases = {
    "case_inv": caseInv, "case_tdl": caseTdl, "case_chaintail": caseChaintail,
    "case_errmatch": caseErrmatch, "case_tour123": caseTour123,
    "case_errname": caseErrname, "case_lib": caseLib,
    "case_ctrlflow": caseCtrlflow, "case_valuetype": caseValuetype,
    "case_nullary": caseNullary, "case_matchret": caseMatchret,
    "case_seqat": caseSeqat, "case_index": caseIndex, "case_pool": casePool,
    "case_effects": caseEffects, "case_bytype": caseBytype,
  }

  # The example family: build one example, check its exit code. Nine
  # near-identical functions in the bash, one table here.
  let examples = {
    "e25": ("examples/25-pools.tuck", "m_25_pools", 4),
    "e26": ("examples/26-actor-run.tuck", "m_26_actor_run", 55),
    "e27": ("examples/27-actor-select.tuck", "m_27_actor_select", 55),
    "e28": ("examples/28-async-task.tuck", "m_28_async_task", 42),
    "e29": ("examples/29-task-timeout.tuck", "m_29_task_timeout", 2),
    "e30": ("examples/30-async-read.tuck", "m_30_async_read", 1),
    "e31": ("examples/31-fnsig-callback.tuck", "m_31_fnsig_callback", 42),
    "e32": ("examples/32-duration-units.tuck", "m_32_duration_units", 42),
    "e43": ("examples/43-literal-payload.tuck", "m_43_literal_payload", 40),
  }

  var work: seq[Work]
  for (name, body) in cases.items:
    work.add Work(name: name, body: body)
  for (tag, spec) in examples.items:
    let (src, binary, want) = spec
    work.add Work(name: tag, body: example, src: src, binary: binary, want: want)

  let failures = runParallel(work)

  # Reported in the same shape as the DSL suites so the runner's summary line
  # matches uniformly. This suite asserts with explicit failures rather than
  # the harness's counters, so the count is its own.
  t.failed = failures
  if failures == 0:
    echo "cli_smoke.sh: all passed, 0 failed"
  else:
    echo "cli_smoke.sh: " & $failures & " failed"
