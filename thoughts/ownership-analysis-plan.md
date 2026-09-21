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
  return {a: xs, b: xs} Pair       # {a: FromParam(0), b: FromParam(0)}

fn build({n: int}) -> Pair:
  let a = [0]
  let b = [0]
  return {a: a, b: b} Pair         # {a: Fresh, b: Fresh}
```

This subsumes `movedFnParam` — "is the summary `FromParam(0)` and is param 0
a container" — and answers `markSeqCopies` correctly: **copy only when the
result may alias something still live at the call site.** *Measured*: both
of the "optimisations" tried this session (exempt call results; exempt
record bindings from calls) are wrong, and this summary rejects both — it
returns `FromParam(0)` for `wrap`, forcing the copy that keeps
`value_semantics`'s aliasing assertion at 17 instead of 106.

## Component B — intraprocedural liveness

**Already exists**, and was missed when this plan was written:
`compiler/analysis_lastuse.nim` stamps the final read of every binding, and
`codegen_common.paramIsMovable` consumes it. It is deliberately strict —
nothing inside a loop is stamped unless the binding is loop-local, which is
not modelled — so there is widening to do, but the pass, its consumer and
its reasoning are in the tree. Its header makes the same argument this plan
does from the other end: last-use is cheap in Tuck precisely because there
is no aliasing to invalidate it.

What it gives, once widened:

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

**Stage 1 — Component A, consumed only by `markSeqCopies`. DONE.** No
freeing, no liveness. Strictly *fewer* copies, only where provably `Fresh`.

Measured A/B on Odin, same machine state, interleaved, 200k orders:

| | emitted copies | time | peak RSS |
|---|---|---|---|
| before | 15 | 13 957-29 891 ms | 5 589 MB |
| after | 10 | **3 102-3 686 ms** | **4 003 MB** |

Memory is the trustworthy figure (5 587-5 589 against 3 999-4 006); the time
spread before the change is allocator churn, which is also why the time win
outruns the copy count.

One prediction here was wrong and is worth correcting rather than quietly
dropping. This plan said the engine would go from 4 ladder copies per order
to 2, on the reading that both binding-site copies were redundant. Only
`sweep`'s is. `rest` has an early return —

```tuck
fn rest({ladder: Seq[int], px: int, qty: int, best: int}) -> Booked:
  if qty <= 0:
    return {ladder: ladder, best: best} Booked
  var lad = ladder
  lad[px] = lad[px] + qty
  return {ladder: lad, best: best} Booked
```

— which really does hand its parameter back, so the analysis marks it
`oAliased` and keeps the copy. That is the analysis being right and the
prediction being wrong. Removing that one needs liveness at the call site
(the old book is dead), which is Stage 2, not Stage 1.

**Stage 2c is NOT WORTH BUILDING — measured, not argued.** The gate was
"`let t = f(x); x = t` emits what `x = f(x)` does", generalising
`movedCallInto` from a syntactic shape to a liveness fact. Instrumented the
predicate over every example, the matching engine, the Savina ports and the
whole stdlib — **63 files, zero candidates**. The instrument fires on a
constructed case, so the zero is the corpus and not a broken probe.

It makes sense in hindsight: `x = f(x)` is the idiomatic spelling, the
builder chain `x ..f {...}` that TUCK-TRANSLATION recommends routes through
the same rule, and EV-9 no longer forces anyone to write the temp. The shape
the gate describes was an artefact of a bug that is fixed.

**Read-only ALIASING is also worth zero here, and that is the more
surprising one.** The three-way rule (move / alias / copy) promises that a
binding whose source and target are both never written needs no copy at all.
Instrumented it the same way over the same 63 files: **zero**. The five
copies the matching engine keeps all bind a value that is then mutated.

That is value semantics working as designed rather than a gap: you copy
precisely when you are about to modify, and a binding you only read from is
a binding you would not have written. So the mutation half of the value
model does not pay for itself as ALIAS-instead-of-copy.

Where the remaining copies actually go is MOVE-instead-of-copy: `sweep` and
`rest` copy a ladder they are about to mutate, and their sources (`b.ask`,
`b.bid`) are dead afterwards. Aliasing would be wrong there; moving is
right. That needs liveness at FIELD granularity — `b.ask` dead, not `b`
dead — which is the one extension with measured value behind it.

(Measurement note: the first version of this instrument counted `let r = X`
as a write, which made every bound name look mutated and reported a
misleading zero for a different reason. Fixed before the numbers above.)

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


## Where this is going: SSA, and one invariant

Two rulings, recorded because they change what the analyses are FOR.

### Actors send data, never pointers

A send hands the receiver a value it owns. The sender must not be able to
observe it afterwards — that is what makes an actor's state its own, and it
is the guarantee EV-13 was violating (the mailbox held a header, so the
sender's next write landed in the actor's message; nim 42, odin 99, d 99).

Stage 0 made it true by COPYING. A MOVE satisfies the same rule and is
strictly better: ownership transfers, the sender is left without it, and
nothing is duplicated. That is what batch mode wants — a batch of messages
handed over by pointer swap rather than copied element by element — and it
needs only liveness at the send site: if the sender's value is dead after
the send, move it.

So the invariant is "the sender cannot observe the value after the send",
not "the send copies". Worth stating that way, because the copy is the
conservative implementation and the move is the intended one.

The three escapes an ownership analysis must know about are exactly the
places this bit: a send payload, an actor field (persists across messages,
so intra-body reasoning says nothing about it), and the `_moved` twin, which
deliberately takes its parameter destructively.

### The analyses want to be SSA, not side-tables

`analysis_liveness` and `analysis_provenance` are hand-rolled answers to
questions SSA answers natively. `Cell.token` — "which allocation does this
name denote" — is a value number by another name.

**Tuck is unusually cheap to put in SSA, for the same reason its liveness is
exact.** In C, SSA covers scalars and everything reached through a pointer
needs MEMORY SSA on top of alias analysis; that is most of the cost. Tuck
has no refs and no nil, so every value is SSA-able and there is no memory
partition to model at all. And φ placement needs no dominance frontier: the
control flow is structured, so the merges are exactly the ends of `if` and
`match` arms and the loop heads.

What that buys, beyond what is already here: value numbering (so
`{a: xs, b: xs}` is one value under two names by construction rather than by
a token comparison), and then GVN, CSE and constant propagation as ordinary
consumers.

The one place it is NOT free is the escape list above. An actor field is a
location that outlives every body that touches it, so it is not SSA-able
within one — that is the small corner where something like memory SSA is
still needed, over a handful of named locations rather than the whole heap.

Sequencing: SSA is an ANALYSIS ir, with facts mapped back to AST nodes by
node id, exactly as the current passes do. The emitters print from the AST
and should keep doing so. Making SSA the codegen input is a different and
much larger project, and nothing here needs it.
