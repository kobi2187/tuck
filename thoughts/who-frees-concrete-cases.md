# Who frees a heap value — the concrete cases

Groundwork for the research session F27 asks for. Not a design; a set of
measured examples, so that session starts from facts rather than from
intuitions about what a no-nil, no-ref language needs.

Every number below is Odin (`--release`), peak RSS, measured not estimated.
Nim and D are flat on all of them — this is F27's backend-local obligation.

## What can own heap at all

Exactly two things: **`Seq[T]`** (Odin `[dynamic]T`) and **`str`** (Odin
`string`, allocated by `strings.clone` / `strings.concatenate`). Records and
actors own heap only by *containing* one of those. `Array[N,T]` is inline.
That is the whole surface — a much smaller problem than "manage memory".

## The load-bearing fact: there is no aliasing

No nil, no refs, and `Seq` assignment copies. So **every heap buffer has
exactly one owner at any instant**, and ownership is a tree, never a graph.
That gives a mechanical answer to "who frees", which a refcounting or
tracing language does not get:

> **The assignment frees.** `x = <new>` can free x's old buffer, because
> nothing else can be holding it — UNLESS the new value was derived from
> the old one.

That exception is the entire difficulty, and the compiler already computes
it: it is `movedCallInto` / `movedFnParam`.

## Case 1 — a local that never escapes: LEAKS, trivially fixable

```tuck
var scratch = [1, 2, 3]        # never returned, never read again
```

One buffer, never freed. Scope-exit free is correct with no analysis at all.

## Case 2 — the loop-carried long-range variable: DOES NOT LEAK

The case that looks worst and is not. A variable living to the end of the
program whose contents are replaced every iteration:

```tuck
var acc = [0]
for i < 2000000:
  acc = {xs: acc, v: i} grow
```

**2 MB for 2 000 000 iterations.** The move path fires, so `grow_moved`
receives the buffer, `append` reallocs it in place (realloc releases the old
block itself), and the same buffer comes back. There is no garbage to free
because no second buffer is ever made.

Worth stating plainly: a long-lived variable is not by itself a problem. The
problem is a long-lived variable whose successive values are *distinct
allocations*.

## Case 3 — `str` in a loop: OOM at 13.6 GB

```tuck
var s = "x"
for i < 200000:
  s = s + "y"
```

**Killed at 13.6 GB.** Strings are immutable, so every `+` is a fresh
allocation by construction and no move can rescue it — the old buffer is
garbage the instant `s` is reassigned. This is Case 2's shape with the
opposite outcome, and the difference is only whether the operation can
mutate in place.

Note this is O(n²) in *time* on every backend (each concat copies the whole
string). Only on Odin is it also O(n²) in *memory*.

## Case 4 — two live variables: a real copy, and real garbage

```tuck
var a = [0]
for i < 200000:
  let b = {xs: a, v: i} grow    # `a` is read again below, so `b` is a copy
  total = total + b[0]
```

23 MB with a 1-element seq; scales with element count. The copy is genuinely
required — `a` survives — and `b` is garbage at the end of each iteration.
This is the case `defer delete` is actually for.

## Case 5 — an actor field replaced per message: the real one

`benches/apps/matching_engine.tuck`, 200 000 orders, `self.st` holding two
1024-element ladders. Per order, `applyBuy_moved` emits **four** 8 KB copies:

| | site | needed |
|---|---|---|
| 1 | `sweep`: `tuck_s.ladder = tuckSeqCopy(...)` | yes — builds the new ask ladder |
| 2 | binding `tuck_f`: `tuck_f.ladder = tuckSeqCopy(...)` | **no** — `tuck_f` is freshly returned |
| 3 | `rest`: `tuck_lad := tuckSeqCopy(ladder)` | yes — builds the new bid ladder |
| 4 | binding `tuck_r`: `tuck_r.ladder = tuckSeqCopy(...)` | **no** — same redundancy |

4 x 8 KB x 200 000 = 6.4 GB, against 5.58 GB measured (some orders take
`rest`'s `qty <= 0` early return and skip #3).

Two separate problems, and they want different fixes:

- **#2 and #4 are redundant HERE, and cannot be removed in general.**
  They are `recordDupSites` copying a record's Seq field right after
  binding a record returned from a call. In *this* program the returned
  ladder is exclusively owned, so the copy is waste. In general it is not —
  see the next section, which is a tested counterexample, not an argument.
- **#1 and #3 are correct, and their predecessors are garbage.** The old
  `b.ask` and `b.bid` die the moment the new `BookState` is assigned into
  `self.st`. This is the genuine free, and it is exactly "the assignment
  frees" above.

## Why #2 and #4 cannot simply be deleted — tested, not argued

`lowering_seqcopy` marks a record binding when the record has Seq fields,
and its comment invites the optimisation: "A construction call's own Seq
fields are already fresh too, so marking it costs one redundant `.dup`
rather than a wrong one." **The premise is false.** A returned record's Seq
fields are whatever the callee put there, which may be a parameter:

```tuck
type Pair:
  a: Seq[int]
  b: Seq[int]

fn wrap({xs: Seq[int]}) -> Pair:
  return {a: xs, b: xs} Pair      # both fields ARE the argument

fn main() -> int:
  var src = [10, 20]
  var r = {xs: src} wrap
  r.a[0] = 99
  ...
  return r.b[0] + other[0]        # 17 when correct
```

Skipping the mark for `exkCall` was implemented and run:

| | nim | odin | d |
|---|---|---|---|
| today | 17 | 17 | 17 |
| with the "optimisation" | 17 | **106** | **106** |

106 is `99 + 7`: `r.a` and `r.b` became one buffer. Silent, wrong, and only
on the two backends whose container aliases — Nim is immune because its
`seq` has real value semantics, so a one-backend check reports green.

Guarded now by `tests/suites/value_semantics.nim`, "a record returned from a
call does not alias its argument", using `hostRuns` on all three legs. Note
`okCheck` still PASSES under the broken build: the checker cannot see this,
which is why the existing `emitsD` regex coverage in that suite was not
enough.

**What would make it safe** is a per-function summary — *does this fn return
a record whose Seq fields it exclusively owns?* `sweep` does; `wrap` does
not. That is an ownership/escape summary over the callee's body, and it is
the SAME fact the free-insertion needs. Worth noticing: the redundant-copy
elimination and the leak fix are not two projects. They are one analysis with
two consumers.

## What this implies for the session

1. **Half the Odin leak is redundant copying, not lifetime** — but
   deleting it needs the same analysis as the other half, so it is not the
   cheap first move it looks like. Tested above.
2. **The hard half is narrower than "memory management".** It is one rule —
   free the previous value on reassignment, except when the new value was
   moved out of it — over exactly two types.
3. **Case 2 is the trap.** The naive version of that rule frees `acc`'s
   buffer in the loop above, which is a use-after-free, because the new
   value IS the old buffer. Any proposal has to get Case 2 right before it
   is worth measuring on Case 5.
4. **V's autofree is the reference** precisely because it chooses to leak
   the residue rather than free wrongly. Its actual completeness is
   contested and should be checked against the implementation, not the docs.
