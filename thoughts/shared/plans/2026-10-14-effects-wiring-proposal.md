# Wiring the other effect markers — proposal, 2026-10-14

Status: **design, nothing built.** Decisions needed are in §6.

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

**Unknown callees.** A restricted fn that calls an extern or `pending` fn with
no marker gets the conservative answer: it is not known to be R, so it is
rejected, with the fix "declare `[no_alloc]` on the extern if it is true". This
forces the stdlib externs to be annotated once (`sqrt`, `bitAnd`, `nowMs`, …),
which is the right place for the claim to live. A fn that is *gradually typed*
(Unknown callee) in a restricted body is also an error: you cannot promise what
you cannot see. Restrictions are opt-in, so this only bites code that asked.

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

## 6. Decisions needed

1. **Externs with no marker, under a restriction:** reject (conservative, my
   recommendation) or assume-safe-with-a-warning?
2. **`[unsafe]`:** spec §3.7 lists it as an effect, but §4.4 uses it as a *local
   escape* at a construction site (`X.Connected [unsafe] {..}`). Should a fn that
   contains such an escape (a) have to declare `[unsafe]`, forcing callers to
   (propagating, like `io`), or (b) stay local and just be *reported*, like the
   narrowing report? Recommendation: **(b)** — a contained, audited escape, as in
   Rust; a propagating `unsafe` makes every caller of anything sealed look unsafe.
3. **`priority` and `stack`** reclassified as attributes (no propagation)?
4. **The `alloc` marker** in spec §3.7's initial set is not in the compiler.
   With `no_alloc` as the restriction it is redundant; drop it from the spec?
