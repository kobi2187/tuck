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
proc, tuck CLI (lex/parse/check/compile).

## User rulings (2026-07-09)
- §6.3 complexity limit: ENFORCE as hard compile error (cyclomatic ≤ 5,
  ~10–15 executable lines/fn).
- `Foo {}`: legal only when the type has no fields (empty state is a valid
  type). Types with fields require every field at construction; absence must
  be explicit `?T`. Add to spec §4.8.
- Actors/tasks: API stays actors + tasks; runtime strategy OPEN — evaluate
  nim-cps vs hand-rolled stackless state machines before building §9.2/9.4.
- Effects §3.7: implicit upward propagation (caller of [io] is [io]
  automatically); only boundaries need annotation. Change checker from
  require-declared to infer-and-propagate.

## User rulings (2026-07-09, session 2) — error model + OS layer
- `extern:` blocks (DONE): sigs implemented by tuck_rt; `extern [c, header:
  "uart.h"]:` emits Nim importc — the C/bare-metal seam. Tuck→Nim→C→gcc
  covers embedded; `tuck build` will forward nim flags (--os:standalone etc).
- Stdlib v1 scope: fs, io, sys (os/env), time — extern sigs over Nim stdlib.
- Errors are declared enums (fieldless sums), named in the signature via
  `[error: FsError]` attr (effects bracket). Effects ≠ errors: [io] still
  propagates upward independently.
- The enum never flows bare — always inside the result struct
  {ok, err, value}. Raise site: `return err FsError.NotFound`, shorthand
  `err NotFound` resolved against the sig's declared error type.
- `expr?` propagation operator DROPPED. Handling = local if/ifErr/.ok
  access, or return the whole result up. Policy 4.9 unhandled list tracks
  the rest. (Parked idea, not firm: call-site `get!` as io marker.)
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
| Invariants | 4.7 | auto-insert validate() at construction/mutation/return/deserialization |
| Actors | 9.1 | coroutine/state-machine runtime, static ring queues, scheduler (design open) |
| Tasks | 9.2 | state-machine transform at [io] yield points |
| bake | 3.5 | real specialization; ex 03 emits invalid Nim |
| alias / type-directed lowering | 2.5 | record expansion at call sites; blocks ex 18, 04, 12 |
| pool / arena | 7.2/7.3 | acquire/release bitmask, reset, scope analysis, size verification |
| Interfaces | 5.2/5.3 | satisfies checking, fat-pointer dispatch |
| Type composition `+` | 4.5 | conflict detection unverified |
| match | — | exhaustiveness checking |
| Effects | 3.7 | switch to implicit propagation (ruling above) |
| Beef backend | — | emits, never validated |

## Missing
- Resource registry §7.4 — parser (`resources` decl, `defer` block,
  `[resource:]` attr), checker (kind validation, propagation,
  acquire-must-finish tracking), rt slot table + inline sweep, codegen
  (mark/close per policy), OPEN RESOURCES report
- `on select` §9.3 (blocks ex 16) + scheduler §9.4
- `when TARGET` conditionals §8.3 (blocks ex 11, 20)
- `pred` / `set` fn prefixes §3.6
- Stack-depth budgets `[stack: N]` §6.2
- Complexity limit §6.3 (ruling: hard error)
- Generics substitution
- Error.x validated against a declared error enum
- Top-level statements / implicit main (ex 11)
- Visibility (pub/private), imported types via `::`, nested module paths

## Broken-example map
03 → bake; 18 → alias lowering; 11 → when + implicit main; 16 → on select;
20 → when + embedded attrs depth; 02/04/09/12/17 → only need sketch
decls/pending blocks (example edits, no compiler work).

## Spec debt
§11 describes npeg parser + flat IR + Merkle cache; reality is recursive
descent + ref-AST + hash-keyed msgpack cache + signature index. Rewrite §11
to match implementation (as was done for §4.8).
