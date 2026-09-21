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

  t.finish()
