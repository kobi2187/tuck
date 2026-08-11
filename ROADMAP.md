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
