# Tuck Roadmap (as of 2026-07-09)

Status legend: DONE = parse+check+codegen+tested. Gate = generated Nim passes
`nim check` (13/24 examples).

## Done
Postfix calls, subset matching, let/var + `..`, sum types, sealed transition
tables (runtime matrix + reachability), decision tables (exact enum analysis,
packed-key codegen), distinct types/units, `!T ?T !?T` + `?` + global error
policy §4.9, effect enforcement, pending blocks + stubs + TODO report,
imports + `::` + msgpack AST cache + signature index, registry §10, register
decl §8.1, sizeof/alignof/offsetof §8.2, static_assert, invariant → validate()
proc, tuck CLI (lex/parse/check/compile), generics v1 (simple substitution,
call-site inference, lowered to Nim generics; ceilings: no generic-record
construction, generic bodies gradual, no constraints). `when TARGET == "...":`
conditionals §8.3, 2026-08-11: resolved at module load (uncached — see
modules.resolveWhenBlocks), `--target:NAME` CLI flag, both backends need no
codegen changes since the AST is already filtered before codegen runs.

`pred`/`set` fn prefixes §3.6 — DROPPED 2026-08-11 (never implemented, and
formally will not be: effect markers already gate side effects, `..`-on-var
already gates mutation, so a third purity mechanism at the keyword level
would duplicate a rule rather than add one). Spec §3.6 rewritten to record
this instead of describing unbuilt syntax.

## User rulings (2026-07-09)
- §6.3 complexity limit: ENFORCE as hard compile error (cyclomatic ≤ 5,
  ~10–15 executable lines/fn).
- `Foo {}`: legal only when the type has no fields (empty state is a valid
  type). Types with fields require every field at construction; absence must
  be explicit `?T`. Add to spec §4.8.
  RE-RULED 2026-08-14 — partial construction is LEGAL; the unsupplied fields
  are `<uninit>`, a compile-time-only state with no runtime representation.
  Three rules: never read it and the program compiles, read it unset and that
  is the error (TK-TY16), assign it and the marker is gone. Rejecting at the
  construction site would have refused the builder pattern (construct partial,
  fill by chain, then read), which works and is worth keeping — this is the
  data analogue of `pending:` (§5.4), so a walking skeleton can carry holes in
  its DATA as well as its functions. The marker rides in the field's type, so
  storing a partial record inside another cannot launder it. `{}` on a
  zero-field type is unchanged. Function CALLS still require every field —
  only type/object construction changed.
- Actors/tasks: API stays actors + tasks. Runtime strategy SETTLED (2026-08-05):
  stackful coroutines over vendored minicoro with mmap'd virtual stacks, one
  cooperative scheduler, and an epoll/kqueue reactor. Neither nim-cps nor
  hand-rolled stackless state machines — both backends drive the same C
  library, so they cannot diverge on switch semantics. §9.2/9.4 are built and
  run-gated (examples 26/27/28/42).
- Effects §3.7: RE-RULED 2026-08-11 — require-declared stays. The
  infer-and-propagate ruling above was never implemented; re-examined and
  reversed instead of implemented, since explicit declaration at every level
  fits Tuck's "everything explicit" stance (spec Part 1) better than silent
  upward inference would. Spec §3.7 rewritten to describe require-declared as
  the real (and now permanent) design.

## User rulings (2026-07-09, session 2) — error model + OS layer
- `extern:` blocks (DONE): sigs implemented by tuck_rt; `extern [c, header:
  "uart.h"]:` emits Nim importc — the C/bare-metal seam. Tuck→Nim→C→gcc
  covers embedded; `tuck build` will forward nim flags (--os:standalone etc).
- Stdlib v1 scope: fs, io, sys (os/env), time — extern sigs over Nim stdlib.
  Full bottom-layer catalogue (what to extern vs write, per domain, incl.
  embedded/atomics/net/proc): stdlib-blocks.md. Layer map above it
  (L0→L5 dependency graph, build order, derive ruling): stdlib-layers.md.
- Errors are declared enums (fieldless sums), named in the signature via
  `[error: FsError]` attr (effects bracket). Effects ≠ errors: [io] still
  propagates upward independently.
- The enum never flows bare — always inside the result struct
  {ok, err, value}. Raise site: `return err FsError.NotFound`, shorthand
  `err NotFound` resolved against the sig's declared error type.
- `expr?` propagation operator DROPPED. Handling = local if/ifErr/.ok
  access, or return the whole result up. Policy 4.9 unhandled list tracks
  the rest. (Parked idea, not firm: call-site `get!` as io marker.)
- `or return` DROPPED (2026-07-22), same reasoning as `expr?`: it was a
  second, weaker unwrap that discarded WHICH error occurred. `and`/`or`/`xor`
  are now strictly boolean, enforced by the checker (there had been no
  operand rule at all — `5 or "x"` typechecked). A `?T` operand in a boolean
  position reads as "is present": a test, not an unwrap. Pool `acquire`
  (§7.2) returns `?T` and is handled with an ordinary `if`.
- Tri-state result STAYS: `int?!` = fallible + optional in one value.
- Type wrapper position: both accepted — `int?` == `?int`, canonical
  postfix; combos `T?!`/`T!?` equivalent.

## User rulings (2026-07-11) — resource registry (spec §7.4, design only)
- Global per-kind registry in tuck_rt (slot table = pool §7.2 machinery);
  user code holds u32 index+generation HANDLES (Tier-1 values), refs stay in
  the runtime layer.
- Kinds user-declared via `resources:` block (open set, like error enums);
  acquire sites marked `[resource: kind]` in the effects bracket, propagated
  by the effects machinery. Unknown kind = checker error.
- `defer` block = release INTENT: marks isFinished, runs per-kind `on_finish`
  (file: flush), bumps generation (handle dies at mark under every policy).
  Actual close per policy strict/lazy/exit (errors-decl symmetry).
- No refcount — single owner, one isFinished bool; eviction candidates =
  finished entries only.
- Cap optional: absent → seq-backed unbounded; present → on_full policy,
  static array on standalone. Watermark sweep (~75%) runs INLINE in the
  defer-release code (mark checks threshold, evicts all finished or in
  user-specified batches, `sweep_batch: 100`) — no thread/actor; explicit
  `kind::sweep` for scheduled cleanup. NO idle/time-based eviction. LIFO
  close-all.
- Static check: every acquire ends in defer-mark or registry escape (escape
  always sound); scope-local analysis only. Debug `OPEN RESOURCES (n)` report.

## User ruling (2026-08-24) — no function overloading, deliberately

**Decided: free functions do not overload, and this is not a gap to close.**
Two same-named `fn`s are rejected with `[TK-TY02] duplicate declaration`
regardless of whether their payload types differ; only object members
overload, resolved by receiver.

The reason is readability: **a call site should say which function it calls
without the reader reconstructing parameter types.** In a language where
arguments bind by name and by type across a payload — with subset matching,
so extra fields are ignored — an overload set would make the resolution
genuinely hard to see at a glance. One name, one function, is the better
fit.

Consequences, accepted rather than worked around:
- The stdlib carries suffixed pairs where a Rust/Nim design would overload:
  `dot`/`dot3`, `length`/`length3` (`core.geom`), `feedFast`/`feedSafe`
  (`core.hash`), `rollRange`/`rollFloat` (`std.random`), `getEnv`/`setEnv`
  (`sys.env`), `sqrtOf`/`lnOf` (`std.math`).
- `platform.power` loses the nicest bit of its Nim design — `wakeOn(duration)`
  / `wakeOn(pin)` / `wakeOn(time)` overloaded on argument type, so the enum
  never appeared at a call site. Now the `WakeSource` is constructed
  directly. This is the clearest cost of the ruling and is accepted.
- Odin cannot overload either, so the mangler already assumed this; the
  ruling keeps the two backends aligned rather than making Odin the
  constraint.

Supersedes the "minimum rule that unblocks the geom case" sketch produced
while investigating this (declaration-time pairwise ambiguity check plus a
mangle-time index) — that work is not wanted.

## User ruling (2026-08-24) — numeric conversion is always explicit

**Decided: crossing a numeric type boundary is always written in the source.
Both directions. No exceptions.**

Not a new rule so much as enforcing one the spec already states — Appendix B
lists *"implicit conversions"* among the things Tuck deliberately does not
have. Today `compatible()` lets any numeric primitive match any other, so
the rule isn't enforced.

```tuck
fn setDuty({channel: int, permille: u16}) -> void

let wide: u32 = 70000
{channel: 1, permille: wide} setDuty         # ERROR: u32 -> u16 needs a cast
{channel: 1, permille: wide ~u16} setDuty    # explicit, in the author's own code
```

**Widening is written too** (`^u32`), even though it cannot lose anything.
Uniform beats "the safe direction is silent": nobody has to remember which
way is which, and the sign-crossing trap stops being a special case — `-5`
into `u32` is *wider* in bits and still lossy, so a width-based exemption
would let exactly the wrong case through.

**The reason, in the user's words:** the user knows where the mistake came
from — his own code. A cast in the source is greppable and blameable; a
silent conversion inside the checker is neither.

### A casting word as well as the sigils
`to` is proposed alongside `~`/`^` for readability at call sites where a
sigil is dense. Spelling not settled — `wide to u16` vs `wide ~u16`, and
whether both exist or the word is just an alias.

### Where it lives in the compiler
`compiler/typecheck.nim:263`'s `compatible()`, final line:

```nim
when defined(strictKind): false   # measure the same-kind fallthrough
else: a.kind == e.kind
```

Every numeric primitive is `tkPrim`, so that one line is what lets `u32`
satisfy `u16`. The `strictKind` define already exists for measuring the
blast radius. `compatible()` itself may be removed later rather than
tightened — it is doing several jobs.

### Arithmetic overflow is a separate concern — and mostly unimplemented
Confirmed this pass: **only `[saturating]` has codegen.** `[wrapping]` and
`[trapping]` appear exactly once in the compiler
(`codegen_common.nim:99`), in a list that makes them imply `distinct` —
they emit nothing, so the behaviour is **whatever the backend happens to
do**. That is C semantics by inheritance, not by decision.

The intended answer is trapping and/or overflow attributes as the safe
alternative to C, likely via compiler-known internal types so a bare `u32`
can carry a policy the way a `distinct` does. Not designed here.

### Order of work
1. Enforce no-implicit-conversion at binding sites (the `compatible()` line).
2. Implement `~` / `^` (and decide `to`), so there is a way to say yes.
3. Implement `[wrapping]` / `[trapping]` for real, then decide the
   bare-primitive default — in that order, since a default that names
   `[trapping]` is theatre until trapping traps.

## User ruling (2026-08-24) — optional variant sets in fn signatures

**A fn taking a transition-typed argument MAY declare which variants it
accepts. Bare type = all variants (unchanged); a declared set narrows.**

```tuck
type ProtocolStage:
  | Handshake
  | Login
  | Active
  | Processing

fn doAfterHandshake({x: int, stage: ProtocolStage<Login|Active|Processing>})
```

Calling that with a `Handshake`-stage value is a compile error — the
function is callable only in the states it names. **Optional by design:**
existing signatures keep working, and an author opts in where the
distinction earns its keep.

*Syntax not settled* — the angle brackets above are illustrative. Tuck uses
`[T]` for generics and `[...]` for attributes, so this needs a spelling
that doesn't collide. Deferred; the semantics are the ruling.

### It relaxes a documented rule rather than reversing it
Spec §4.4b currently says:

> **Function boundaries carry the narrowing, not the signature.** A fn's
> declared param/return type stays the general `Type` (no `@Variant` in
> signatures)…

That put the knowledge in the checker's inference rather than the
declaration, and the spec names the cost itself: **"return-site tracing is
module-local (cross-module calls yield the full set)."** An optional
declared set fixes that where an author asks for it — the set travels with
the signature, so it survives a module boundary with no inference at all —
while inference stays the default everywhere else.

### Why it fits
- **Same shape as `[error: FsError | NetError]`**, which already puts a
  variant set in a signature and validates `match` arms against it. State
  and failure get the same treatment.
- **Typestate without a new concept.** "Only valid in these states" is what
  protocol bugs look like — sending before the handshake, reading after
  close — and §4.4b's flow analysis (per-var variant sets, branch merges,
  match narrowing) already exists. This gives it something declared to
  check against.
- **Documentation that cannot drift**, since the checker enforces it.

### Scope, decided
- **Params only. Return position is out of scope** — the point is to limit
  *calling* a function, statically, with the compiler's help. Narrowing a
  caller's result from a declared return set is a different feature and
  isn't wanted here.
- **Interfaces: exact match. A wider implementation does NOT satisfy a
  narrower contract.** Conformance already matches params exactly, names
  included (`tests/suites/interfaces.nim:122`), and this follows that rule
  rather than introducing variance. An interface declaring
  `ProtocolStage<Login|Active>` is satisfied only by an implementation
  declaring the same set.

### The error message is part of the feature
This exists so a user learns statically what they got wrong. The diagnostic
should name the three things they need: the states the fn accepts, the
state the value is actually in, and where it got that state.

Something like:

```
Type Error: 'doAfterHandshake' accepts ProtocolStage in Login|Active|Processing,
but 'stage' is Handshake here.
  stage became Handshake at protocol.tuck:14 (construction)
```

The "where it got that state" line is what makes it actionable — §4.4b's
per-var variant sets already track this, so the information exists. Compare
`FRICTIONS.md` #7 (the opaque-handle-in-actor-field error) as the house
standard: it names the type, the rule, the position, and a way forward.

## User ruling (2026-08-25) — numeric defaults, narrowing, and unsigned subtraction

Completes the 2026-08-24 conversion ruling above; supersedes the parts noted.

### 0. The rationale: shorten the search for a bad number
We trust the developer knows what they are doing. The risk is not that they
write a bad conversion — it is that **a weird value appears somewhere far
from where it was created**, and they have no idea which line produced it.

Everything below is aimed at that, and nothing below tries to prevent the
bug outright:

- **The sigils (`~` / `^`) mark the sites in the source.** Every place a
  number crosses a type is greppable, in the author's own code.
- **The warnings list the sites the compiler suspects.** Not proof — just
  "these are the places it could have happened."
- **Trapping stops execution at the site** rather than letting a wrong
  number travel (see ruling 4).

That is why the compile-time half is deliberately weak: it is a *search
narrowing tool*, not a correctness proof. Judged as a proof system it fails;
judged as "which of my 400 lines could have made this 65503", it works.

### 1. Bare `int` is the native word (64-bit on hosted targets)
64-bit ops are fast, and at that width ordinary counting and arithmetic do
not overflow. So there is **nothing to warn about on the common path** —
overflow is a concern only where an author *chose* a narrow type (a protocol
field, a register, a memory budget), and there the attribute applies.

**A declared type is always respected — the default never overrides it.**
If the user writes `i16`, `u32`, or annotates a literal with a numeric type,
that is the type. No silent promotion to `int64`, no "helpful" widening.
The default fills an *absent* annotation; it does not second-guess a present
one.

This supersedes the earlier instinct to warn on arithmetic generally: with a
64-bit default the warning would fire almost entirely on code that is fine.

*Note:* this likely simplifies the spec's "declared types never auto-widen
(`u8 + u8` stays `u8`)" clause — literals and intermediates are `int`, and
declared narrow types bind at storage. Worth re-reading §4.1 against this.

### 2. What the compiler can actually say — no ranges, so no proofs
**Tuck has no range/interval analysis, so the compiler cannot prove a
variable's value fits.** It has exactly two things:

- **Constant folding** — a literal or `const` is evaluated, so
  `70000 ~u16` is *certain* not to fit. That is an **error**, not a warning.
- **Type-width reasoning** — for a variable, the compiler knows only that
  *some* values of the source type do not fit the target. It cannot know
  whether *this* value does. That is a **warning**, and the honest wording is
  "might not fit".

| case | what the compiler knows | verdict |
|---|---|---|
| literal / `const` that does not fit | certainty | **error** |
| literal / `const` that fits | certainty | silent |
| variable, source width > target | nothing about the value | **warn: may not fit** |
| variable, sign crossing | nothing about the value | **warn: may not fit** |

**Arithmetic results warn too, and there is no cast to hang it on:**
`a * b` or an exponent on a declared narrow type can exceed it with nothing
in the source to draw the eye. Wording: *"this operation may reach the
type's upper limit"*.

**Two rules keep these warnings from becoming noise** (a warning people
learn to ignore is worse than none):
- Arithmetic warnings fire **only on declared narrow types**. Bare `int` at
  64 bits stays silent — ruling 1 gives this for free.
- An overflow attribute **silences it**. `[saturating]` means the author
  already said what happens, so there is nothing left to warn about.

### 3. Unsigned subtraction yields `?T`
Underflow is not an overflow-policy question — **the operation has no
answer**, exactly like `pool.acquire` on exhaustion. `?T` is already the
language's word for that, and `.ok` is already the idiom.

```tuck
let count: u32 = 3
let r = count - 5        # ?u32 — absent, because it underflowed
```

The ceremony objection is answered by ruling 1: with `int` defaulting to
64-bit signed, unsigned types are rare and deliberate. Nobody writes guards
around a loop counter; they write them where they genuinely subtract from a
byte count.

**Open (small):** always `?T`, or only where non-negativity cannot be
proven? Always is simpler to explain and impossible to get wrong;
proof-conditional is friendlier but reintroduces "why does this one need a
guard and that one doesn't". Leaning always, given unsigned is now rare.

### 4. Trapping is the default overflow behaviour, on every backend
**Not whatever the backend prefers.** Confirmed this pass: only
`[saturating]` has codegen; `[wrapping]`/`[trapping]` appear once
(`compiler/codegen_common.nim:99`) in a list that merely implies `distinct`,
so today the behaviour is inherited from Nim/Odin by accident. That is C
semantics by default, which is the thing this ruling replaces.

**Why trapping rather than wrapping or saturating:** both of the others
produce a *plausible-looking* number that keeps travelling. A wrapped
counter is a hang; a saturated reading is a silently wrong measurement — and
by the time either is noticed, the origin is gone. Trapping stops at the
site, which is the same "shorten the search" goal as the sigils and the
warnings, applied at runtime.

Wrapping and saturating remain available **where the author asks for them**
by attribute — a protocol sequence number genuinely wraps, a sensor reading
genuinely clamps. The change is only to what happens when nobody said.

**Traps stay in release builds.** A wrong number in production is worse
than a slow one, and stripping the trap reinstates exactly the
travelling-bad-value problem ruling 0 exists to kill — in the one
environment where it is hardest to debug. Overflow checking is not a
debug-only assertion.

*Implementation note:* needs real codegen for `[trapping]` on both backends
before the default can be switched.

### 5. `invariant` gets a flag too — and should be available in release
Related decision, and it revises shipped behaviour rather than a pending
design. Today invariants are stripped unconditionally:
`compiler/codegen.nim:1398` emits

```nim
proc validate*(self: T) =
  when not defined(release): ...
```

The `when not defined(release)` is hardcoded into the emitted Nim, so there
is **no way to keep invariants in a release build** even when you want them
— which is the common case for anything where a violated invariant means
corrupt data rather than a slow loop.

Ruled: **swap the define, and flip the default to on.** This is a one-line
codegen change, not new machinery — `release` is itself just a Nim define,
so the emitted guard becomes a dedicated one:

```nim
proc validate*(self: T) =
  when not defined(tuckNoInvariants): ...
```

`tuck build` passes `-d:tuckNoInvariants` only when the user asks to strip
them (it already forwards Nim flags via `--nim:`). Invariants then stay on
in release **by default**, opt-out rather than automatic-off — which is the
right way round for a check whose whole job is catching corrupt data.

Same shape applies to overflow traps once `[trapping]` has codegen: one
dedicated define, checked at the emission site, not piggybacked on
`release`.

Care needed only in that this changes shipped behaviour with existing
coverage — `cli_smoke` run-verifies invariants aborting in four positions,
and those must stay green.

### The whole numeric story, after these rulings

| operation | mechanism |
|---|---|
| arithmetic on bare `int` | nothing — 64 bits is enough |
| arithmetic on a declared narrow type | warn "may reach the type's limit"; silenced by an overflow attribute |
| narrowing a value | `~T` / `^T`; error if a constant cannot fit, warn if a variable may not |
| unsigned subtraction | `?T` — underflow is absence |
| overflow, nobody said what to do | **trap** — stop at the site (ruling 4) |
| overflow, author declared a policy | `[saturating]` / `[wrapping]` / `[trapping]` |
| any cross-type numeric flow | always written (2026-08-24 ruling) |

## Partial
| Feature | Spec | Missing piece |
|---|---|---|
| Static transition checking | 4.4b | CORE DONE 2026-07-13: per-var variant sets (Type@Variant), reassignment-as-transition vs the table, if/match/loop set merges, match narrowing, param full-set entry, module-local return tracing, sealed-RHS exemption. Caught a real bug in ex 20 on first run. Ceilings: cross-module fns → full set; helper fns building sealed variants need [unsafe]; match arms single-line; optional debug assertion emission not done |
| Invariants | 4.7 | construction + return sites DONE (2026-07-11; validate() auto-inserted, `when not defined(release)` strips). mutation sites, extern boundaries and `!T`-wrapped returns ALL DONE 2026-07-13 — every production site now validates (constructions, returns, `..` chains, extern call sites; !T payloads validate transitively via construction). Both backends, runtime-verified. Ruling: BLOCK syntax only |
| Actors | 9.1 | DONE 2026-08-05. Stackful minicoro coroutines, static ring mailboxes, cooperative scheduler + epoll reactor. `on <name>` and `on select` handlers both work on both backends (26/27 run-gated at 55). Ceiling: tuckNotifySend broadcast-wakes every actor per send, not the addressee |
| Tasks | 9.2 | DONE 2026-08-05 — but STACKFUL coroutines, not the state-machine transform this row assumed. `[io]` calls are yield points; binding a task's result awaits it. Ceiling: on Odin a task WITH ARGUMENTS still emits a direct call (proc literals cannot capture), so its body runs off-coroutine |
| bake | 3.5 | v1 DONE 2026-07-13 (Factor-fry: :name refs, fn→auto generic lowering, slot.invoke; ex 03 green+runtime-verified). Beef bake = delegate-type ceiling. True Tuck-IR inlining later if ever needed |
| alias restructuring | 2.5 | DONE 2026-07-13 (typed renamed record, both backends; ex 18 green). Non-exkVar payload args still not exploded (double-eval; bind-to-temp later) |
| pool / arena | 7.2/7.3 | acquire/release bitmask, reset, scope analysis, size verification |
| Interfaces | 5.2/5.3 | DONE. `satisfies` is checked at compile time; an interface value is a TAGGED VARIANT THAT COPIES, not a fat pointer — dispatch is a switch on the tag calling the concrete member fn, so there is no table, no thunk, and no lifetime question (escape analysis was deleted with the pointer design). Both backends |
| Type composition `+` | 4.5 | conflict detection unverified |
| match | — | exhaustiveness DONE: every match over a closed domain (sum type, bool, error enum) must cover all cases or end in `_`. Open domains (int/str) unchecked, as in Nim |
| Effects | 3.7 | switch to implicit propagation (ruling above) |
| ~~Beef backend~~ | — | REMOVED 2026-07-28. Frozen since the Odin backend landed, never compile-verified here (no BeefBuild), and every new construct meant a third unchecked emitter arm. Odin is the second backend |
| Odin backend | — | 2026-08-05: 41 examples compile-gated, 15 run-gated on exit codes; coroutine runtime over minicoro; full C FFI parity; offload worker + std/net mirrored. Known gap: a task WITH ARGUMENTS is not spawned as a coroutine |
| C FFI | — | DONE 2026-07-28: functions, cstring, structs by value, enums with explicit values, callbacks, opaque handles — all run-verified against a real C library on BOTH backends. `lib:` links a system library or a vendored `.c` |
| Control flow loops | 2.6/3.6b | DONE 2026-07-19: unified for (cond/iter/indexed), loop, break/continue (innermost, depth-checked), spaced-`..` ranges (Nim convention), fn inline ({.inline.}/[Inline]). Runtime-verified exit-17 smoke both backends. No labels ever (ruling); value-returning main = process exit code |

## Missing
- Resource registry §7.4 — parser (`resources` decl, `defer` block,
  `[resource:]` attr), checker (kind validation, propagation,
  acquire-must-finish tracking), rt slot table + inline sweep, codegen
  (mark/close per policy), OPEN RESOURCES report
- `on select` §9.3: the ACTOR form is done (ex 27, both backends). The TASK
  form lowers `read <fd>` / `timeout <ms>` only — dotted sources (`resp.ok`,
  `timeout.5s`) still parse as opaque strings, which is what blocks ex 16.
  Scheduler §9.4 is done (see Partial above).
- Stack-depth budgets `[stack: N]` §6.2
- Complexity limit §6.3 (ruling: hard error)
- Error.x validated against a declared error enum
- Visibility (pub/private), imported types via `::`, nested module paths

## Broken-example map (2026-07-13: Nim gate 21/25, Beef 20/25)
Remaining: 11 → when + pool + attr features (main-only ruling landed 2026-07-13); 16 → on select (actor-runtime
ruling); 20 → when + actor-transition lowering; 03 → Beef-side only
(delegate types). Everything else GREEN in both gates.

## Spec debt
None outstanding. §11/§12 (previously: describing npeg parser + flat IR +
Merkle cache while reality is recursive descent + ref-AST + hash-keyed
msgpack cache + signature index) rewritten 2026-08-11 to match the real
compiler — confirmed, per user ruling, that the built architecture is
preferred over the original design, not a gap to close.

## Experimental (2026-08-24) — three things to try

Speculative, deliberately kept apart from the status sections above.
Nothing here is committed; each is a "run the experiment, then decide."

### 1. A D (dlang) backend

A third backend beside Nim and Odin. D is a reasonable fit on paper —
value-type structs, compile-time evaluation, no mandatory GC path
(`@nogc`/`-betterC`), and a C ABI story — so much of what Tuck already
lowers should map without inventing new IR concepts.

What the experiment answers:
- **Does the two-backend discipline actually generalize to three?** The
  current invariant (each backend lowers its own deep copy; `case` over an
  enum takes no `else` so a new node kind breaks every backend that hasn't
  handled it) was designed to make this cheap. A third backend is the real
  test of that claim.
- **Where do Nim-isms hide?** Anywhere Tuck currently leans on a Nim
  feature without noticing, a D backend will fail loudly. That is worth
  knowing regardless of whether the backend ships.
- Odin already forced one such discovery (no overloading → the mangler),
  which is exactly the kind of finding to expect more of.

Cost is bounded: it's additive, and abandoning it leaves the tree no worse.

### 2. Slab allocator — the value-semantics answer for trees

**The problem, from the stdlib translation** (`stdlib-project/`): Tuck is
value-based with no `ref`, and that is load-bearing for the Tier-1 safety
argument. Recursive *data* works through `Seq` (a JSON tree typechecks and
builds), but two things don't:

- **Direct self-containment** — `Add({left: Expr, right: Expr})` is
  infinite-sized; it typechecks and then fails in the backend with
  `illegal recursion in type` (see `stdlib-project/FRICTIONS.md` #4).
- **By-reference node identity** — a linked list or an intrusive tree
  where you hold a cursor into the structure. `alloc.list` was dropped
  over this.

**The idea:** a slab — one owned arena of homogeneous slots plus integer
indices into it. Indices are ordinary values, so nothing about the
no-`ref`/no-stored-pointer rules is violated, and the slab owns every node
so lifetime stays single-owner. `Seq[Node]` + `int` child indices is
already the workaround the corpus uses; a slab type would make it a
first-class, ergonomic thing instead of a hand-rolled pattern.

Open questions the experiment should answer:
- Does it need language support, or is it a library over `pool`/`Seq`?
  (`pool` already gives fixed-count slots with `acquire`/`release` and
  `?T` on exhaustion — possibly most of a slab already.)
- Can index-vs-slab mismatches be caught? A raw `int` index into the wrong
  slab is exactly the class of bug `ref` types prevent; a `distinct` index
  per slab type might recover that.
- Ergonomics: `tree.child(n, 0)` versus `n.left`. If it stays clumsy,
  users will reach for externs instead — which is the status quo.

**Why not just rely on externs:** a user shouldn't have to leave the
language to build a tree. Worth solving inside Tuck even if externs remain
the escape hatch.

### 3. SoA — struct-of-arrays for `Seq[T]` and friends

Invert container layout: a `Seq[Point]` stores `xs[]`, `ys[]`, `zs[]`
rather than an array of `Point` — same API, different memory layout. Wins
are cache locality on field-wise traversal and real SIMD opportunities;
losses are whole-element access and any code that wants a `Point` back as
one value.

Three shapes to consider, easiest first:
- **Build `Seq` with SoA in mind from the start** — likely the cheapest
  path, since `Seq`'s implementation isn't frozen yet, and callers only
  ever see the API.
- **A separate type** (`SoaSeq[T]`) — explicit, opt-in, no surprises, but
  a second thing to learn and a second thing to keep in sync.
- **A compiler transformation** — most powerful, most invasive; needs the
  layout decision to be invisible and provably behaviour-preserving across
  both (three?) backends.

Interacts with two things already open:
- **The `Seq` copy question** (`stdlib-project/FRICTIONS.md` #8): how `Seq`
  crosses a call boundary is undecided, and layout and copying should
  probably be decided together rather than twice.
- **`core.simd`** — SoA is what makes vectorized field-wise work natural;
  the two experiments reinforce each other.

Measure before committing: `benches/` exists, and the honest outcome may be
"wins on the traversal benchmark, loses on the random-access one," in which
case the answer is a separate type rather than a change to `Seq`.
