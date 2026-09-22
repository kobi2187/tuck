# An SSA mirror, and the six bugs that argue for one

Written 2026-09-21, immediately after EV-15. Not a proposal in the abstract:
every item in the first section is something that actually broke this week,
and they all broke the same way.

## The pattern

The ownership decision — *may this value be moved rather than copied, and who
frees it* — is made **in syntax-directed emitters**, and every analysis that
feeds them has to **predict what they will do**. That is the shape of all six:

**1. The decision lived at four syntactic positions, and one was missing.**
The MOVED-twin substitution was wired into `genAssign` (Odin), `genDAssign`
(D) and `genChainStep`. `return f(x, ...)` is a fourth position, and nothing
asked there — so a whole lighting chain's result went through the copying
wrapper. Fixed by hoisting the question into the call emitters
(`movedCalleeName`), which is the right move and is also the third time this
question has been re-asked in a new place.

**2. Reaching the twin and skipping the result's copy were welded together.**
They are two decisions. `pick(p, q, which)` is twinnable on `p` and returns
`q`: moving `p` in is right, dropping the copy of the result is not. The
emitters had one flag for both, and separating them needed a new predicate
(`otherArgLives`) whose only job is to re-derive, at the call site, something
the callee's own summary half-knows.

**3. `slotsMovedAway` re-scans the tree to re-derive what another pass
already decided.** It walks the body looking for "was this slot handed on to
a twin?", independently of the code that decided to hand it on. Two walks
that must agree, with nothing making them agree. They did not, once, and the
result was a double free that segfaulted under `TUCK_TRACK`.

**4. The analysis has to model the emitter's fast paths.** `afterBinding`
reasons "this slot was not exclusive, so the binding copied it, so it is
fresh now" — which is false wherever the emitter has an in-place path
(`xs = {items: xs, value: v} push` becomes `append(&xs, v)`). Getting that
wrong in one direction was a use-after-free; over-correcting cost 1.6 GB
against 10 MB on the matching engine. Both were measured, neither was
obvious, and the underlying problem is that an analysis is guessing at an
emitter.

*Still open — it is what Stage C is for — but LATENT rather than live, which
was worth establishing rather than assuming.* The unbacked claim needs
something to consult it, and two rules stand in the way. For a local, the
flow-insensitive join carries the name's earlier value, so an in-place
mutation cannot launder an aliased slot into a fresh one. For anything with
no earlier value in this body — an actor field assigned in a handler, the
one case the join cannot cover — the mirror sees `dfEntry`, and an entry
value is owned only when it is the moved parameter of a twin, which a
handler is not. Pinned by `ssa`'s "an actor field handed to a threading fn":
remove the `dfEntry` rule and that program answers 93 instead of 7, because
the actor's own buffer was freed under it.

**5. Two predicates for one fact, kept in step by hand.** `maybeMovedParam`
(analysis) must track `movedFnParam` (codegen). Codegen learned a second twin
shape; the analysis did not; that drift was a use-after-free that returned 14
on one run and 48 on the next (PR #75). The analysis cannot simply call the
codegen predicate, because codegen sits downstream — so the duplication is
structural, not laziness.

*Closed 2026-09-22, and it is the one of the six that has nothing to do with
the mirror.* The duplication was structural, so the fix is: `twin_shape.nim`
holds the predicate BELOW both, reaching for neither codegen nor an
analysis. `maybeMovedParam` is `movedFnParam` now, and is no longer the
wider of the two — wider was a hedge against drift, and with one definition
there is nothing to drift. Emitted output identical everywhere, the same 24
move stamps, and the complexity ratchet went 26 to 25 because a duplicated
predicate was a duplicated routine.

**6. `movedCallInto` needs a `targetName`.** A syntactic fact, threaded into
an ownership question, because the decision is made where the syntax is
rather than where the value is.

None of these is a hard bug. Each was found, each is now guarded. The point
is that they are **one bug appearing six times**, and the seventh is already
implied: EV-14 wants a free inserted at a dead value's last use, which means
finding every syntactic position where a value can die. That is item 1 again,
with a free instead of a move — and a missed position there is a leak, while
a wrong one is a double free.

## What SSA changes

In SSA a value has one definition and a known set of uses. "Is this the last
use", "who owns this", "has this been consumed" become properties **of the
value**, not of the position it is written at. The decision is taken once,
recorded on the value, and every emitter reads it. There is no position to
miss, because positions stop being the unit.

Concretely, against the six:

| | today | on a value graph |
|---|---|---|
| 1 | ask at each syntactic position | the value is consumed or it is not |
| 2 | one flag, two meanings | two facts on the value: *consumed*, *result aliases* |
| 3 | a second scan that must agree | the consuming use is recorded on the value |
| 4 | analysis predicts the emitter | the lowering is an explicit rewrite the analysis sees |
| 5 | two predicates in two layers | one, because the lowering is above codegen |
| 6 | syntax threaded into ownership | no syntax in the question |

## Why it is cheap in Tuck specifically

This is not a general-purpose SSA construction, and it should not be built
like one.

**No dominance computation.** Tuck's control flow is entirely structured —
block, if, match, for, while, break, continue, return, raise, and nothing
else. `analysis_liveness` already exploits this: it computes exact liveness
with a backward tree walk and a loop fixpoint, and its own header explains
that a CFG would add a representation to keep in sync for no extra precision.
The same holds here. Phi nodes appear at exactly two places — the join after
an `if`/`match`, and a loop head — and both are syntactically obvious.

**A name IS a value.** No nil, no refs, and `let b = a` copies. The aliasing
analysis that dominates SSA-based ownership work in C or Rust is not needed;
`analysis_liveness`'s header makes this point too, and it applies twice over
here.

**The lattice already exists.** `analysis_provenance` has
`oFresh < oAliased < oUnknown` with allocation tokens, a flow-insensitive
join, and a fixpoint over the call graph. It is already doing SSA-shaped work
on a non-SSA representation — which is exactly why it needs `afterBinding` to
guess at the emitter (item 4). Give it versioned values and the guessing is
what disappears.

## Shape

A **mirror**, not a replacement IR. The ruling recorded in
`ownership-analysis-plan.md` stands: we transpile, the backends do the real
optimisation, and an IR we emit from would be a second tree to keep correct.
What is wanted is a side structure the passes consult and the emitters read
stamps from — the same relationship `Resolution` already has to the AST.

```
  Value     id, type, and one Def
  Def       a literal, a construction, a call, a phi, or a parameter
  Use       a Value read at a node, with a position kind
  Ownership owns | borrows | consumed, per Value
```

Keyed by `NodeId`, like `lastUses` and `movedArgs` already are, so nothing
downstream has to learn a new addressing scheme.

## Staging, and how each stage is proved

Each stage has to be provable *before* anything depends on it. The discipline
that has worked all week — build the instrument, then verify it against a
known answer, then sabotage it — applies here and is the whole risk control.

**A. Build the mirror. No behaviour change. — DONE, 2026-09-21.**
`compiler/analysis_ssa.nim`, checked by `assertSsaWellFormed` under
`--verify-stages` and pointed at the corpus by `tests/suites/ssa.nim`.
Nothing consults it.

*The criterion above was wrong, and writing it is what showed that.* It asked
for an answer **identical** to `analysis_liveness`. SSA is strictly MORE
precise in a loop, because a loop-head phi is a fresh version each iteration:

```tuck
for i < n:
  out = {items: out, value: 0} push
```

has a final read of `out` at the push. The old pass cannot say so — it
reasons about the NAME `out`, which is live at the head — and that extra
precision is the entire point of the mirror. Demanding equality would have
been demanding the feature be absent.

So the criterion is a **superset**: every site the existing pass proves
final, the mirror must also prove. A site it misses is a capability lost; a
site it invents is a use-after-move. `onlyPass` is the assertion,
`onlyMirror` is the measurement. Over the corpus, both applications, the
Savina ports and the stdlib:

| | |
|---|---|
| agree | 515 |
| onlyMirror (the precision gain) | 20 |
| onlyPass (must be 0) | **0** |

The 20 sit exactly where predicted — `zeroed`, `sweep`, `flow`, `session`,
`pass`: the loop-carrying functions.

**What building it cost, which is the part worth keeping.** The first
differential ran 489 / 38 / 20, and every one of the 20 was a builder bug
rather than a precision difference:

1. *Last in program order* is wrong the moment control flow branches. A
   value read in all four arms of a `match` has FOUR final reads, because on
   whichever path runs, that read is the last. `world_server`'s `toShard` is
   exactly that shape. Fixed by giving each arm a region and asking whether
   two reads can both happen.
2. An arm ending in `return` is not followed by the code after its branch —
   and that code is not in a sibling arm, so the arm rule cannot see it.
3. The loop-head phi was created before entering the loop's region, so every
   loop-carried value looked as though it were read again forever.
4. "Repeats" is a **subset** test on loop chains, not equality: a value read
   AFTER a loop has fewer loops than its definition and does not repeat.
   Equality refused `for ...: acc = ...` then `return acc`, the commonest
   shape there is.
5. An entry value materialised lazily got the region it was first READ in,
   so a name first seen inside a loop looked loop-defined.
6. An entry value materialised inside one arm sat in the branch-scoped map,
   so the join invented a second version of it and a phi over the two.
   `exit` in `examples/38-division` ended up with five versions.

None of these would have been found by a snippet, which is why the invariants
run over the corpus — and both the invariant checker and the differential
were sabotage-verified rather than assumed green.

**Known gap in this stage's proof.** The loop's exit value must be the head
phi (a loop may run zero times), and reverting that leaves the suite green:
the subset rule answers every last-use question either way, and nothing else
consults the mirror. It matters for Stage B, where a zero-trip loop would
otherwise attribute the body's allocation to a path that never allocated.
Stage B is where it gets teeth.

**Also noted, not fixed.** A callee name is read as an ordinary place, so
`push` and `exit` become values. `analysis_liveness` does the same, which is
why the differential is clean — but a callee is not a value and should stop
being one when the mirror replaces that pass.

**B. Move ownership onto it. — PARTLY DONE, 2026-09-21.**
`markMovableArgs` now reads ownership off the mirror. What it replaced was
three walks — a seed pass asking provenance about every NAME a call site
read, a grow pass spreading the answer along assignments to a fixpoint, and
`valueIsOwned` re-deriving the call shape inside it — which had to agree
about what a name holds. That is item 6, and it is gone: on the mirror there
are no names to spread anything along.

Proved the same way as A. The two implementations were run side by side
across the corpus, both applications, the Savina ports and the stdlib before
anything switched: **24 stamps, zero difference either way**. After the
switch the tracked `examples/` output is byte-identical and both
applications print the same numbers at the same peak RSS.

**Item 3 is closed too, 2026-09-22.** `slotsMovedAway` is gone. The site
that consumes a value is recorded ON the value, so `moveFactsSsa` answers
both halves of the question from one look: which arguments this body may
hand on, and which slots of its own moved parameter it has therefore handed
away. The two used to be independent walks with nothing making them agree —
and they did not agree, once, and the result was a double free.

The new answer is also NARROWER, correctly: the scan recorded a slot
whenever the callee merely *had* a twin, whether or not the call site
reached it. An unstamped site calls the wrapper, which copies our slot and
hands the COPY to the twin, so ours is still ours to free. Switched after
both were computed side by side over the corpus with no difference, and
after `TUCK_TRACK` confirmed no double free and the same 266 683 / 16 leak
counts.

**`analysis_liveness` no longer stamps anything either.**
`markLivenessSsa` is the pass; the old walk is kept and run only under
`--verify-stages` as the ORACLE the mirror is checked against. Keeping it
costs a file nothing on the hot path calls and buys the only check on the
mirror that is not the mirror's own opinion — which is how six builder bugs
were found in an afternoon.

That switch was not behaviour-neutral, and the goldens are where it showed.
`analysis_liveness` never stamped a read in a `for`'s ITERABLE at all: its
`exkFor` arm walks the body and folds the iterable into the live set without
ever calling `stampSites` on it. So a parameter iterated once and never
touched again was not a final use, and Nim got `seq[T]` where `sink seq[T]`
is right. Eight goldens changed, sixteen lines, every one of them
`seq[X]` -> `sink seq[X]`; the programs were run on all three backends first
and answer what they always did. `tests/suites/ssa.nim` now guards the
capability by intent rather than leaving it recorded only as a golden.

**One divergence is allowed and documented** (`deferExempt`). For
`defer: finish sock.value`, the old pass's skip set holds the PATH
`sock.value`; its root rule then asks whether `sock` is dead, does not find
`sock` in the skip set, and stamps it — although the defer reads `sock` at
scope exit through that very field. The mirror refuses. Inert today, since
`sock` is a local and nothing consumes a local's stamp, but reproducing a
hole to make a differential green is how a hole becomes permanent.

**Two rules in the new code are NOT EXERCISED by the corpus**, established
by sabotage rather than assumed:

* *a twin hands back what it was given, so the result is ours when the
  argument was.* Disabling it changes no stamp anywhere, because
  `afterBinding` already calls such a binding fresh — which is item 4 doing
  the work, and exactly what Stage C removes. The rule is kept because it is
  what will carry the fact once that prediction is gone.
* *the per-field slot test on a projection.* Also unexercised. Kept because
  it refuses moves rather than granting them, which is the safe direction.

The rule that IS exercised is the one that matters most: treating a
parameter as owned wrongly stamps 12 sites across the corpus, every one of
them a use-after-free on D and Odin.

**What it cost.** One crash, and it says something about the Stage A proof.
`R.W = true` is an assignment whose target has no nameable place — an
`exkField` over a memory-mapped register — and the builder read `brReceiver`
off a field node and took the compiler down. No example assigns a register
field with `=` (examples/20 uses the chain form throughout), so the
corpus sweep never produced the shape; it surfaced only once the mirror
moved onto the hot path for every D and Odin build, and `known_bugs`'
register assertion is what caught it. The `ssa` suite now carries all three
unnameable targets directly, because a corpus can only exercise the shapes
it happens to contain.

**C. Make the lowerings explicit rewrites.**
In-place append, self-concat, and the twin call become rewrites on the
mirror, performed *before* emission. The emitters stop deciding and start
transcribing. Item 4 goes away, and so does item 1, because there is no
longer a per-position decision to forget. This is also the stage the earlier
ruling was aiming at: *"we can make tree transformations that will simplify
the backends — the code they'll see passed to them is simple — and ensure
they get the correct semantics and not accidentally their own
interpretation."*

### The obvious decomposition does not work, and here is the measurement

The tempting half-measure is to leave the emitters alone and just stop
`afterBinding` guessing: refuse the freshness claim wherever an emitter fast
path will lower the binding in place, and let the mirror's flow rule (*a
twin hands back either a buffer it allocated or the one it was given*) carry
ownership through instead. Tried, with a precise predicate — the target is
the PRIMARY operand of the value, which is the position every in-place
lowering mutates:

| | move stamps | world_server | matching_engine |
|---|---|---|---|
| today | 24 | 536 MB | 10 MB |
| afterBinding stops guessing | 24 | **1 630 MB** | **1 613 MB** |

The move decision is untouched — the mirror's flow rule does carry ownership
exactly as intended. What collapses is the COPY decision, which is a
different consumer: `lowering_seqcopy.markSeqCopies` asks
`exclusivelyOwned`, and that reads provenance's cells **directly**, not the
mirror. Starve those cells and the elision goes with them, so every binding
gets its defensive copy back and abandons it.

So Stage C is not "remove the prediction". It is **move the copy decision
onto the mirror first, then remove the prediction** — and the copy decision
needs more than ownership. `exclusivelyOwned`'s allocation tokens exist to
catch `return {a: xs, b: xs}`: two fields, one buffer, both `oFresh`. The
mirror does not model that yet; both fields are projections of one call and
nothing says they collide. Tokens, or something like them, have to come
across before the prediction can go.

**How big item 4 actually is, measured rather than guessed.** Twelve
assignment sites across the corpus and both applications are marked as
needing a copy by `markSeqCopies` and then lowered in place by a fast path
that never consults the mark — the exact set where `afterBinding`'s claim is
unbacked (`TUCK_DEBUG_INPLACE=1`). None of them reaches a consumer that
misuses the claim, for the two reasons under item 4 above. That is what
"latent" means here: twelve known sites, none live, and a named reason for
each.

**D. Free insertion falls out.**
EV-14 becomes: a value that `owns` and has no live use is freed after its
last use. No position to miss. This is the stage that should not be attempted
before C, because a missed position is a leak and a wrong one is a double
free, and today there is no single place to put the decision.

## A note on the suite flake, since it cost time to rule out

`odin_backend` and `recursive_types` each fail intermittently, and it is
neither the mirror nor the emitted code. The message is

```
odin rejected the emitted code (rc=1): Intrinsic called with incompatible
signature   call void @llvm.memset.p0.i64(ptr %7, i8 0, i64 16, i1 false)
```

— Odin's own LLVM backend failing its verifier, on source that compiles on
the next run and every run after. Both suites pass in isolation, repeatedly.
Worth writing down because "a suite went red after my change" is the right
reflex and this one answers to a re-run rather than to a bisect.

## What this does not buy

Worth stating so the cost is not argued for twice.

It does not make Nim faster — Nim already gets `sink` and hands the rest to
ARC, and every measurement this week has shown the Nim backend unmoved by
this whole line of work. It buys D and Odin, where the copies are real.

It does not remove the backends' semantic differences; it removes the places
where *we* have to predict them.

And it is not free: stage A is pure cost, paid to make B through D safe. The
argument for paying it is that the six items above cost more than that
already, and item seven is queued.
