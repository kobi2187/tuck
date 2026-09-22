# Ownership, and the value mirror it rests on

How the memory analysis works, what each piece is for, where the current
design is wrong, and what it should be instead.

Written 2026-09-22, after a review that found a use-after-free in shipped
code. That bug is the argument for most of what follows.

---

## 1. Three side tables, and what each one knows

Tuck's compiler keeps three structures alongside the AST. None of them is a
copy of the tree; each answers a different question about it.

| | keyed by | answers |
|---|---|---|
| **Resolution** (`resolution.nim`) | node id | *what is this?* — the type of an expression, which decl a name refers to, which params a call fills |
| **The value mirror** (`analysis_ssa.nim`) | place + version | *which value is this?* — how many distinct values a name has held, where each came from, where each is read |
| **Provenance** (`analysis_provenance.nim`) | fn name | *where did it come from?* — does this function's result alias its argument, or is it freshly allocated |

They layer. Provenance asks Resolution for types. The mirror asks Resolution
for what a node means. The ownership pass (`analysis_ownership.nim`) asks all
three and produces the fourth thing: **who frees this buffer**.

### Why there are three and not one

Resolution is a *fact about a node* — stable the moment typechecking ends.
Provenance is a *fact about a function* — a summary, computed to a fixpoint
because functions call each other. The mirror is a *fact about a value inside
one body* — and a single name holds several values over its lifetime, which
is exactly what a node-keyed table cannot express.

That last sentence is the whole reason the mirror exists. `xs` in

```tuck
var xs = [0]
for i < n:
  xs = {items: xs, value: i} push
```

is one name, one declaration node, and `n + 1` distinct buffers. Ask
Resolution about `xs` and you get one answer. The question ownership needs —
*is THIS buffer still reachable* — is about the values, not the name.

---

## 2. What the ownership pass does, in six steps

`analysis_ownership.nim`, run per function. The module header carries the same
six steps; this is the why.

**Step 1 — collect the locals.** Every assigned name, how often, and what it
was declared with. The count splits the work: a name assigned exactly once has
one allocation for the whole scope, so the name *is* the buffer and steps 2–4
can reason about it directly. A name assigned more than once does not, and
goes to step 5.

**Step 2 — ownership, per slot.** A *slot* is the value itself for a bare
`Seq`, or one named field for a record. This body owns a slot if it got a
buffer nobody else holds. Two routes, and the second reads backwards: a
defensive copy *having been emitted* means the copy is ours. `exclusivelyOwned`
answering false is not "someone else owns it" — it is the reason
`markSeqCopies` marked the site.

**Step 3 — escape, per slot.** Can this slot still be reached after the body
returns? Returned, sent, stored through another name, or handed to a twin that
will free it. Per slot is the entire precision of the pass: `relight` returns
`{height: sl.height, lum: sl.lum, light: b.light}`, so `b.light` escapes and
`b.height` and `b.lum` do not. Ask about `b` as a whole and all three read as
live.

**Step 4 — owned and not escaping ⇒ free at scope exit.** The backend prints
this as a `defer`, which needs no *position*: decided once at the declaration,
run on every path out.

**Step 5 — overwritten in a loop ⇒ free the old value at the overwrite.** A
scope-exit free fires once; the leak is one buffer per iteration.

**Step 6 — the twin's parameter.** A MOVED twin consumes its first argument
and frees each slot the result does not hand back.

Every question fails towards *not* freeing. A slot the pass declines is a
leak, which is where the Odin backend already was. A slot it claims wrongly is
a double free or a use-after-free.

---

## 3. Your model of SSA, and what I actually built

You described it as:

> like Resolution in that it accompanies the ast nodes and has more
> information about them, but it is not a copy, instead it has a reference to
> the node, or its id, and then has all kinds of relevant information about
> it. Then to create the SSA form, it can do it in various scopes.

**That is right, and it is not what I built.** Three divergences, all mine:

**It is keyed by place, not by node.** The primary index is
`place: string` (`"b.ask"`) plus a version number. There *is* a node index —
`readAt: Table[NodeId, ValueId]` — but it only covers read sites. Ask "what do
you know about node N" and the mirror can only answer if N happens to be a
read. Your model makes the node index primary, which is both simpler and more
useful.

**It is rebuilt, not stored.** Resolution is built once and lives. The mirror
is constructed on demand by whoever wants it, and thrown away:

```
SSA-BUILDS total=110 distinct-fns=45 worst-fn-rebuilt=10 times
```

That is one compile of `world_server`. Forty-five functions, a hundred and ten
constructions. It is a pure function of `(Resolution, Decl)` and nothing
memoizes it.

**It exists in exactly one scope.** `buildFn` and nothing else. Your "various
scopes" is not expressible, because there is no block structure to name a
scope *with* — control flow is encoded as a `'/'`-joined string
(`"L3/A7:then"`) and parsed back out with `split` at query time.

So: your instinct was the better design, and I drifted from it without
noticing. The drift has a cost, measured below.

---

## 4. The real algorithm, and which one Tuck wants

SSA construction has two well-known approaches.

**Cytron, Ferrante, Rosen, Wegman & Zadeck (1991)** — the classic. Build an
explicit control-flow graph, compute the dominator tree, compute *dominance
frontiers*, place a φ for variable *v* at the dominance frontier of every
block defining *v*, then rename in a dominator-tree walk with a stack per
variable. This is what every textbook means by "SSA construction". It needs a
CFG and a dominator tree, neither of which Tuck has.

**Braun, Buchwald, Hack, Leißa, Mallon & Zwinkau (2013), "Simple and Efficient
Construction of SSA Form"** — builds SSA *directly from the AST*, with no CFG
and no dominance computation. Three operations:

- `writeVariable(var, block, value)` — record the current definition;
- `readVariable(var, block)` — if this block defines it, done; otherwise
  recurse into predecessors (`readVariableRecursive`);
- when a block has several predecessors, insert a φ, and **remove it again if
  it turns out trivial** — a φ whose operands are all the same value, or all
  the same value plus itself.

Loops are handled by *sealing*: a block whose predecessors are not all known
yet gets an **incomplete φ**, filled in when the block is sealed. That is
exactly the back-edge problem, solved without dominance.

**Braun is the one Tuck wants**, for a reason specific to this language: Tuck
has *structured control flow only*. No `goto`, no labels — ROADMAP records
"No labels ever" as a ruling. Every join is a syntactic join. With an
irreducible CFG you need Cytron; without one you do not, and Braun is
materially simpler.

### And this is what my builder is, badly

Read `analysis_ssa.nim` against the paper and the correspondence is exact:

| Braun | mine |
|---|---|
| `currentDef[var][block]` | `Builder.cur: Table[place, ValueId]` |
| `readVariable` | `valueOf` |
| `writeVariable` | `defineAt` |
| φ at a join | `joinMaps` |
| sealing / incomplete φ | *absent* — special-cased per construct |
| trivial-φ removal | *absent* |
| blocks with predecessor lists | *absent* — a `'/'`-joined string |

I reimplemented two thirds of a known algorithm without naming it, and the
third I left out is the third that handles loops. **The six builder bugs that
Stage A cost were all in that third**: the loop-head φ taking the wrong
region, entry values materialised inside an arm spawning phantom φs (`exit` in
`38-division` ended with *five* versions — that is precisely a missing
trivial-φ removal), "repeats" needing a subset test rather than equality.

Braun handles every one of those by construction. Writing it from the paper
would have been faster and would be correct now.

---

## 5. Mistakes in the current design

Numbered so they can be argued with individually.

**M1 — control flow is a string.** `region: string` holds `"L3/A7:then"`, and
`disjoint()` answers "can these two reads both happen" by `split('/')`, then
`split(':')`, then comparing prefixes. A tree, serialised and re-parsed at
every query. Blocks with predecessor lists — Braun's representation — make the
same question a set operation and make your "various scopes" expressible.

**M2 — no memoization.** 110 constructions for 45 functions, worst case 10×.
It is a pure function of its inputs.

**M3 — and worse than waste: the mirror means different things at different
stages.** `markLivenessSsa` runs *before* the per-backend deepCopy, on the
checked tree. `moveFactsSsa` and `consumedSlotsSsa` run during codegen, on a
lowered tree. These are different trees; lowering mutates in place. Nothing in
the code says so, and the answers genuinely differ — the pre-clone probe found
`relight`'s `a` and `r` freeable, which post-lowering they are not, because
the twin-call rewrite had not happened yet. **That is the exact class of bug
the mirror was introduced to eliminate**, reproduced inside the mirror's own
API.

**M4 — `Slot = string` with `""` as a sentinel** for "the value itself". An
empty string is not a field name today; it is one sentinel away from being a
bug. A variant type costs nothing.

**M5 — the escape test is a full body walk per slot.** `diesAtScopeExit` calls
`slotEscapes` once per slot, inside a loop over locals, and `diesAtOverwrite`
calls it again. Five locals with three fields is fifteen traversals of the
whole function. The mirror already holds every use of every value — this
question should be a lookup, not a walk. **It is asking the tree a question
the mirror was built to answer.**

**M6 — the `str` analysis is a second copy of the `Seq` one.** Same six steps,
same shape, different file, living inside the Odin emitter
(`ownedStrLocalsOf`, `strEscapes`, `isOwnedStrLocal`). Two implementations of
one idea, kept in step by hand. This is item 5 of the SSA design document,
which the mirror was supposed to have retired.

**M7 — and M6 is not theoretical. It shipped a use-after-free.** The `str`
copy's escape test answered "could this destination be carrying a str" with
**false for `str` itself**, reasoning that the allocating runtime procs return
fresh storage rather than passing one through. True of a *call*. False of a
*return*:

```odin
tuck_label :: proc (n: int) -> string {
  tuck_s := str.toStr(n)
  defer delete(tuck_s)     // frees it
  return tuck_s            // returns the freed buffer
}
```

It printed garbage. Nothing in the suite caught it, because every `str` in the
corpus is consumed where it is built — no example returns one it allocated.
The `Seq` path has the same rule written correctly; the two copies disagreed,
which is what having two copies means.

---

## 6. `freed` on the value — the fix for the class, not the instance

The right response to M7 is not "be more careful in the escape test". It is to
make the thing checkable, which is what a `freed` marker on the value gives:

```nim
Value* = object
  place*: string
  version*: int
  def*: Def
  uses*: seq[Use]
  freedAt*: NodeId      ## where this value's storage is released, or 0
  freedBy*: FreeKind    ## scope exit, overwrite, or a twin consuming it
```

Recording the free **on the value** rather than deciding it inside an emitter
turns three properties into assertions the compiler can check on every build:

1. **No value is freed twice.** One `freedAt` per value, by construction. The
   double free that segfaulted `value_semantics` — `b` freed at scope exit
   *and* by `step_moved` — is a second write to a field that already has one.

2. **No use follows a free.** Every `Use` of a value must be able to happen
   before `freedAt`. The `str` use-after-free is exactly this: the `return`
   is a use, and it comes after the `defer`. An assertion over `uses` and
   `freedAt` catches it without anyone having to have thought of the case.

3. **Every owned value is freed exactly once.** The leak half, stated as an
   invariant rather than measured as an RSS number afterwards.

That is the answer to "why don't we introduce a `freed` field" — it is the
right idea, and the reason is stronger than convenience. Today correctness of a
free is established by reading the emitter and running valgrind. With the
marker it is established by the pass that made the decision, at the point it
made it.

It also subsumes M6: a `str` and a `Seq` are both values with slots, and the
only genuinely backend-specific part — *which runtime calls return storage the
caller owns* — is a list passed in, not a second analysis.

---

## 7. What to change, in order

1. **Rebuild the mirror per Braun et al.** Real blocks with predecessor lists,
   `readVariableRecursive`, sealing for loops, trivial-φ removal. Kills M1,
   makes M5 a lookup, and makes "SSA over a chosen scope" expressible.
2. **Store it beside Resolution, built once**, with the stage it describes
   recorded on it. Kills M2 and M3 — and M3 is a correctness fix, not a
   performance one.
3. **Add `freedAt`/`freedBy` to `Value`**, and assert the three invariants in
   §6 whenever the ownership pass runs.
4. **Fold `str` into the one ownership pass**, with the allocating-call list
   as a parameter. Kills M6 and the class M7 came from.
5. Only then move the pass before the per-backend clone — which needs the copy
   decision on the mirror first (Stage C), for the reason measured in
   `analysis_ownership.nim`'s header.

Steps 3 and 4 are worth doing before 1, because they are small and they close
a shipped bug class. Step 1 is the larger piece and should be done from the
paper rather than from the current file.
