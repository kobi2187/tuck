# Documentation-pass audit — 2026-09-27

Found while adding a doc comment to every routine and type in the tree
(branch `claude/actor-throughput-profiling-sbfhq8`, commits `ed99d10`,
`5818dc3`, `6072b89`). Writing a doc means reading the body, and reading every
body once turns up what nobody reads twice. Every claim below is cited to
`file:line` in the tree AFTER that pass, or to a probe that was actually run;
the two bugs ranked first were reproduced end to end.

Baseline when written: `tests/run` is **green** — 1764 PASS, 0 FAIL, 0 SKIP,
6 OPEN (the `known_bugs` pins), with the Odin and D toolchains present. The doc
pass itself changed no emitted output: `tools/emit_examples.sh` re-emits
`examples/` with zero diff.

Ranked by consequence: wrong answers first, then work that was started and not
finished, then code that could be much simpler, then coupling, then cleanup.

---

## Part 1 — Wrong answers (reproduced)

### F1 — A decision table can return the wrong row

`groupByOutcome` (`compiler/lowering_decisions.nim:131`) resolves every
combination to its first matching row, then groups combinations whose answers
are the same so they share one `match` arm. "The same" is decided by comparing
`rows[hit].body.toString()`. That printer (`compiler/parser_stringify.nim:81`)
is lossy on purpose — it is for messages and dumps — and prints control flow
as its keyword alone: every `match` is `"match"`, every `if` is `"if"`, every
block is `"block"`. Two rows whose bodies are DIFFERENT `match` expressions
therefore compare equal, collapse into one group, and the whole table answers
with one row's body.

```tuck
decision pick({a: bool, b: bool}) -> int:
  | true  _ -> match 1:
    1: 10
    _: 20
  | false _ -> match 2:
    2: 30
    _: 40

fn main() -> int:
  return {a: true, b: true} pick
```

Built with `tuck b` on Nim, this exits **30**; the right answer is **10**. The
emitted body is a single `return (case 2 ...)` — the table was lowered to one
outcome. Literal and name rows are unaffected (names are mangled before this
pass, so `"hello"` and a const `hello` do not collide), which is why the
corpus never hit it.

Fix: compare row bodies structurally (a `jsony` dump of the node, or an
explicit structural `==`), or group only rows whose bodies are literals and
names and give every other row its own arm. Pin it in `known_bugs` first.

### F2 — The effect checker skips `on select` arms and object members

`verifyDecl` (`compiler/semantics.nim:179`) checks `dkFn`, `dkTask`, the
handlers of `dkActor` and `dkStaticAssert`, then ends in `else: discard`
(`:222`) — the exact shape CLAUDE.md records as having hidden `on select`
arms from `checkDecl` and `mangleMember`. An `[io]` call is rejected in an
`on add(...)` handler and accepted, unchanged, in the equivalent select arm:

```tuck
fn touch({n: int}) -> int [io]:
  return n

actor A [queue: 4]:
  total: int = 0
  on select:
    | add -> {n: int}:  total = {n} touch
```

`tuck ch` says `OK`. Swap the arm for `on add({n: int}):` and it reports
`Expression requires effect [io]`. The same hole lets an object member call an
`[io]` fn with no `[io]` of its own:

```tuck
fn touch({n: int}) -> int [io]:
  return n

object Box:
  v: int
  fn poke(self) -> int:
    return {n: 1} touch
```

also checks `OK`. By reading, the same `else` also skips record `typeMembers`,
mixin members and `when` blocks (not probed). `collectLocal` (same file) ends
in `else: discard` too, so those members' own declared effects are never
recorded for their callers either.

Related: the diagnostic for this error exists — `dcEfBudget = "TK-EF01"`
(`compiler/diagnostics.nim:132`) — and is never used; the message is raised
uncoded at `compiler/semantics.nim:171`.

Fix: name every DeclKind in `verifyDecl` and `collectLocal` (the `checkDecl`
treatment), then walk declarations with `ast_ops.allDecls`/`bodies` rather
than by hand.

### F3 — A stray `?` or composition `+` is silently dropped on Nim and Odin

`genUnary` in `compiler/codegen.nim:646` and `compiler/codegen_odin.nim:908`
ends in `else: ""`, so `uoPropagate` and `uoComposition` print their operand
with no operator. D refuses both (`compiler/codegen_d.nim:504`,
`dUnsupported`). Latent — the rewrite pass desugars every `?` it can, and D's
own comment says the case "reaches codegen only if the rewrite pass did not
desugar it" — but when it does, Nim and Odin emit a program that silently
loses its error propagation. Refuse, as D does.

---

## Part 2 — Half-finished

### F4 — Arenas exist in three layers and work in none

- The parser reads an `arena` block's members and throws them away
  (`compiler/parser.nim:87`, `parseArenaDecl`); the declaration becomes an
  empty record type.
- The checker says "Arena/alloc semantics stay unimplemented (ROADMAP §7.3)"
  (`compiler/typecheck.nim:4228`).
- The Nim runtime has `BumpArena`, `alloc` and `reset`
  (`compiler/tuck_rt.nim:279`), and no backend ever emits a reference to them.

So an arena program checks clean and does nothing (probed: `tuck ch` OK). The
ROADMAP's "Deferred" list already asks for a diagnostic ("fifteen minutes, so
it stops checking clean"); this confirms it is still wanted.

### F5 — The `missing type` sentinel was retired, but not everywhere

`compiler/ast.nim:612` says a missing type "is reported before it can be
stamped onto the typed AST" — the named sentinel is gone. What still describes
or tests for it:

- `hasMissingType` (`compiler/ast_query.nim:464`) now means "contains a nil",
  while its doc still calls it the checker's "I could not work it out" marker.
- `pipeline.carriesMissingType` / `assertNoMissingTypes`
  (`compiler/pipeline.nim:101`, `:121`) test `t != nil and hasMissingType(t)`
  — true only for a recorded type with a nil hole, which the checker does not
  produce. The stage check is effectively dead.
- `branchOutcomeType`'s doc (`compiler/typecheck_util.nim:31`) reads "unlike
  `the old missing-type sentinel`" — a find-and-replace leftover.

Either delete the stage check and rename `hasMissingType` to what it is now, or
give it something real to catch.

### F6 — The move-analysis differential compares the mirror with itself

`moveDiffReport` (`compiler/analysis_provenance.nim:756`, `TUCK_DEBUG_MOVE=diff`)
was the Stage B differential against the three-walk implementation. That
implementation is gone. `oldStampsIn` (`:745`) now reads `res.movedArgs`, whose
only writer is `markMovableArgs` (`:728`) calling `movableArgsSsa` (`:707`) — so
the report compares `movableArgsSsa` with its own output and can never
disagree. Delete it, or point it at a real oracle before Stage C needs it.

In the same file, `movableArgsSsa` repeats `moveFactsSsa`'s setup and loop
(`:663`; its answer is `moveFactsSsa(...).sites`) and hand-builds the context
`moveCtx` (`:650`) already builds.

### F7 — Dead fields and enum members that every stage still handles

| What | Produced by | Still handled by |
|---|---|---|
| `MatchArm.guard` (`compiler/ast.nim:287`) | nothing — the parser always writes `guard: nil` (`compiler/parser_expr.nim:792`, and the decision parser) | complexity, analysis_liveness, codegen_d, lowering_match_binds, ast_ops; `ssa_build` asserts it is nil (`compiler/ssa_build.nim:483`) |
| `BinOp.boXor` (`compiler/ast.nim:326`) | nothing — there is no `xor` keyword or token | the checker (`compiler/typecheck.nim:1217`, `:1301`), the stringifier and all three backends |
| `ChainOp.coDot` (`compiler/ast.nim:340`) | nothing — every `ChainStep` is `coDotDot` | `step.op != coDotDot` tests in `optimize` and `typecheck`, always false |
| `ssa_ir.Value.freedAt` / `freedBy` (`compiler/ssa_ir.nim:135`) | nothing — only initialised to `fkNotFreed` | the enum `ssa_ir.FreeKind` (`:97`) duplicates `analysis_ownership.FreeKind` (`compiler/analysis_ownership.nim:134`) member for member. M3.2 chose buffers over per-value `freedAt`; the field stayed |
| `tuck_rt.AccessMode` (`compiler/tuck_rt.nim:8`) | nothing | nothing |

Each one is a branch every new stage has to write and no program can reach.

### F8 — The SSA mirror's status is described three ways

`tests/suites/ssa.nim:3` says "THE MIRROR IS PROOF-ONLY TODAY. Nothing consults
it". `compiler/pipeline.nim:172` says "Nothing CONSULTS the mirror yet" and,
nearby, that `analysis_liveness` "no longer stamps anything — the mirror does".
ROADMAP's "Where it stands" says "NOTHING CONSULTS IT YET" while M1.3 says the
consumers were switched onto `ssa_build`. And `markMovableArgs` stamps moved
arguments straight from `movableArgsSsa`. At least two of these are stale; a
reader planning from any one of them plans wrong.

### F9 — Smaller unfinished edges

- **Task `on select` on Nim** lowers only `read` and `timeout` arms
  (`compiler/codegen.nim:1105`, "first cut"); the checker refuses the rest. Fenced
  honestly, and it is ROADMAP S2.6 / #15.
- **Odin member calls**: `genOdinMemberFn`'s doc still carries "ponytail: call
  sites don't take the address yet".
- **Uncoded diagnostics**: about 137 `fail("...")` sites carry no `TK-` code
  against about 68 `fail(dc, ...)` — "Transition Error", "Conformance Error",
  "Effect Error" (`checkFallibleNeedsIo`) among them. `tuck explain` cannot
  answer for any of them.
- **`benches/cg_emit.nim` no longer compiles**: `lowerModule` changed signature
  (`:44`). Not caused by the doc pass — the file fails the same way at `c3a4c23`.
- **Nim `genFnDecl`** (`compiler/codegen_decl.nim:105`) resets two of the five
  return-context fields after a body; D and Odin have `leaveReturnContext` for
  all of them. Harmless today because every fn sets them on entry.
- **`codegen_odin_ctx.odinType`** ends in `else: "rawptr"` (`:278`), against the
  "no `else` over an enum" rule; Nim's `genType` names `tkUnion`, `tkRename`,
  `tkEffect` explicitly.

---

## Part 3 — Could be much simpler

- **`complexity.walk`** (`compiler/complexity.nim:155`) lists every ExprKind to
  recurse by hand. Only the forking kinds need arms; the rest is
  `for c in e.children`, and `ast_ops.children` is already exhaustive.
- **D decides `break;` from the emitted TEXT** (`compiler/codegen_d.nim:1155`):
  `endsWith("return;")` and "last line starts with return". The AST already
  says whether an arm ends in `return`/`raise`.
- **`parseBinaryExpr` rebuilds its precedence Table on every call**
  (`compiler/parser_expr.nim:625`) — one table allocation per binary
  expression parsed. It is a `const`.
- **Three type-substitution walkers**: `typecheck_util.substituteType`
  (`:169`, ends `else: t`, so tuples, sums, unions and renames are not
  substituted), `generic_actors.substType` (`:57`, exhaustive) and
  `ast_query.substParams` (`:850`). One exhaustive walker would do.
- **Four signature printers**: `typecheck.sigStr` (`:4865`), `typecheck.sigLine`
  (`:4894`), `typecheck_conformance.sigText` (`:63`), and the pending report's
  format.
- **Two attribute-bracket parsers**: `parseDeclAttrs`
  (`compiler/parser_decl_kinds.nim:65`) and `parseTypeUseAttrs`
  (`compiler/parser_type.nim:15`) differ only in `error: A | B` and the
  `invariant` refusal.
- **Two module-loading walks**: `loadProgram` and `loadProgramIndexed`
  (`compiler/modules.nim:394`, `:420`) each carry a near-identical DFS; one walk
  with a "may this import come from the index?" predicate covers both.
- **String↔enum tables written twice**: `effectMarkerFromName` (parser) and
  `effectName` (ast_ops); `resourceOnFullFromName`/`resourceOnFinishFromName`
  and the three backends' `*OnFullName`. Enums with string values plus
  `parseEnum` give the source spelling in one place.
- **Dead backend**: `SelectedBackend* = cbMinicoro` is a `const`
  (`compiler/tuck_coro.nim:201`), so the 10 `when SelectedBackend == cbLibaco`
  branches are dead code for a library that is not vendored.
- **Duplicated helpers**: `getLineContext` (`lexer.nim:187` and
  `compiler/parser_base.nim:46`), `seqFieldsOfType`
  (`compiler/analysis_provenance.nim:508`) = `twin_shape.seqFieldNames` (`:31`),
  `isStr` (analysis_ownership, lowering_strtemps), `elapsedMs` (`tuck.nim:288`,
  while it imports `compiler/verbose.nim:27`'s), `isValueIfD`
  (`compiler/codegen_d.nim:1040`) — a pure alias of `isValueIf` — and `lexAll`
  in five places under `benches/` and `fuzz/` when `modules.lexSource` is it.
- **Two "is this a value tail" predicates** that disagree:
  `ast_query.injectTailReturn` (`:398`) and `typecheck_flow.checkImplicitTailReturn`
  (`:280`) exclude different ExprKinds.

---

## Part 4 — Coupling that could be undone

- **Per-compile decisions in module globals.** `analysis_ownership.decided`,
  `lowering_seqcopy`'s four site tables, `twin_calls`' three, the provenance
  `summaries`, `backend_prepare.preparedOnce`, the name counters in
  `lowering_chains`, `lowering_match_binds` and `lowering_strtemps`, and
  `ast_ops.globalNodeCounter`. The `Resolution` side-table exists for exactly
  this; in globals, pass order is load-bearing and invisible.
- **`resetResolution`** (`compiler/resolution.nim:371`) hand-copies SEVEN
  program-wide name tables across each reset (its doc says five). One
  `ProgramNames` object on `Resolution` would make the carry one field and the
  list impossible to drift.
- **The driver writes target code.** `tuck.nim`'s `when isMainModule`
  (`:605`) is about 750 lines: the whole CLI and every backend's build steps,
  including the Nim entry-point wrapper as source text (`tuckAsyncInit`,
  `registerActor*`, `tuckRun`, the exit-status wrapper at `:1183`). Split per
  command; move entry-point emission into each backend's emit module.
- **Every driver query written twice**, once for modules loaded from source and
  once for modules served from the cached index (`addLoadedEffects` /
  `addSigOnlyEffects`, `addLoadedPending` / `addSigOnlyPending`, ...). A single
  signature view over both would halve it.
- **`typecheckModule` takes seven `extern*` tables** (`compiler/typecheck.nim:4967`);
  an imported-view object is one parameter and one place to add the eighth. The
  `TypeChecker(...)` literal for signature collection is repeated three times.
- **`parseTypeHook`** (`compiler/parser_base.nim:191`) is a global mutable proc
  set at init to break the `parser_expr` ↔ `parser_type` import cycle — a hidden
  init-order dependency.

---

## Part 5 — Cleanup

- **Stale comments.** Beef-era wording throughout `compiler/codegen_odin.nim`
  ("plain Beef enums", "inside one Beef type"); orphaned comment blocks at the
  end of `codegen.nim` and `codegen_odin.nim` for code that moved to the
  `_decl`/`_emit` modules; `compiler/parser.nim:61` describes code that moved to
  `parser_type.nim`; `compiler/tuck_async.nim:259` says the actor runtime has
  "no locks, no OS thread" above the thread-mode runtime; `benches/bench_async_scale.nim:16`
  calls the ready queue "a Deque" (it is a ring buffer); `ast.nim` ends with two
  empty section headers.
- **String-typed decisions in the emitters**: `genDLit`
  (`compiler/codegen_d.nim:66`) chooses `L`/`UL` by lexicographic compare and
  treats any integer literal containing `e` as float-like, so `0xfe` gets no
  suffix; `recCtorFromLiteral` (`compiler/codegen_odin.nim:65`) narrows a field
  by the first letter of its Odin type name.
- **Quadratic loops**: `ssa_build.newValue` (`:101`) numbers a version by
  scanning every value; `lexer.nextToken` pops with `delete(0)` (`lexer.nim:674`);
  `codegen_odin_decl.sumNamesIn` (`:414`) is recomputed per payload sum.
- **`tuck_rt.rollRange`** (`compiler/tuck_rt.nim:1466`) reduces one 32-bit draw
  modulo the span — biased, and `high - low + 1` overflows for the full range.
- **Small ones**: `parseDecl`'s `of tkIdent` arm duplicates its `else`
  (`compiler/parser.nim:275`); `parser_base.current`/`peek` build the same EOF
  token twice; `Lexer.linesLen` (`lexer.nim:108`) is never read; the lexer
  reports codes as raw strings, so a typo in one is caught by nothing;
  `typecheck_util.typeName` (`:145`) prints tuples and fn types as `<type>`;
  `typecheck_util.fail` (`:68`) appends the position to the message AND sets it
  on the error; six `genXxx` bodies in `codegen_decl.nim` are indented 4 or 6
  spaces instead of 2, left from being extracted out of a `case` arm.

---

## Where these meet the ROADMAP

- F4 is the Deferred list's "`arena` ... give it a DIAGNOSTIC now".
- F2 widens S4.1 (#64): before new markers are wired, the one that is wired
  must reach every body.
- F8 should be settled before M4.3 — the queue's own status line is one of the
  three disagreeing descriptions.
- F1 and F2 are Part-1 "silent wrong answers", the S1 tier the queue says to do
  early; neither is on it yet.
