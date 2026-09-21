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
  t.emitsOdin "the twin that builds a new value frees its parameter",
              r"defer delete\(p\.items\)"
  t.omitsOdin "...and the twin that hands its own back does not",
              r"defer delete\(q\.items\)"
  # 2 + 3 + 1 + 1, pinned on all three backends.
  t.hostRuns("a freed parameter is never one the caller still reads", 7)

  t.finish()
