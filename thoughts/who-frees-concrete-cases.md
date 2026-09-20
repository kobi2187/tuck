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

- **#2 and #4 should not exist.** They are `recordDupSites` copying a
  record's Seq field immediately after binding a record that was *just
  returned* and cannot be aliased. Same redundancy as the call-result case
  in EV-12, one level down. Removing them is a codegen fix and frees nothing.
- **#1 and #3 are correct, and their predecessors are garbage.** The old
  `b.ask` and `b.bid` die the moment the new `BookState` is assigned into
  `self.st`. This is the genuine free, and it is exactly "the assignment
  frees" above.

## What this implies for the session

1. **Half the Odin leak is not a lifetime problem.** Cases #2/#4 are
   redundant copies; no ownership model is needed to delete them. Do this
   first — it is mechanical and it shrinks the problem the hard fix has to
   solve.
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
