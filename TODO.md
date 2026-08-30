# TODO — every known bug, gap and unfinished thing, in one place

Collated 2026-08-29. This file is an INDEX, not a replacement: each entry
says what is wrong, how confident we are, and where the full write-up lives.
Fix an entry, delete it from here and update its source.

**The suite is the authority.** `./tests/run` prints every `OPEN` line, and
`tests/suites/end_to_end.nim` checks the count in `MISSING-FEATURES.md`
against the number of `bugOpen` assertions, so those two cannot drift apart
silently. Everything else here is prose and can.

Sources collated:
`MISSING-FEATURES.md` · `stdlib-project/FRICTIONS.md` ·
`thoughts/shared/audits/stage-boundary-crossings.md` ·
`thoughts/ledgers/CONTINUITY_CLAUDE-d-backend.md` ·
`scratchpad/actor-playground/FINDINGS.md` ·
`scratchpad/iface-playground/FINDINGS.md`

Confidence key: **[repro]** reproduced by running · **[read]** read from the
code, not run · **[design]** a decision that was never made.

---

## 1. Design gaps — a decision was never made

These are not bugs. Nobody has ruled, so no implementation can be correct.

- [ ] **[repro] Full-mailbox policy is unstated, and today it deadlocks.**
  `send` is fire-and-forget and `[queue: N]` is a compile-time bound, so a
  mailbox can fill. The spec never says whether it blocks, drops or raises.
  Observed: it DROPS silently, and a `waitUntil` on the dropped work then
  spins forever. All three backends agree because D was built to match
  rather than invent a fourth behaviour. → FRICTIONS #9 (with the
  2026-08-29 update), actor-playground FINDINGS.
- [ ] **[repro] `send` without `waitUntil` never delivers.** 10 sends into a
  queue of 4 with no wait leaves the actor untouched: `main` never yields,
  so the daemon never runs. An actor program with no `waitUntil` and no task
  does nothing at all. → same sources.
- [ ] **[design] How `Seq` crosses a call boundary.** Emitted as a plain
  value in/out — no `sink`, no `var` — so an append loop is O(n²) today.
  The call-site spelling (`xs ..push {v}`) is already right either way, so
  this is a lowering decision, not an API one. → FRICTIONS #8.
- [ ] **[design] Correlation tokens for actor replies.** Decided in
  principle: the token is a payload field the CALLER generates, and the
  actor keeps a table (probably a hashtable, tracking finished values and
  pending work). Nothing implemented; no codegen change expected since the
  token rides as an ordinary parameter.
- [ ] **[design] Recursive types have no expression.** Direct
  self-containment is infinite-sized; the corpus works around it by indexing
  into a flat `Seq`. Fine in an arena world, but currently forced rather
  than chosen. Lands on `std.encoding`, `std.reflect`, ASTs, JSON.
  → FRICTIONS #4, ROADMAP "slab allocator" experiment.
- [ ] **[design] Hashing primitives.** `satisfies int: Hashable` is refused
  (correctly — `satisfies` matches declared objects), which leaves
  `Table[str, V]` with no way to hash its key. Blocks `alloc.map` and
  `alloc.set` entirely. A `fnsig` hash slot needs no language change and is
  the current front-runner. → FRICTIONS #6.

## 2. Unimplemented / partial language features

- [ ] **[repro] Generic `fnsig` does not parse.** `fnsig Mapper[T, U]` is a
  parse error, which blocks every higher-order generic API. The dangerous
  part is the workaround that LOOKS fine: a non-generic `fnsig` with bare
  `T`/`U` typechecks because gradual typing reads them as `<unknown>`, so it
  silently disables checking on the callback. → FRICTIONS #1.
- [ ] **[repro] Generic `actor` does not parse.** Blocks a service actor
  generic over its payload. Genuinely unclear whether it SHOULD exist — an
  actor is a compile-time singleton, so "one instance, generic over T" may
  be meaningless. Wants a ruling either way; today the error reads like a
  parser gap. → FRICTIONS #2.
- [ ] **[repro] Storing into a `fnsig` slot is not signature-checked.**
  A `{a: str} -> str` fn sits in a `{x: int} -> bool` slot with no
  complaint. Calling THROUGH a slot checks arity, so the gap is specifically
  the store — which is `bake`'s whole contract. → FRICTIONS #3.
- [ ] **[read] Effect propagation is require-declared, not inferred.** The
  ruling is implicit propagation; the checker still makes you declare it.
  → MISSING-FEATURES D, ROADMAP:26.
- [x] ~~**`[may_block]` has no checker meaning.**~~ STALE — verified
  2026-08-29: it is enforced, by the general budget rule the spec describes
  (§3.7: `[irq_safe]` calling `[io]` is "one instance of the general rule,
  not a special case"). An `[irq_safe]` fn calling a `[may_block]` one is
  rejected, and the obligation propagates to undeclared callers. Now pinned
  in `declarations` — there was no effect-marker coverage at all, which is
  how a misspelling in the message survived.
- [ ] **[read] Typed select sources.** `on select` lowers `read <fd>` and
  `timeout <ms>` only. Dotted forms (`resp.ok`, `timeout.5s`) parse as
  opaque strings. Blocks example 16. → MISSING-FEATURES B/C.
- [ ] **[read] Numeric conversion work (ROADMAP ruling, ordered).**
  (a) enforce no-implicit-conversion at binding sites — `compatible()` in
  `typecheck.nim:263`, with the `strictKind` define already there to measure
  the blast radius; (b) implement `~`/`^` so there is a way to say yes;
  (c) implement `[wrapping]`/`[trapping]` for real, THEN switch the default.
  Only `[saturating]` has codegen today. A default naming `[trapping]` is
  theatre until trapping traps.
- [ ] **[read] Invariants stay on in release (ROADMAP ruling 5).** Done in
  the D backend (`version(tuckNoInvariants)`); the NIM backend still
  hardcodes `when not defined(release)` into emitted code, so its invariants
  cannot be kept in a release build at all.
- [ ] **[design] Variant sets in fn signatures.** Semantics ruled
  (`ProtocolStage<Login|Active>` narrows where a fn may be called); the
  SPELLING is unsettled, since `[T]` and `[...]` are taken.

## 3. Checker bugs

- [ ] **[repro] Field access on a primitive is unchecked.** `s.wibble` on a
  `str` typechecks clean and becomes `<unknown>`.
  `typecheck.nim missingFieldMessage` declines to report when the receiver
  has no declared fields — deliberate for sum types, but it means every
  primitive receiver accepts every name. **Pinned:** `known_bugs`, bugOpen.
  Related: `len` is declared NOWHERE (not std, not any runtime) and resolves
  by luck in whichever backend spells it the same way. Declaring it needs
  the `seq`/`str` ambiguity settled and `Seq[T]` binding against `Seq[int]`
  — both hit and reverted. → MISSING-FEATURES A4.
- [ ] **[repro] A member fn shadows a top-level fn of the same name.**
  `collectSigs` registers members under their bare name in the same flat
  `fnSigs`. Attempted and reverted: members must STAY there, because
  `d.noise` resolves through `asFnByName`. Needs call resolution to
  distinguish them. **Pinned:** `member_names`. → MISSING-FEATURES A1.
- [ ] **[repro] A member call with a payload mis-binds `self`.**
  `d.crank {step: 1}` against `fn crank({step: int})` on an object reports
  "argument to 'crank' expects int but got Deck" — the receiver is being
  matched against the FIRST declared param instead of the `self` lowering
  supplies. Found while testing composition; example 04 declares `play` and
  never calls it, which is why no example catches this. Not pinned yet.
- [ ] **[repro] A prefix call is accepted.** `echo total` (wrong — Tuck is
  postfix) typechecks and emits `total(echo)`. Both names read as
  `<unknown>` under gradual typing. Same trap family as the fnsig
  workaround above. NOT pinned yet.
- [ ] **[repro] By-type payload matching does not run for MEMBER calls.**
  `{n: 7, text: "x"} b.grow` against `grow({self, count: int, label: str})`
  checks OK and then drops the payload entirely. `payloadFields` reports
  `shapeKnown=false` for a member call, so the claim passes never run. The
  same payload against a top-level fn works. → audit F6.
- [ ] **[repro] `declForType` is never recorded for inferred types.**
  `resolveTypeNames` walks only types the user WROTE, so a type the checker
  synthesized for an expression has no declaration edge and every consumer
  re-derives it by name — a decl-list scan per node, which is why emit is
  quadratic. A partial fix landed (`resolveInferredTypes`); it does not
  reach these nodes, which arrive with `id=unset`. → audit F1.
- [ ] **[repro] `callParamsFor` unrecorded for three categories** — pending
  fns, distinct-type ctors, combinators. Every backend therefore keeps a
  decl-scan fallback (~150 lines across three). Members were fixed
  2026-08-27; these three remain. → audit F2.

## 4. Compiler-internal issues (not user-visible)

- [ ] **[repro] Emit is quadratic in every backend.** D's share of a compile
  went 0.03s / 0.11s / 0.38s at 200 / 500 / 1000 types — doubling n
  roughly quadruples it. Nim has the same curve with a smaller constant.
  Cause is the decl-list scans above, not the emitters. → audit, SCORES.md.
- [ ] **[read] `decl_index.nim` may be the wrong fix.** It makes emit-time
  re-derivation cheap instead of removing it; measured gain was 0.84s →
  0.80s. If F1/F2 land and the scans disappear, DELETE it rather than keep a
  cache for work that no longer happens. → audit F4.
- [ ] **[read] Marker plumbing is partly duplicated.** Two name→marker maps
  remain (`parser.nim:123`, `parser_type.nim:199`). The two marker→name maps
  were collapsed into `ast.effectName` on 2026-08-29 — they had DRIFTED, both
  deriving the name from the enum and dropping the underscore, so
  `[may_block]` printed as `[mayblock]`. → MISSING-FEATURES D.
- [ ] **[read] One C implementation of the runtime.** Nim, Odin and D
  runtimes are mirrored BY HAND and have drifted repeatedly. Collapsing the
  offload seam into one C file bound over the existing FFI removes the
  class of bug. The coroutine engine already works this way (all three
  drive the same vendored minicoro), which is the precedent.
- [ ] **[read] Stage boundaries leak.** 90 emit-time queries across the
  three backends re-derive facts an earlier stage should have recorded.
  Rule: a question asked at emit means an earlier stage did not finish.
  → the whole audit document.

## 5. Backend bugs

### Nim
- [ ] **[repro] Invariants cannot be kept in a release build.** See §2.
- [ ] **[repro] An actor handler containing a registry raise emits nothing
  usable** — no proc for the handler at all (example 20). Same source fails
  in D differently, so the cause is upstream of both.

### Odin
- [ ] **[repro] `.toStr` on an int does not compile** — "'n1' of type 'int'
  has no field 'toStr'". → iface-playground FINDINGS.
- [ ] **[repro] A list literal cannot reach a `Seq` parameter.**
  `[dynamic]T` has no literal form. Needs statement hoisting in the emitter.
  **Pinned:** `interface_seq`. → MISSING-FEATURES A2.
- [x] **FIXED 2026-08-30** — `on select` in a task body was a stub; a task
  WITH ARGUMENTS ran on the main context instead of a coroutine. Both fixed;
  29/30 now run correctly under Odin. See commit "Odin task select,
  task-with-args, and a silent test-harness bug".

### D
- [x] **FIXED 2026-08-30** — a statement-position match with plain
  (non-return) arms was routed through the VALUE dispatch, wrapping only
  each arm's first statement in `return` and stranding the rest outside
  the switch. genDStmt now dispatches exkMatch to genDMatchStmt directly,
  matching Odin's own genStmt shape, instead of asking genDExpr's
  matchArmsReturn (a different question — "does an expression-position
  match's arm already return" — answered wrong when the match is a
  statement to begin with).
- [x] **FIXED 2026-08-30** — `sizeof`/`alignof` now emit D's postfix
  property (`T.sizeof`) instead of the call syntax dmd rejects. Odin's own
  `sizeof(x)` emission is STILL wrong (real Odin spelling is `size_of(T)`)
  — unfixed there since no example has reached that line yet (see below).
- [ ] **[read] Records containing a `Seq` field shallow-copy the slice.**
  Assignment `.dup`s a bare Seq, but a record holding one is copied
  field-wise and the slice inside is shared. Needs a probe and a per-field
  dup (or a postblit).
- [ ] **[read] Registers are not `volatile`.** D has no volatile qualifier;
  `core.volatile`'s load/store are the supported spelling. Correct for the
  examples, wrong for a real embedded target.
- [ ] **3 of 44 examples do not compile** (was 13, 2026-08-29):
  `on select`'s TASK form which needs the reactor (29, 30), and 16 — which
  fails the CHECKER, not codegen (§6). FIXED since: the messageless actor
  (15), the inline sum type (08), fnsig-as-value (03), composition and
  mixins (04), and a value-returning body the checker left open, which D
  and Odin reject where Nim does not. → ledger.
- [ ] **[repro] Example 20 is unverified on every backend past emit.**
  Chasing its D build (match-statement fix, then sizeof) surfaced two
  more blockers, both cross-backend and neither D-specific:
  - `register DAC_CR at 0x...` field access (`DAC_CR.EN = true`) reaches
    codegen as a raw `uint*`/`^u32` with no field — confirmed the SAME
    error on a real Odin build of the same emitted source, so this is a
    lowering/typecheck gap in register-field modeling, not a backend bug.
  - A bare `discard` (no value to drop) is not a real construct in ANY
    backend's grammar (`grep` for it turns up nothing in parser*.nim) —
    it reaches codegen as a plain identifier and prints verbatim, which
    happens to be valid Nim (coincidence, same shape as the sizeof bug),
    unverified as valid Odin or D. Never caught because example 20 has
    never been in any backend's compile- or run-checked list.

### Cross-backend
- [ ] **[repro] The Nim backend is stricter than D on numeric mixing.**
  `acc + payload.value` with `acc: int` and the field `u16` compiles in D
  and fails in Nim. Same source, two answers about which programs exist.
  The numeric-conversion ruling closes this; until then it is a portability
  hole. → ledger.

## 6. Diagnostics — right refusal, wrong message

A cluster with one shape: the compiler is correct to refuse, but the message
describes the parser's or backend's problem rather than the author's.
FRICTIONS calls #7 the house standard — it names the type, the rule, the
position, and a way forward.

- [ ] **16-actor-tasks-unified-syntax** — fails the CHECKER, not codegen:
  `.fn {args}` on an undeclared method (the example needs a `pending:`
  stub), plus dotted select sources. → MISSING-FEATURES B.
- [ ] **20-embedded-mp3-player** — see the Nim and D entries above.

## 8. Object member receivers alias — undecided, needs a ruling

Found 2026-08-29 while probing the stateful-value question. NOT fixed: the
resolution is a language decision, not a codegen one, and it was left open.

**The facts, all reproduced by building and running:**

- Chains are CORRECT and uniform. `c ..bump` emits `c = bump(c)` in every
  backend — return-value assignment, no aliasing. `checkMutatorCall`
  (`typecheck.nim:1188`) enforces the contract: a `..` mutator must return the
  receiver's type. Records prove the whole path: `let b = a ..withPort {p:8080}`
  leaves `a` at 1 and gives `b` 8080.
- The DIRECT call has no such contract. `{self: c} bump` emits `bump(c)` with
  `self: var Counter` (`codegen.nim:1315`, unconditional — no body analysis
  exists anywhere in the compiler). The member mutates the CALLER's object.
  `let r = c.bump` gives `r.n=1` AND `c.n=1`; value semantics says `c.n=0`.
- A READ-ONLY member cannot be called on a parameter. `p.sum` where `sum`
  mutates nothing fails in Nim with `expression 'p' is immutable, not 'var'`.
  Legal Tuck, rejected in the backend's words. Works on a local, because Nim's
  `var T` binds any addressable location — which is why every existing test
  misses it (they all use locals).
- **The three backends disagree.** Nim: `var self`, aliases. D: `ref self`,
  aliases, and `tests/suites/d_backend.nim:185` RUNS a program asserting the
  receiver mutates across two direct calls (expects 9). Odin: declares `^T`
  but its call sites never pass an address — its own comment says
  `# ponytail: call sites don't take the address yet`.
- `value_semantics.nim:383` is the only Nim-side coverage and is `okCheck` —
  typechecks a member that mutates `self`, never calls it. That is how this
  survived.

**The ruling needed:** are function arguments copied, `self` included?
- If YES (`self` is an argument like any other): `var self` dies in all three
  backends, the read-only-on-param defect and Odin's unwired call sites both
  fall out for free, `d_backend.nim:185` is asserting the wrong thing and gets
  rewritten to the chain form, and a member that writes `self` but does not
  return the object type becomes a silent no-op — example 04's
  `fn play({episode: Episode}) -> void` is exactly that shape, and probably
  wants rejecting the way `checkMutatorCall` already rejects it for chains.
- If NO (object members are the language's one aliasing construct): it needs
  saying in the spec, `let c` is genuinely unsafe through a member call, and
  the read-only-on-param defect needs the body analysis that does not exist
  in order to emit a plain `self` for non-mutating members.

Related and separate: `{self: Self}` declares but cannot be CALLED —
`argument to 'louder' expects Self but got Player`. `Self` is substituted in
five places (`typecheck.nim:529/532`, both backends, conformance) but not on
the call path. `value_semantics.nim:391` uses this exact shape and only
`okCheck`s it.
