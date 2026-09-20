# One ownership analysis, four consumers — a plan

The compiler today has **three partial, ad-hoc approximations of one fact**,
and every bug in `KNOWN-BUGS-EVENTS.md` from EV-9 onward is a hole in one of
them:

| | what it computes | its hole |
|---|---|---|
| `movedFnParam` | may param 0 be taken destructively | only param 0 — a fn returning param 1 defeats it |
| `movedCallInto` | is this `x = f(x)` | only that syntactic shape — `let t = f(x); x = t` misses |
| `markSeqCopies` | copy unless it is a list literal | visits only `exkAssign`, and cannot tell a fresh return from an aliased one |

The fact all three want is the same: **for this heap value, at this program
point, who owns it?** Compute it once and the three collapse into one, the
redundant copies go, and freeing becomes possible on Odin.

This is a plan, not a design review. Every claim below that is marked
*measured* was run; the rest is intent.

## Why this is tractable here and not in general

Tuck has **no nil, no refs, and `Seq` assignment copies**. So every heap
buffer has exactly one owner at every instant and ownership is a tree, never
a graph. There is nothing to *discover* at runtime — no refcount, no
tracing, no ownership table. The information is static; the compiler simply
does not currently compute it.

That is the whole argument for doing this as an analysis rather than adding
a mechanism to the language.

## What owns heap

Exactly two: **`Seq[T]`** and **`str`**. Records and actors own only by
containing one. `Array[N,T]` is inline. Everything below is over those two.

## The three questions

1. At `x = e` — is `x`'s current buffer dead? (free it, or move it into `e`)
2. At `let y = f(...)` — does `f`'s result alias an argument? (copy or not)
3. At scope exit — which locals still own a buffer nobody took? (free them)

## Component A — interprocedural provenance summary

For each fn returning a heap-owning type, and for **each heap slot** of that
return (a record returns one per Seq/str field), one of:

- `Fresh` — allocated in this body, or derived from a `Fresh`
- `FromParam(i)` — may alias parameter `i`
- `Unknown` — extern, indirect call, or unresolved recursion

Abstract interpretation over the body; fixpoint for recursion, starting at
`Fresh` and widening to `Unknown`. Per-field is essential:

```tuck
fn wrap({xs: Seq[int]}) -> Pair:
  return {a: xs, b: xs} Pair     # {a: FromParam(0), b: FromParam(0)}

fn sweep({ladder: Seq[int], ...}) -> Filled:
  ...                            # {ladder: Fresh}
```

This subsumes `movedFnParam` — "is the summary `FromParam(0)` and is param 0
a container" — and answers `markSeqCopies` correctly: **copy only when the
result may alias something still live at the call site.** *Measured*: both
of the "optimisations" tried this session (exempt call results; exempt
record bindings from calls) are wrong, and this summary rejects both — it
returns `FromParam(0)` for `wrap`, forcing the copy that keeps
`value_semantics`'s aliasing assertion at 17 instead of 106.

## Component B — intraprocedural liveness

Standard backward dataflow over heap-owning locals: at each point, may this
name be read later? Gives:

- `x = f(x)` where `x` is dead after → move. Generalises `movedCallInto`
  past its syntactic shape, so EV-9's forced workaround `let t = f(x); x = t`
  stops costing three copies.
- `s = s + t` where `s` is dead → **in-place append**. *Measured*: emitting
  `s.add(t)` instead of `tuckConcat(s, t)` takes the 200k-concat loop from
  **460 ms to 2 ms on Nim** — 230x, and it turns O(n^2) into O(n).
- scope exit → free what is still owned and did not escape.

## The escape set — what must NOT be freed

A value escapes its scope, and the scope must not free it, when it is:

1. **returned** (ownership moves to the caller);
2. **stored into an actor field** (the actor owns it until overwritten);
3. **moved into a call** that takes it destructively (the `_moved` twin);
4. **put in a `send` payload** — the message owns it, and the receiving
   actor may be on another OS thread.

(4) is not hypothetical and is currently broken in the other direction:
**EV-13** — a `Seq` in a send is not copied at all, so the sender keeps
writing the actor's message. *Measured*: nim 42, odin 99, d 99. Any
free-insertion built before EV-13 is fixed would turn that aliasing bug into
a use-after-free across threads.

## Consumers

1. `markSeqCopies` → **replaced**. Copy iff the bound value may alias
   something still live. Removes 2 of the matching engine's 4 copies per
   order.
2. `movedFnParam` / `movedCallInto` → **replaced** by the general move rule.
3. **New: free insertion**, Odin only (Nim has ARC, D has a GC). Emit
   `delete` at the last use, at reassignment, and at scope exit for anything
   not in the escape set.
4. **New: in-place append** for `str`, which `Seq` already gets via `push`.

## Where it lives

A shared pass beside `lowering_seqcopy.nim`, under the same discipline: runs
after `lowerModule` on the backend's private deepCopy, marks keyed by node
id, marks accumulate across the import closure and are never cleared between
modules. The FACTS are backend-independent; only the repair differs — Nim
needs almost none of it, D wants fewer `.dup`s, Odin needs both the elision
and the frees.

Note `tuck.nim`'s `checkOrDie` is where pass-ordering constraints are
written down; this one needs types, so it runs after typecheck, and its
consumers run after it.

## Staging — each stage lands and is measured alone

**Stage 0 — EV-13 first, on its own.** Mark send payloads. It is a
correctness fix for a live data race, it is narrow, and every later stage
would otherwise be built on top of a bug. Gate: the EV-13 repro returns 42
on all three backends in both `single` and `thread` mode.

**Stage 1 — Component A, consumed only by `markSeqCopies`.** No freeing, no
liveness. Strictly *fewer* copies, only where provably `Fresh`. Gate:
`value_semantics`' aliasing assertion stays 17 on three backends; the
matching engine drops from 4 ladder copies per order to 2 (measurable as
peak RSS, ~5.5 GB -> ~2.8 GB on Odin, and as time on D).

**Stage 2 — Component B, consumed by the move rule and by `str`.** Gate: the
2M-iteration `Seq` loop stays at 2 MB; the 200k `str` loop goes from 460 ms
to single-digit ms on Nim; `let t = f(x); x = t` emits what `x = f(x)` does.

**Stage 3 — free insertion on Odin.** The risky one: a wrong free is a
use-after-free, where every earlier stage's failure mode is merely a
retained buffer. Lands last, behind a flag, with Odin's tracking allocator
asserting **zero leaks and zero double-frees**. Gate: the matching engine at
200k orders in bounded memory, same printed book.

**Stage 4 — `str` representation on Odin and D** so in-place append is
possible there too (Odin `string` is an immutable byte slice with no spare
capacity; Nim's `string` already has it, which is why Stage 2 buys 230x
there and nothing here).

## Verification

Nothing in the suite measures memory today (EV-12 says so), and that is the
first gap to close — a bounded-peak-RSS assertion, or every stage is
unfalsifiable.

Otherwise: `hostRuns` on all three backends for every ownership assertion,
never `emits`. The three bugs this session were each invisible to `okCheck`
and to a regex over generated text; two of them were invisible on Nim
specifically, so a one-backend check reports green. `benches/apps/matching_engine.tuck`
is the standing end-to-end measurement.

## What makes this fail, and the fallback

Every unknown is answered `Unknown` and costs a copy, never a wrong answer:
indirect calls (`:pred` references), extern fns, recursion before the
fixpoint settles, and anything involving a backend-provided container the
pass cannot see into. The analysis must be *sound*, not complete — the
failure direction is a retained buffer, which is exactly the property that
put the arena option first in EV-12's ranking and the same one V's autofree
chooses.
