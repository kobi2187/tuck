## Does a loop accumulate garbage?
##
## This suite exists because nothing else in the tree could ask. The Odin
## backend leaked every heap value it copied — 75 KB per message, OOM-killed
## at 13.6 GB on a 200k-order program — while passing every assertion in the
## suite (KNOWN-BUGS-EVENTS.md EV-12, issue #77). It passed because the
## programs are CORRECT: `okCheck` is clean, the emitted text is plausible,
## the exit code is right. Only the memory is wrong, and memory was the one
## thing no assertion looked at.
##
## The budgets here are deliberately loose. They are not performance
## assertions and should not be tightened into ones — each is set well above
## what a non-leaking backend needs and well below what a leaking one
## reaches, so the gap does the work and ordinary allocator variation does
## not. A budget that fails on a 2x wobble would be turned off within a
## month.
##
## Every assertion runs on all three backends, because the one that leaks is
## the one without a collector and a Nim-only check reports green.
##
## What is HERE is what holds on all three today. The copy-per-iteration loop
## that found EV-12 does not, so it lives in `known_bugs` as a `bugOpen` —
## stating the correct behaviour, failing, and reporting itself — rather than
## as a red line here.
import ../harness

proc run*(t: var T) =
  ## Registers the memory assertions: loops whose memory must stay inside a
  ## loose budget on all three backends (a leak blows through it).

  # The move path, which should allocate NOTHING per iteration: `x = f(x)`
  # hands the buffer to the twin, `append` reallocs it in place, and the same
  # buffer comes back. 2 000 000 iterations in a budget a single copy loop
  # would blow, so this fails loudly if the move ever stops firing.
  t.src """
import seq

fn grow({xs: Seq[int], v: int}) -> Seq[int]:
  var out = xs
  out = {items: out, value: v} push
  return out

fn main() -> int:
  var acc = [0]
  var i = 0
  for i < 2000000:
    acc = {xs: acc, v: i} grow
    i = i + 1
  if acc[500] != 499:
    return 1
  return 0
"""
  t.okCheck "a self-threaded append loop checks"
  t.runs "...and computes the right answer", 0
  t.hostPeakRss "...and 2M appends stay in one buffer", 131072

  # --- a MOVED twin frees the parameter it owns, and only then ------------
  #
  # The twin owns its moved parameter: the caller either transferred it
  # (movedCallInto proved the argument dead) or the wrapper handed over a
  # copy. So it may free it at exit — but ONLY if the value it returns
  # carries none of the parameter's buffers.
  #
  # The two fns below are the two sides of that, and they take DIFFERENTLY
  # NAMED parameters so the emitted frees can be told apart by name. Note a
  # PARAMETER keeps its own name in the emitted code — only declarations are
  # mangled — so these match `p.items`, not `tuck_p.items`:
  #   rebuild(p)  allocates a new seq        -> frees p.items
  #   passthru(q) returns the seq it got     -> must NOT free q.items
  #
  # `passthru` is the case that matters: freeing there frees the value the
  # caller is about to bind. An earlier version of the provenance pass
  # reported BOTH as returning fresh values, because it assumed the binding
  # `var keep = q.items` copied — which inside a twin the emitter
  # deliberately suppresses (codegen_odin:1199).
  #
  # THE `omitsOdin` IS THE GUARD, NOT THE EXIT CODE. Tried it: making the
  # emitter free unconditionally fails the omits assertion and the program
  # still exits 7. Reading a freed `[dynamic]T` is undefined and here it
  # simply returns the old bytes, so a use-after-free of this shape does not
  # reliably show up as a wrong answer. `hostRuns` is kept because it pins
  # the arithmetic across three backends, but it is not what would catch a
  # bad free — nothing at runtime dependably is, which is the whole reason
  # the decision has to be asserted on the emitted text.
  t.src """
import seq

type Pair:
  items: Seq[int]
  n: int

fn rebuild({p: Pair, v: int}) -> Pair:
  var fresh = [0]
  fresh = {items: fresh, value: v} push
  return {items: fresh, n: p.n + 1} Pair

fn passthru({q: Pair, v: int}) -> Pair:
  var keep = q.items
  return {items: keep, n: q.n + v} Pair

fn main() -> int:
  var a = {items: [1, 2], n: 0} Pair
  a = {p: a, v: 5} rebuild
  var b = {items: [7, 8, 9], n: 0} Pair
  b = {q: b, v: 1} passthru
  return a.items.len + b.items.len + a.n + b.n
"""
  t.okCheck "both twin shapes check"
  # Rule P: `rebuild` only reads `p`, so it borrows it, and the caller frees
  # the value the call rebuilt from, once the new one exists.
  t.emitsOdin "the caller frees what a borrowing call rebuilt from",
              r"tuckNext1 := tuckˑfnˑrebuild_moved\(tuckˑvˑa, 5\)\n\s*rt\.tuckDrop\(tuckˑvˑa\)"
  t.omitsOdin "...and the twin that hands its own back does not",
              r"defer delete\(q\.items\)"
  # 2 + 3 + 1 + 1, pinned on all three backends.
  t.hostRuns("a freed parameter is never one the caller still reads", 7)

  # A `let` that is only read is a VIEW of what it reads (#213): no copy where
  # it is bound, no drop at the end. regex-redux's VM did `let ins = prog[pc]`
  # on every instruction, a deep copy of a record owning a Seq.
  t.src """
type Inst:
  op: int
  ranges: Seq[int]

fn weigh({prog: Seq[Inst], at: int}) -> int:
  let ins = prog[at]
  return ins.op + ins.ranges.len

fn main() -> int:
  let prog = [{op: 1, ranges: [1, 2]} Inst, {op: 2, ranges: [3]} Inst]
  return {prog: prog, at: 1} weigh
"""
  t.okCheck "a read-only let of an element checks"
  t.emits "...is the element's own bits, not a copy",
          r"tuckˑvˑins = tuckBits\(tuck_rt\.tuckAt\(prog"
  t.omits "...and nothing frees it", r"tuckDrop\(tuckˑvˑins"
  t.omitsOdin "...nor does the Odin body", r"delete\(tuckˑvˑins"
  t.hostRuns("...and it computes the same", 3)

  # The view ends where the source may change: a write to the source while the
  # binding is still read keeps the copy.
  t.src """
type Inst:
  op: int
  ranges: Seq[int]

fn old({prog: Seq[Inst]}) -> int:
  var p = prog
  let ins = p[0]
  p[0] = {op: 9, ranges: [7, 7, 7]} Inst
  return ins.op + ins.ranges.len

fn main() -> int:
  let prog = [{op: 1, ranges: [1, 2]} Inst]
  return {prog: prog} old
"""
  t.emits "a write to the source while the binding is read keeps the copy",
          r"tuckˑvˑins = tuckCopy\(tuck_rt\.tuckAt\(tuckˑvˑp"
  t.hostRuns("...and the binding sees the old value", 3)

  # A source handed to a consuming parameter is gone after the call.
  t.src """
type Inst:
  op: int
  ranges: Seq[int]

fn keep({p: Seq[Inst]}) -> Seq[Inst]:
  return p

fn after({prog: Seq[Inst]}) -> int:
  var p = prog
  let ins = p[0]
  let kept = {p: p} keep
  return ins.op + ins.ranges.len + kept.len

fn main() -> int:
  let prog = [{op: 1, ranges: [1, 2]} Inst]
  return {prog: prog} after
"""
  t.emits "a source consumed while the binding is read keeps the copy",
          r"tuckˑvˑins = tuckCopy\("
  t.hostRuns("...and the binding outlives it", 4)

  # A view that leaves the function is copied at the one place it leaves.
  t.src """
type Inst:
  op: int
  ranges: Seq[int]

fn first({prog: Seq[Inst]}) -> Inst:
  let ins = prog[0]
  return ins

fn main() -> int:
  let prog = [{op: 4, ranges: [1, 2, 3]} Inst]
  let got = {prog: prog} first
  return got.op + got.ranges.len
"""
  t.hostRuns("a view that is returned is copied there", 7)

  # A counted loop that pushes once per iteration reserves first (#210), and
  # its pushes store without asking. The loop below qualifies; the ones after
  # it each break one condition, and keep the plain push.
  t.src """
import seq

fn fill({n: int}) -> Seq[int]:
  var out: Seq[int] = []
  for i in 0 ..< n:
    out = {items: out, value: i * 2} push
  return out

fn main() -> int:
  let xs = {n: 5} fill
  return xs.len + xs[4]
"""
  t.emits "a counted loop that pushes reserves its room first",
          r"tuckReserve\(tuckˑvˑout, \(n - 0\)\)"
  t.emitsD "...and on D its pushes store without asking",
           r"rt\.tuckPushFilled\(tuckˑvˑout"
  t.emitsOdin "...and Odin reserves too",
              r"rt\.tuckReserve\(&tuckˑvˑout, \(n - 0\)\)"
  t.hostRuns("...and the filled Seq is what the loop made", 13)

  # An early exit means not every iteration pushes: no reservation.
  t.src """
import seq

fn some({n: int}) -> Seq[int]:
  var out: Seq[int] = []
  for i in 0 ..< n:
    if i == 3:
      break
    out = {items: out, value: i} push
  return out

fn main() -> int:
  let xs = {n: 10} some
  return xs.len
"""
  t.omits "a loop that can leave early reserves nothing", r"tuckReserve"
  t.hostRuns("...and still pushes only what it pushed", 3)

  # The loop reading what it has built would see a length it has not reached.
  t.src """
import seq

fn running({n: int}) -> Seq[int]:
  var out: Seq[int] = [1]
  for i in 1 ..< n:
    out = {items: out, value: out[i - 1] + 1} push
  return out

fn main() -> int:
  let xs = {n: 6} running
  return xs[5]
"""
  t.omits "a loop that reads its own Seq reserves nothing", r"tuckReserve"
  t.hostRuns("...and the reads see the pushes so far", 6)

  # A bound that calls something is evaluated once, by the loop alone.
  t.src """
import seq

fn bound({k: int}) -> int:
  return k + 2

fn calls({k: int}) -> Seq[int]:
  var out: Seq[int] = []
  for i in 0 ..< {k: k} bound:
    out = {items: out, value: i} push
  return out

fn main() -> int:
  let xs = {k: 3} calls
  return xs.len
"""
  t.omits "a bound that is a call reserves nothing", r"tuckReserve"
  t.hostRuns("...and the loop still runs it once", 5)

  t.finish()
