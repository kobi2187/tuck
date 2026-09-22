## The SSA value mirror — Stage A of thoughts/ssa-mirror-design.md.
##
## THE MIRROR IS PROOF-ONLY TODAY. Nothing consults it: no emitter reads a
## stamp from it and no analysis asks it a question. It exists so that the
## ownership work can move off syntax-directed emitters, and it earns each
## step of that by being checked before anything depends on it.
##
## WHAT IS ASSERTED HERE, and why it is shaped like this.
##
## The invariants live in the PIPELINE (`assertSsaWellFormed`, run under
## `--verify-stages`) rather than in this file, and this suite's job is to
## point that assertion at the corpus. That split is deliberate: the bugs a
## value mirror has are not the ones you think to write a snippet for. They
## are shapes the corpus already contains — a `match` with a guard, a `for`
## whose body breaks out of an enclosing `while`, a field written through a
## chain — and each would produce a plausible-looking mirror that answers the
## ownership question wrongly two stages later. Running the real assertion
## over every example, both applications, the Savina ports and the stdlib is
## worth more than any number of hand-written cases, and it costs ~5ms a file
## because `tuck ch` never reaches a backend.
##
## Verified to have teeth rather than assumed: two deliberate builder bugs
## were introduced and both were caught across the corpus — a phi taking an
## operand belonging to a different place (20 files) and a read that failed
## to record itself in its value's use list (41 files).
##
## The snippets below are for the CONTROL-FLOW JOINS specifically, because
## those are the part with no prior art in this tree to copy: every other
## pass here is a single walk, and this is the first one that has to say what
## a value IS after two arms disagreed about it.
import std/[os, strutils]
import ../harness

proc corpusFiles(): seq[string] =
  for pat in ["examples/*.tuck", "benches/apps/*.tuck",
              "benches/savina/*.tuck", "std/*.tuck"]:
    for f in walkFiles(pat): result.add f

# 16-actor-tasks-unified-syntax does not typecheck AT ALL — it calls an
# undeclared `copyFrom` (TK-TY03) — so it never reaches the mirror and is not
# evidence either way. Named rather than pattern-matched so that a file which
# starts failing for a NEW reason is not silently excused with it.
const notChecked = ["16-actor-tasks-unified-syntax.tuck"]

proc run*(t: var T) =
  var idx: seq[tuple[name: string, i: int]]
  for f in corpusFiles():
    let name = f.extractFilename
    if name in notChecked: continue
    idx.add (f, t.needCmd(@["./tuck", "ch", f, "--verify-stages"]))

  if t.phase == pReport:
    var bad: seq[string]
    for (name, i) in idx:
      let (rc, outp) = t.resultOf(i)
      if rc != 0 and "SSA mirror is malformed" in outp:
        bad.add(name & ": " & outp.splitLines()[^1])
      elif rc != 0:
        # Some other diagnostic. Not this suite's business — examples.nim
        # gates what must compile — but a file that stopped checking is
        # also a file the mirror stopped being exercised on, so say so.
        bad.add(name & ": did not check, so the mirror was never built")
    if bad.len == 0:
      t.ok "the value mirror is well formed over the whole corpus (" &
           $idx.len & " files)"
    else:
      t.no "the value mirror is well formed over the whole corpus",
           bad[0 .. min(3, bad.high)].join(" | ")

  # --- the joins, which are the part with no prior art here ----------------
  #
  # Each of these is a shape where "what value does this name hold" has no
  # single answer and the mirror has to say so with a phi. They are asserted
  # through the same pipeline assertion — a malformed phi is exactly what
  # `structuralErrors` reports — so what they add over the corpus sweep is
  # CERTAINTY THAT THE SHAPE IS PRESENT, which a corpus cannot give.
  t.src """
import seq

fn pick({n: int}) -> Seq[int]:
  var out = [0]
  if n > 1:
    out = {items: out, value: 1} push
  else:
    out = {items: out, value: 2} push
  return out

fn armed({n: int}) -> int:
  var acc = 0
  match n:
    | 0 -> acc = 1
    | 1 -> acc = 2
    | _ -> acc = 3
  return acc

fn looped({n: int}) -> int:
  var total = 0
  var i = 0
  for i < n:
    total = total + i
    if total > 100:
      break
    i = i + 1
  return total

fn nested({n: int}) -> int:
  var a = 0
  var i = 0
  for i < n:
    var j = 0
    for j < n:
      j = j + 1
      if j > 2:
        continue
      a = a + 1
    i = i + 1
  return a

fn main() -> int:
  let p = {n: 2} pick
  let q = {n: 1} armed
  let r = {n: 20} looped
  let s = {n: 4} nested
  return p[1] + q + r + s
"""
  t.okCheck "every join shape checks"
  let verified = t.needCmd(@["./tuck", "ch", t.curDir / "t.tuck",
                             "--verify-stages", "--root:" & t.root])
  # 1 + 2 + 105 + 8. Asserted by value so a join that loses a version — the
  # failure a structural check cannot see, because a mirror missing a phi is
  # still internally consistent — shows up as a wrong number.
  t.runs "...and they still compute what they did", 116

  if t.phase == pReport:
    let (rc, outp) = t.resultOf(verified)
    if rc == 0: t.ok "...and the mirror is well formed across all four"
    else:
      t.no "...and the mirror is well formed across all four",
           "exit " & $rc & ": " & outp.splitLines()[^1]

  # --- assignment targets with NO NAMEABLE PLACE ---------------------------
  #
  # The gap the corpus had, found the expensive way. `R.W = true` is an
  # `exkField` whose receiver is a memory-mapped register rather than a
  # value, so the path is unnameable — and the builder then read `brReceiver`
  # off a field node and took the compiler down with
  # `field 'brReceiver' is not accessible for type 'Expr'`.
  #
  # It got that far because no example assigns a register field with `=`
  # (examples/20 uses the chain form throughout), so the corpus sweep never
  # produced the shape, and the mirror had by then moved onto the hot path
  # for every D and Odin build. known_bugs' register assertion caught it.
  #
  # COMPILE-ONLY, and not because running it is inconvenient: `R` is an
  # address, 0x40011000 is not mapped on a host, and writing it is a
  # segfault. This is a syntax specimen in the sense examples/ means — the
  # assertion is that the compiler survives the shape.
  t.src """
register R at 0x40011000:
  W: bit 0 [read, write]

fn poke() -> void:
  R.W = true
  return

fn main() -> int:
  return 0
"""
  t.okCheck "an assignment to a register field checks"
  let noplace = t.needCmd(@["./tuck", "ch", t.curDir / "t.tuck",
                            "--verify-stages", "--root:" & t.root])
  t.emits "...and it lowers to the setter, not a place",
          r"tuck_R_W_set\(true\)"

  if t.phase == pReport:
    let (rc, outp) = t.resultOf(noplace)
    if rc == 0: t.ok "...and the mirror survives a target with no place"
    else:
      t.no "...and the mirror survives a target with no place",
           "exit " & $rc & ": " & outp.splitLines()[^1]

  # The other two unnameable-ish targets, which DO have something to version
  # beside them and can therefore be asserted by value.
  t.src """
import seq

type Cell:
  xs: Seq[int]

fn indexed({c: Cell}) -> Cell:
  var out = c
  out.xs[0] = 9         # the ELEMENT has no name, but `out.xs` changed
  return out

fn fielded({c: Cell}) -> int:
  var d = c
  d.xs = [4, 5]         # a field target, which DOES have a place
  return d.xs[1]

fn main() -> int:
  let a = {xs: [1, 2]} Cell
  let b = {c: a} indexed
  let n = {c: a} fielded
  return b.xs[0] + n + a.xs[0]
"""
  t.okCheck "an element and a field target check"
  # 9 + 5 + 1. `a.xs[0]` is 1 only if `indexed` wrote into its OWN copy —
  # the same aliasing question the index-assign versioning exists to answer.
  t.runs "...and they still compute what they did", 15
  t.hostRuns("...on every backend", 15)

  # --- what the mirror proves that the pass it replaced could not ----------
  #
  # `analysis_liveness` never stamped a read in a `for`'s ITERABLE at all —
  # its `exkFor` arm walks the body and then folds the iterable into the live
  # set without ever calling `stampSites` on it. So a parameter iterated once
  # and never touched again was not a final use, and Nim got `seq[T]` where
  # `sink seq[T]` is correct.
  #
  # Guarded here by INTENT rather than only by the eight goldens the switch
  # rewrote, because a golden records what the compiler did and this records
  # what it is supposed to do.
  t.src """
import seq

fn total({xs: Seq[int]}) -> int:
  var s = 0
  for v in xs:
    s = s + v
  return s

fn main() -> int:
  return {xs: [1, 2, 3]} total
"""
  t.okCheck "a parameter iterated once checks"
  t.emits "...and its only read is final, so Nim gets sink",
          r"proc tuck_total\*\(xs: sink seq\[int\]\)"
  t.runs "...and it still computes what it did", 6
  t.hostRuns("...on every backend", 6)

  # --- an ACTOR FIELD is not this body's to give away ----------------------
  #
  # The one place item 4 of thoughts/ssa-mirror-design.md could still bite.
  # `afterBinding` claims that a binding which was not already exclusive must
  # have copied, and therefore holds a fresh allocation — a claim about what
  # the EMITTER does, which is false wherever it has an in-place path. For a
  # local the flow-insensitive join covers it, because the name's earlier
  # value is joined in. An actor field assigned in a handler has no earlier
  # value in that body to join with.
  #
  # It does not bite, and this is why: the field never reaches the ownership
  # question as anything but `dfEntry`, and an entry value is owned only when
  # it is the moved parameter of a twin — which a handler, returning void, is
  # not. So `grow` is reached through its copying wrapper and the actor's
  # buffer survives.
  #
  # Asserted rather than reasoned about, because "the other rule happens to
  # cover it" is exactly the kind of claim that stops being true.
  t.src """
import scheduler
import seq

type Bag:
  xs: Seq[int]
  n:  int

fn grow({b: Bag}) -> Bag:
  var it = b.xs
  it = {items: it, value: b.n} push
  return {xs: it, n: b.n + 1} Bag

actor Keeper [queue: 16]:
  st: Bag
  ready: bool = false

  on init({n: int}):
    st = {xs: [7], n: 0} Bag

  on peek({n: int}):
    let g = {b: st} grow
    ready = true

fn done() -> bool:
  return Keeper.ready

fn main() -> int:
  Keeper send init {n: 0}
  Keeper send peek {n: 0}
  Keeper.waitUntil {pred: :done}
  let b = Keeper.st
  return b.xs[0] + b.n
"""
  t.okCheck "an actor field handed to a threading fn checks"
  t.emitsOdin "...and reaches the copying wrapper, not the twin",
              r"tuck_grow\(self\.st\)"
  # 7 + 0. A twin that took the field destructively would free it, and the
  # read after the wait would answer with whatever was left.
  t.hostRuns("...so the actor's own buffer survives", 7)

  t.finish()
