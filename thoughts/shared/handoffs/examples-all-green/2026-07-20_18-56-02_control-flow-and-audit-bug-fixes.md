---
date: 2026-07-20T18:56:02+03:00
session_name: examples-all-green
researcher: Kobi
git_commit: 2632da04c2eb3a61f92a9aa9e36fb220b8453dd7
branch: main
repository: tuck_lexer
topic: "Control flow loops (spec 2.6/3.6b) + expressibility-audit bug fixes"
tags: [implementation, strategy, codegen, codegen-beef, typecheck, parser, lexer, spec, audit]
status: complete
last_updated: 2026-07-20
last_updated_by: Kobi
type: implementation_strategy
root_span_id:
turn_span_id:
---

# Handoff: control-flow loops landed; audit exposed core-language gaps, 3 of them fixed

## Task(s)

1. **Control flow loops — COMPLETE** (design → spec → plan → 7-task implementation,
   commits 20360e3..d2ddc7a). Odin-inspired unified `for`. Full matrix green.
2. **Expressibility audit — COMPLETE** (sonnet subagent, 2 rounds, ~53 probes).
   Reality check: language is further from done than assumed. 25+ discrepancies.
   Agent hit its session limit after round 2; all probes remain in the scratchpad
   at `/tmp/claude-1000/-home-kl-prog-tuck-lexer/fa69d027-a98c-4113-862f-8998586be185/scratchpad/audit/`.
3. **Audit bug-fixing — IN PROGRESS.** User ruling: focus on BASIC language gaps,
   not unique features. Three fixed and committed (b0eb80a, 77d88b0, 2632da0).
   Fourth (`toStr` + `+`) was mid-investigation when the session ended.

## Critical References
- `docs/superpowers/specs/2026-07-18-control-flow-loops-design.md` — the loops design + rulings
- `docs/superpowers/plans/2026-07-19-control-flow-loops.md` — 7-task plan (all done)
- `tuck-spec.md` §2.6 (loops), §3.6b (`fn inline`), §7.1 (value types — the b0eb80a fix)

## Recent changes

**Control flow (spec 2.6/3.6b)** — `loop:` infinite, `for cond:` while-style,
`for i in 0 .. 10:` / `0 ..< 10:` (Nim convention, spaced `..` distinguishes from
the tight `..field` mutator), `for idx, item in xs:`, `break`/`continue`
(innermost only, no labels ever), `fn inline`. Sites: `lexer.nim` (tkLoop/tkBreak/
tkContinue/tkRange/tkRangeLt + space-sensitive `..` lexing ~line 256);
`compiler/ast.nim` (exkWhile/exkBreak/exkContinue, boRangeIncl/boRangeExcl,
dkFn.isInline); `compiler/parser.nim:786` region (for-form lookahead), `:1230`
(`fn inline` keyword slot); `compiler/typecheck.nim` (loopDepth, exkWhile arm,
range typing in synthBinary); both codegens.

**Audit fixes:**
- `compiler/codegen.nim:1142,1350` + `codegen_beef.nim:1204,1458` — records and
  manager objects emit `object`/`struct`, not `ref object`/`class`.
- `compiler/codegen.nim:1020` — record-typed fn params emit `var T`;
  `codegen_beef.nim:1052` — same params emit `ref T`, and
  `codegen_beef.nim:474` region adds the matching `ref` at bare-var call sites.
- `compiler/codegen_beef.nim:437` — record construction dropped `new` (in Beef
  `new` heap-allocates and yields `Type*`).
- `compiler/ast.nim` exkVar branch gained `varCallNode`; `typecheck.nim:954`
  region stamps it for zero-param fns; both codegens' exkVar arms emit it.
- `compiler/codegen.nim` + `codegen_beef.nim` `injectTailReturn` — a tail
  `exkMatch` with a non-nil subject is now wrapped in a return.
- `tests/cli_smoke.sh` — four new runtime cases: control flow (exit 17),
  value semantics (17), nullary call (12), match-as-return (9).

## Learnings

- **`block:` captures unlabeled `break` in Nim.** Every Tuck block was emitted as
  `block:`, so `break` exited the block, not the loop — loops never terminated.
  Now emitted as `if true:` (identical scoping, not a break target).
- **`ref object` was hiding a whole class of mutation bugs.** Under `ref`, a fn
  could mutate a struct param regardless of `var`, so nothing ever needed `var`
  params. Switching to value types surfaced that the checker binds *every* param
  `isVar: true` (typecheck.nim:1201) — codegen just wasn't honoring it.
- **Beef `new` on a struct yields `Type*`.** Struct literals use
  `TypeName() { field = val }` with no `new`. `.()` is the implicit-type form and
  is NOT valid where the type must be named.
- **Both backends run `injectTailReturn` on the SHARED AST** — every mutation must
  be idempotent (wrapping `stmts[^1]` in exkReturn is, since the second pass sees
  exkReturn and skips).
- **Nim variant objects reject a repeated field name across branches** — hence
  `varCallNode` on exkVar rather than reusing `callNode`.
- `nim c -o:` a test binary INSIDE the repo tree (e.g. `tests/_cae`) or module
  resolution fails to find `std/*.tuck`.
- `msgpack` raises `Defect` (ObjectConversionDefect), not CatchableError, on AST
  layout changes — the cache stamp check never ran. Fixed in `modules.nim`.
- `continue` became a keyword and collided with `errors [policy: continue]`.
- `./tuck parse <file> --ast` emits JSON followed by a trailing status line —
  strip the last line before parsing it as JSON.

## Post-Mortem

### What Worked
- **Probe-driven verification over suite-green.** Every one of these bugs passed
  the existing gates. The control-flow probe caught the `block:`/`break` bug the
  moment it ran, and the audit found 25 more the suites never touched.
- **Delegating the audit to a subagent** — cheap, broad, and it returned exact
  compiler errors rather than impressions.
- **Root-cause discipline (systematic-debugging skill)** on the value-type fix:
  tracing where `ref` was load-bearing BEFORE editing revealed that `self` params
  and the `..` chain emitter were already value-semantics-ready, so the change was
  much smaller than feared.
- **Exit codes as the assertion mechanism** for runtime verification.

### What Failed
- Assumed `..`-mutator ambiguity would block reusing `..` for ranges → user's
  space-sensitivity ruling solved it with no new token.
- Tried `[inline]` as an effect marker, then a `%` sigil → user rejected both;
  `fn inline` keyword slot is the answer (effect markers propagate, codegen hints
  do not — different categories).
- Beef struct init: tried `.()` first → "Expected identifier"; correct form is
  `TypeName() { ... }`.
- Wrote a probe with `type Light: Red | Yellow | Green` → parse error; sum
  variants need the `| Variant` block form.
- Ran the full matrix before committing each fix → user corrected: commit after
  every success, don't batch.

### Key Decisions
- **No labels, ever** (loops). Multi-level exit = extract a fn; `fn inline` makes
  that free. Alternatives: labeled break (rejected as goto-shaped), break-with-value
  (deferred).
- **No C-style 3-clause `for`** — avoids `;` as a token used nowhere else.
- **Ranges are spaced `..`** — `0 .. 10` inclusive, `0 ..< 10` exclusive (Nim
  convention, since Tuck lowers to Nim); tight `..field` stays the mutator.
- **Records are value types, no ref escape hatch.** User asked whether fields could
  be refs for perf; rejected because per-field ref makes `==` and copy semantics
  field-dependent — the exact ambiguity the model exists to remove. If a perf case
  ever appears, the answer is a visible type-level opt-in (like `[packed]`), not a
  silent per-field one. Sum types, actors, tasks and event carriers KEEP reference
  semantics — identity is part of their model.
- **Bare name = call; `:name` = the only fn-ref form** (user ruling). Restricted to
  zero-param fns: a fn with params referenced bare is still payload-explosion.

## Artifacts
- `docs/superpowers/specs/2026-07-18-control-flow-loops-design.md` (new)
- `docs/superpowers/plans/2026-07-19-control-flow-loops.md` (new)
- `tuck-spec.md` §2.6 + §3.6b (new sections)
- `ROADMAP.md` (control-flow row), `progress.md` (2026-07-19 entry)
- `thoughts/ledgers/CONTINUITY_CLAUDE-examples-all-green.md` (loops marked done)
- `tests/cli_smoke.sh` (4 new runtime cases)
- Audit probes: `/tmp/claude-1000/-home-kl-prog-tuck-lexer/fa69d027-a98c-4113-862f-8998586be185/scratchpad/audit/` (~53 files, regression corpus)

## Action Items & Next Steps

**Immediate — finish the audit-bug queue (basics only, per user):**
1. **`toStr` + `+` loses `str`-ness (IN PROGRESS).** `n.toStr + " bottles"` picks
   the numeric `+` overload. Established so far: `n.toStr` alone types and runs
   fine (probe `scratchpad/tostr3.tuck` works); it only breaks under `+`; the
   concat condition is `e.left.ty.kind == tkNamed and name in ["str","string"]`
   at `codegen.nim:469` and `:772`. Next step was dumping the AST
   (`./tuck parse <file> --ast`, drop the trailing line) for
   `scratchpad/tostr4.tuck` to see whether `e.left.ty` is unset or whether the
   expression parses as `n.(toStr + "...")` — a precedence problem.
2. **Indexing `xs[i]` does not exist** — silently misparsed as a fresh list
   literal `[i]`. Biggest blast radius in the language: blocks sort, binary
   search, sieve, palindrome, Caesar, string reversal. Needs parser + checker +
   both codegens.
3. **`if` has no expression form** — `let x = if a: b else: c` is a parse error.
4. **`saturating` literal out of range traps** instead of clamping (spec promises
   saturating never traps).

**Deliberately deferred** (user: basics first, not unique features): `pred`/`set`
prefix keywords are entirely unparsed by the parser despite being a spec pillar
(§3.6); seq/string stdlib (`add`, `split`, indexed assignment) is unbuilt by
design per `stdlib-blocks.md` and blocked on the Seq/traits ruling.

**Still open from the previous handoff:** actor runtime ruling (nim-cps vs
hand-rolled state machines) blocking example 16 and TOUR-GAPS #9; match `:` vs
decision `->` arrow unification; examples 11/20 (`when TARGET` §8.3, pool §7.2).

## Other Notes
- Full matrix: `typecheck_tests`, `compile_all_examples`, `end_to_end`,
  `cli_smoke.sh`, `beef_backend` — with `BEEFBUILD_BIN=/home/kl/apps/Beef/IDE/dist/BeefBuild`
  for the real Beef compile checks. All green at 2632da0.
- Rebuild the repo-root binary (`nim c -o:tuck tuck.nim`) before any CLI probe.
- Gates unchanged at Nim 21/25, Beef 20/25 examples.
- User preferences confirmed this session (saved to memory): commit after every
  success rather than batching; in Bash use literal full paths (no shell vars) and
  prefer Read/Edit over `sed`.
