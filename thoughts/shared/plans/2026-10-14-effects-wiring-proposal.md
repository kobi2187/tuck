# Wiring the other effect markers — proposal, 2026-10-14

Status: **built 2026-10-14** on `claude/effects-mechanism`: families and
restriction call rule (EF03), combinations (EF04), allocating constructs (EF05),
`stack` recursion (EF06), ISR send (EF07), derived facts + `tuck effects`,
annotated std externs, `--host-checks` (Nim `noSideEffect` for `[pure]`).
**Not built:** D `pure @nogc nothrow` and Odin equivalents (no dmd/odin in the
session that built the rest, so unverifiable), `-d:tuckChecks` debug
assertions, single-producer lock elision, cross-module derived facts (the
signature index carries declared markers only), `-O:inline`, `fn memo` (#69).
`[stack: N]` was later split into `[no_recursion]` (static) and `[recursion: N]` (runtime limit). Ruling 2026-10-14: the mailbox stays as tuned; an ISR cannot send (TK-EF07), and the workaround is for the ISR to set a flag or write a ring that a task or actor drains. No lock-free mailbox. Rulings of 2026-10-14 are in §6; §3.5 is the
implication table the owner asked for. Original text: **design, nothing built.** Rulings of 2026-10-14 are in §6; §3.5 is the
implication table the owner asked for.

Follows #14 (the compiler says what to declare or remove, for `[io]`). This is
ROADMAP S4.1 / issue #64: only `[io]` has checker logic today; `no_alloc`,
`irq_safe`, `unsafe`, `may_block`, `stack` and `priority` parse and are
otherwise inert, and #62/#63/#65/#67 wait on them.

## 1. What is wrong today (measured, not assumed)

The effect pass (`compiler/semantics.nim`) treats every marker the same way:
*a callee's declared markers must all be in the caller's declared markers*.
That is correct for a **capability** (`io`: doing I/O is something a caller must
admit to). It is backwards for a **restriction** (`irq_safe`, `no_alloc`: a
promise about everything below you). Two probes on current `main`:

```tuck
fn tiny({x: int}) -> int [no_alloc, irq_safe]: return x + 1
fn normal({x: int}) -> int: return {x: x} tiny      # REJECTED, wrongly
# Effect Error [TK-EF01]: Expression requires effect [no_alloc], which is not
# allowed in context of 'normal'

fn plain({x: int}) -> int: return x + 1
fn isr({x: int}) -> int [irq_safe]: return {x: x} plain   # ACCEPTED, wrongly
```

An ordinary function may call a restricted one; a restricted function may only
call restricted ones. The check runs the wrong way round. The one existing
`irq_safe` assertion ("an irq_safe fn may not call a may_block one") passes only
because `may_block` happens not to be in `irq_safe`'s budget.

## 2. Three families, not one

| family | markers | rule | direction |
|---|---|---|---|
| **capability** | `io`, `may_block`, `unsafe`? | callee's markers ⊆ caller's declared markers | obligation propagates **up** (done for `io`) |
| **restriction** | `no_alloc`, `irq_safe` | if the caller declares R, every callee must be R (or be known R) | obligation propagates **down** |
| **attribute** | `stack: N`, `priority: N` (and `inline`) | no propagation; configuration | none |

`ast.EffectMarker` becomes three sets (`CapabilityMarkers`, `RestrictionMarkers`,
`AttributeMarkers`) so each rule is one `for` over one set, and a new marker has
to be filed under a family to compile (the repo's no-`else` rule).

## 3. The rules

### 3.1 Restrictions (the real work)

**Call rule.** In a fn declaring restriction R, every call must reach a callee
that declares R. This is the mirror of the capability rule and reuses the same
walk (`callEffects` already finds the callee and its declared set).

**Conflict rule.** `irq_safe` excludes the capabilities that cannot run in an
interrupt: declaring `irq_safe` together with `io` or `may_block` is an error
(TK-EF04), with the fix spelled out. This subsumes the spec §3.7 sentence "an
`[irq_safe]` function calling an `[io]` function is a compile error" and makes
the existing `may_block` test pass for the right reason.

**`no_alloc` has a second half: the body itself.** A call rule is not enough,
because allocation is mostly *syntax*, not calls. In a `[no_alloc]` fn these are
errors (TK-EF05), each naming the construct and a fix:

- a `Seq` literal or a growing `Seq` op (`exkList`, `exkAppend`, `push`);
- `str + str` (`tuckConcat`), `toStr`, `split`, any std fn that returns a new
  `str`/`Seq`;
- an explicit `copy` of a heap value;
- constructing a record that contains a `Seq`/`str` field *from a non-literal*.

Not allocation, so allowed: fixed `Array[N, T]`, stack records, `pool` / `slab` /
`arena` operations (their storage is declared and sized at compile time —
that is what they are for), and string *literals*.

The list lives in one place (`allocatingConstructs` in `semantics.nim`) so a
reviewer can argue with it, and a new construct has to be classified.

**Unknown callees (ruled 2026-10-14).** A restricted fn calling an **extern with
no marker is rejected**: it is not known to be R, and the fix is "declare
`[no_alloc]` on the extern if it is true". That forces the stdlib externs to be
annotated once (`sqrt`, `bitAnd`, `nowMs`, …), which is the right place for the
claim to live. A call to a **`pending` fn is ignored** (a stub is an unwritten
body, not a claim; it neither passes nor fails the rule, and the existing
PENDING report already lists it). A *gradually typed* callee (Unknown) in a
restricted body is an error: you cannot promise what you cannot see.
Restrictions are opt-in, so this only bites code that asked.

### 3.2 Capabilities

`io` is done (#14). `may_block` is `io`'s sibling: same up-propagation, plus the
conflict with `irq_safe` above. It needs no new walk.

### 3.3 Attributes

- `stack: N` — parse and keep. A real check needs frame sizes, which source
  does not have, so the first version checks only what is decidable: a fn
  declaring `stack` must not be (mutually) recursive and must not call an
  unbounded-depth fn; it reports the static **call depth**. It does *not* claim
  to bound bytes. (An honest weak check beats a fake strong one.)
- `priority: N` — configuration for the scheduler/ISR table, not an effect.
  Move out of `EffectMarker`; no propagation.

### 3.5 Combinations and what they imply (the compiler infers, the user declares)

Markers are not independent. Each row is a rule the compiler checks and *says
out loud*, in the #14 style (declared in code; the compiler names what to add or
remove). An implication is an **error with a fix**, not a silent addition, so
the signature still tells the whole truth at a glance.

| declared | the compiler infers | what it tells you |
|---|---|---|
| `irq_safe` | excludes `io`, `may_block` | TK-EF04 if you also declare them |
| `irq_safe` | requires `no_alloc` (an interrupt cannot take the allocator's lock) | "an `[irq_safe]` fn must also be `[no_alloc]`: add it" (TK-EF04) |
| `irq_safe` | every callee must be `irq_safe` (hence `no_alloc`, not `io`/`may_block`) | TK-EF03 at the offending call, with the callee's missing markers listed |
| `no_alloc` | every callee `no_alloc`; no allocating construct in the body | TK-EF03 / TK-EF05 |
| `no_alloc` + `io` | compatible (I/O does not imply allocation) | nothing |
| `may_block` | excludes `irq_safe`; propagates up like `io` | TK-EF04 on the pair; EF01 for a caller that did not declare it |
| `io` | propagates up (done, #14) | TK-EF01 / TK-EF02 |
| `stack: N` | forbids recursion on the call graph below it | TK-EF06 |
| none of the above on a leaf | **eligible** for `no_alloc` / `irq_safe` if its callees are | hint only, under `--suggest-effects` |

Two inference outputs the compiler can produce for any fn, shown by
`--suggest-effects` and used in the messages above:

- **required set** — capabilities its body needs (what #14 already reports);
- **eligible set** — restrictions the body could carry (all callees carry them,
  no allocating construct), i.e. the promotions an embedded author is looking for.

A violated implication always names the *smallest* fix: the marker to add, the
marker to remove, or the call to stop making.

### 3.4 Help, in the #14 spirit

The compiler already knows, for every fn, whether it *could* carry a
restriction (all callees do, no allocating construct). Same two-sided help as
`[io]`:

- violation → spells the fix at the offending call or construct;
- `--suggest-effects`: lists fns that satisfy `no_alloc`/`irq_safe` but do not
  declare them, so an embedded author finds the promotable ones. (Optional, last.)

## 4. Diagnostics (new, at the end of the EF block — numbers are permanent)

| code | meaning |
|---|---|
| TK-EF03 | a `[R]` fn calls something not declared `[R]` (restriction call rule) |
| TK-EF04 | a restriction declared together with a capability it excludes |
| TK-EF05 | an allocating construct in a `[no_alloc]` fn |
| TK-EF06 | `[stack: N]` fn is recursive / has unbounded depth |

Each message names the call or construct, the fn, and the fix.

## 5. Order of work (each step independently shippable and tested)

1. **Family split + fix the false error.** Reorganise the marker sets; capability
   rule only for capabilities. Fixes `normal -> tiny`. Tests: both probes above.
2. **`irq_safe` call rule + conflict rule** (TK-EF03/04). Small; existing
   precedent in `declarations`.
3. **`no_alloc` call rule**, plus annotating the std externs.
4. **`no_alloc` allocating-construct list** (TK-EF05).
5. **`stack` depth** (TK-EF06) and moving `priority` out of the effect set.
6. `--suggest-effects`.

Cross-module: restrictions need the callee's *declared* set across imports, which
`importedEffects` already carries for capabilities (and now for extern fns, #113).

## 6. Rulings (2026-10-14)

1. **Externs/`pending` under a restriction:** `pending` ignored; an extern with
   no marker is rejected; compiler infers and reports the combinations and their
   implications (§3.5).
2. **`[unsafe]`:** a **local escape, reported**, not a propagating effect. A fn
   that contains an escape does not force its callers to declare anything; a
   report (like `--report-narrowing`) lists every site. §3.7 and §4.4 of the spec
   should say so; the `unsafe` marker leaves the propagating set.
3. **`stack` and `priority`** are attributes (no propagation).
4. **`alloc`** is dropped from the spec's marker list; `no_alloc` covers it.

Still open, small: whether `irq_safe` *requires* writing `no_alloc` (as §3.5
proposes, in keeping with "declared, not inferred") or *implies* it silently.
Recommendation: require it written.

## 7. What the combinations let us derive (added 2026-10-14, at the owner's prompting)

Effects are not only checks. Once the compiler knows, per fn *and per block*,
which capabilities a body needs and which restrictions it could carry, it
holds **facts** the backends can use — to run faster, to take fewer locks, and
to check themselves. Nothing in this section is written by the user; these are
*derived*, shown by `--suggest-effects`/`--report-effects`, and used by passes.

### 7.1 Derived facts

Computed bottom-up over the same call-graph walk the effect pass already does
(`synthesizeExpr` works on any `Expr`, so a block is as easy as a fn):

| fact | holds when |
|---|---|
| **pure** | no capability needed (`io`, `may_block`, `unsafe`-escape), no read or write of actor fields, pool/slab/arena, registers or externs with state |
| **alloc-free** | `no_alloc` is declared, or every callee is and no allocating construct appears (§3.1) |
| **isr-context** | declared `irq_safe`, or reachable only from `irq_safe` fns |
| **bounded-depth** | no recursion below it (needed for `stack: N`) |
| **single-producer** | every `send` to an actor in the program comes from one execution context (whole-program: the compiler sees all send sites) |

**Unknown ⇒ no fact.** A gradually typed callee, an unmarked extern, or a `pending`
stub produces *no* derived fact, never an optimistic one.

### 7.2 What each fact buys

| fact | consequence | kind | notes |
|---|---|---|---|
| pure / alloc-free / leaf | emit the host's own contract: D `pure @nogc nothrow`, Nim `func` / `{.raises: [].}` | **verification** | the host compiler independently checks our claim; a disagreement is a compiler bug caught at build time. Cheapest and most valuable first step |
| pure + all-constant arguments | fold the call at compile time (extends `const`'s static evaluation) | speed | needs a compile-time evaluator over pure Tuck |
| pure small leaf | candidate for an `-O:inline` pass | speed | a second optimiser pass beside `chain-inplace` |
| alloc-free | drop ownership bookkeeping for heap values in the body (there are none) | speed | measure first; may be nothing |
| single-producer | lock-free single-producer mailbox for that actor | **less locking** | today the spinlock is compiled away only globally, by `--actors:single`; this does it *per actor* |
| a send site inside `irq_safe` code | the spinlock is **unsafe** there (an interrupt that preempts the holder deadlocks) | **check + selection** | either TK error "actor X's mailbox takes a lock, so it is not `irq_safe`", or, when the producers are only ISRs and the consumer is one thread, select the lock-free SPSC variant |
| `stack: N` | debug stack-watermark check at entry | assertion | complements the weak static check (§3.3) |
| alloc-free | debug allocation-counter check around the call | assertion | catches an extern that lied about `no_alloc` |
| `irq_safe` entry | debug assert "not on a coroutine / not already in an ISR" | assertion | |
| a block that is pure and alloc-free (a `for` body) | hand the host a side-effect-free closure so it may unroll / vectorise | speed | later: data-parallel `for` if aliasing is also proven |

### 7.3 Principles

1. **Checks stay checks; speed is opt-in.** A consequence that changes only
   *verification* (host attributes, debug assertions) can be on by default. A
   consequence that changes *generated code* is an `-O:` pass, off unless named
   (`optimize.nim`'s existing rule), with a differential test: same output with
   and without.
2. **Debug assertions are not the release-kept traps.** Overflow traps and
   invariants stay in release builds (2026-08-25 ruling 4/5). These are a separate
   `-d:tuckChecks` set, stripped in release, because they check the *compiler's*
   claim, not the program's data.
3. **Defence in depth before reliance.** The moment codegen depends on a derived
   fact, a checker bug becomes a miscompile. So the host-attribute cross-check
   (first row) comes *before* any speed-motivated use.
4. **Cross-module.** Facts must be recorded in the signature index
   (`SigInfo` gains the derived set) or an import silently loses them.

### 7.4 Memoisation is already planned — this work is its prerequisite

`fn memo name(...)` is the planned ROADMAP **#69**, in the same keyword slot as
`fn inline` (spec §3.6b), an `optimize.nim` pass that is off unless `-O` names
it. Its precondition is exactly the **pure** fact derived in §7.1: the compiler
checks it, the author asks for the transform, and a `fn memo` on a fn that is
not pure is a compile error naming the effect or state access that breaks it.
So the "derive `pure`" step in §7.5 is what unblocks #69; nothing else in this
proposal needs to change for it.

One note for when #69 is built, not a ruling: #69 says it needs "effect-free
**plus total**". For skipping a *repeated* call with equal arguments, totality
is not needed for correctness — the first call already returned (a trap or a
hang would have ended the program), so the second would return the same value.
`total` is needed only if the transform may *reorder* or *speculate* calls.

Still not proposed: automatic (unrequested) memoisation, auto-parallelisation,
and reordering calls on the strength of `pure`. They need aliasing and FFI
proofs the language does not have.

### 7.5 Order (after §5 steps 1–4)

1. Derive the facts and expose them (`--suggest-effects`, `--report-effects`).
2. Host attributes as a cross-check, with a test that a deliberately false claim
   is caught by the host.
3. Debug assertions behind `-d:tuckChecks`.
4. Mailbox: single-producer lock elision, then the ISR send-site rule.
5. `-O:inline`, compile-time folding of pure calls, then **#69 `fn memo`**
   (uses the pure fact from step 1).

### 7.6 Decisions

- Host-attribute cross-check **on by default** (recommended: it only adds
  verification) or behind a flag?
- ISR send to a locked mailbox: **error** (recommended first, simple and safe) or
  auto-select the lock-free variant?
