# Handoff — Tuck compiler, 2026-08-14

**Repo:** `/home/kl/prog/tuck_lexer`
**Branch:** `claude/spec-code-audit-34xh4q`, 20 commits ahead of the session start
**State:** clean tree, full suite green (`TUCK_REQUIRE_ODIN=1 ./run-all-tests.sh`)

Two pieces of work: a feature (`<uninit>` field tracking) and a complexity
pass that turned into a bug hunt.

## What shipped

### The `<uninit>` feature — complete

A field a construction did not supply is a compile-time hole. Three rules:
never read it and the program compiles; read it unset and that is the error;
assign it and the marker is gone. No runtime representation — emitted code is
unchanged, verified by grepping for `uninit` in the output.

The marker is a TYPE (`<uninit>[T]` on the field, inside the variable's
synthesized record type), not a side table. That is what makes nesting safe:
`{inner: i} Outer` then `o.inner.b` is caught, because a type rides with the
value and `synthStruct` types a literal from its fields' synthesized types.

Cross-function works too: the call site scans the callee's body and refuses
only when the callee actually READS the hole (`f {c}` passes if it does not).
Mutators fill exactly the fields their body provably assigns.

17 assertions in `tests/suites/uninit.nim`. Spec re-ruled in `ROADMAP.md`
(the 2026-07-09 "every field at construction" ruling is amended in place, not
deleted); `TK-TY16` added with its `explain` body.

### Complexity pass

| | Start | End |
|---|---|---|
| debt | 1487 | **1280** |
| heavy (cc>=15) | 45 | **32** |
| worst proc | 42 | 29 |

Eleven procs split, all behaviour-preserving with `examples/` byte-identical.
The big ones: `scanNext` 38 -> 8/7, `lowerExpr` 42 -> 12/10/6, `builderSteps`
39 -> 14/11/10, `checkRegistry` 34 -> four named rules.

`tools/cc` also changed: an `of` arm with no decision of its own no longer
counts. A 21-kind AST dispatch was outscoring genuinely knotty code. The
exemption is measured — an arm that loops or tests still counts in full —
and it moved the honest debt 1964 -> 1476 with no code change.

### The `ast.children` sweep

New iterator in `ast.nim`, exhaustive by construction. Every hand-rolled Expr
walk now uses it: `clearIds`, `lowerExpr`, `rewriteExpr`, `synthesizeExpr`,
`mentionsName`, `raisedEventsIn`, `scanReturns`, `rewriteChains`.

**Four of those had silent gaps.** That is the sweep's real payoff.

## Bugs found

`KNOWN-BUGS-EVENTS.md` has the full write-ups. Summary:

- **EV-1 (open, high).** A raise inside a TASK body emits garbage —
  `Boom(tuck_AppEvents.raise)(1)`, which Nim rejects with "invalid
  indentation". `lowerModule` walks `allFns`, which yields `dkFn` only, so
  `lowerExpr` never reaches `taskBody`. `rewrite.nim:153` documents this exact
  gap in a parenthesis and works around it for itself.
- **EV-2 (open, medium).** Same root cause on the checking side: a typo'd
  event in a task passes `tuck ch` clean.
- **EV-3 (pattern).** Three roles have a feature-full implementation and a
  simplistic one, and the simplistic copy holds the hole while the other masks
  it. EV-1 survived for exactly this reason.
- **EV-4 (FIXED).** An `[io]` call inside a `send` payload escaped the effect
  audit entirely — and `markAsync` never fired, so codegen would skip the
  async transform. Verified against a pre-refactor binary.

Also fixed: `failIfPointerReturn` did not descend into `tkFunc` while its
sibling did — a returned callback passing memory went unchecked.

Two earlier bugs, both from analyses keyed by bare variable name:
narrowing inherited across a shadowed binding (accepted invalid code,
`711b77b`) and variant state leaking out of scope (rejected valid code,
`f02f8f6`).

## Other changes worth knowing

- **Optimizer is ON by default** (`78a4cc3`). `-O:none` turns it off, which is
  the first thing to try when emitted code looks wrong. Visible effect: one
  line in `examples/02-builder-mutation`, both backends.
- **`tests/run` is a script now**, not a checked-in binary. It rebuilds only
  when a test source changed. Running the old binary directly tested the
  PREVIOUS version of the suite, which cost a wrong commit.
- **`COMPILER-README.md`** — a developer guide to the pipeline, the checker's
  section map, the four implicit proc-family contracts, per-variable state,
  the test architecture and the gates.

## Where to pick up

Ordered by what I would do next:

1. **Fix EV-1 and EV-2.** One-line widening in two places
   (`for d in m.decls(dkTask): lowerExpr(d.taskBody, m)` and the same for the
   registry pass), or one fix to `allFns` itself. Both are behaviour changes,
   which is why this pass left them.
2. **Continue the complexity pass** if wanted. Remaining above 19:
   `toString` 29 (parser_stringify — honest rendering dispatch, 25 arms, no
   `else`; I would leave it), `resolveDeclTypeRefs` 25, `mangleModuleWith` 22,
   `genReturn` 22, `genOdinDecl` 20, `assignIds` 20.
3. **`assignIds`** is the last hand-rolled traversal that could not take
   `children` — it threads a `var` counter, so a read-only iterator cannot
   carry it. Worth a second look.

## Working agreements observed this session

- No `sed`/`awk`/python in-place rewrites; use Read/Edit/Write. I broke this
  twice and had to verify by reading afterwards.
- Literal full paths in Bash, no shell variables.
- Commit after each verified success, not batched.
- Run `./run-all-tests.sh`, not `./tests/run`, before committing — the wrapper
  is what regenerates and re-blesses.
- Control tests before claiming a bug: three times this session a suspected
  bug reproduced identically WITHOUT the suspected cause, which meant the
  cause was wrong. `varErrTypes` shadowing and the `main` effect exemption
  were both cleared that way.
