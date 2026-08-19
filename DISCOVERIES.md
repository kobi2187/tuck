# DISCOVERIES

Append-only. One entry = what was assumed, what turned out true. Newest last.
Companion to `ROADMAP-GRAPH.md` (the map) and `TASKS.md` (the holes).

Format: `### D-nn · <one line>` then **Assumed / Found / Node** (the
`ROADMAP-GRAPH.md` node it changes) and, where it exists, the evidence.

---

## Spike S-01 — the weekend program (2026-08-19)

Node: **C11**. Throwaway source at `scratchpad/spike-weekend.tuck`, ~95 lines,
written as a jam developer *would* write it (loot table, turn loop, scoring,
CSV save file, leaderboard), then run at the checker. Disposable by design.

### D-01 · List literals are single-line only
**Assumed:** a multi-line list literal with leading commas parses, as in every
language a jam dev comes from.
**Found:** parse error at the first line break. `[a, b, c]` on one line works;
the moment a loot table is long enough to wrap, it stops.
**Node:** C11 (papercut), no foundation node — parser-local.

### D-02 · Value-`if` does not compose as an operand
**Assumed:** `total = total + if x: a else: b` works, since `if` is an
expression (ruling R2).
**Found:** parse error — `Expected an expression here, found 'if'`. Value-`if`
is accepted at the top of an assignment RHS (`let limit = if hot: 90 else: 20`,
`examples/39`) but not nested inside a binary expression. Workaround is a
`let` per branch-value.
**Node:** C11. Worth a decision: is this the intended ceiling or a gap?

### D-03 · Bare-receiver postfix breaks inside a struct literal — **WRONG, see D-13**
**Assumed:** `{who: f at 0}` works — postfix application is the house style.
**Found:** `Expected field name in struct literal`.
**Node:** C11.
**Retracted 2026-08-19** — the diagnosis was wrong; see D-13. The entry stays
because this log is append-only and a wrong reading is worth keeping visible.

### D-13 · D-03 was misdiagnosed: bare-receiver postfix in a field is fine
**Assumed (from D-03):** a bare receiver cannot be postfix-applied in a
struct-literal field position, so two signature features do not compose.
**Found:** they compose. `{a: n twice} P` checks clean — reproduced while
writing the ceiling suite for the T-11 ruling. What actually failed in the
spike was `f at 0`: a postfix call carrying an **extra argument**, which is not
syntax in any position, field or otherwise. `at` takes `{items, index}`, so the
payload form is required — `{items: f, index: 0} at`.
**Node:** none. No ceiling to document, no gap to fix.
**Lesson:** the spike reported the symptom's location, not its cause. Writing
the assertion is what caught it — which is the argument for pinning a ruling
with a test rather than only with prose.

### D-04 · Parse errors are genuinely good; type errors are not
**Assumed (from the toolchain report):** the Elm-grade registry prose is
unreachable from a user's terminal.
**Found:** half right. `/` produced *"`/` is not an operator in Tuck — write
`/i` for integer division… The operator names the arithmetic so the result
cannot depend on how the operands were inferred."* — rule, fix and rationale.
Type errors on the same file are one line with no snippet.
**Node:** toolchain lens §9 — confirms the split is `dieSyntax` vs
`die(err.msg)`, not a lack of prose.

### D-05 · The double-position bug is live
**Assumed:** reported by the toolchain research, not reproduced.
**Found:** reproduced verbatim —
`spike-weekend.tuck:34:17: Type Error: … at line 34:17`. Prepended by
`withModulePrefix` (`typecheck.nim:3491`), appended by `fail`
(`typecheck_util.nim:57`).
**Node:** §9 R1.

### D-06 · `Map[str, int]` does not parse as a type at all
**Assumed:** `Map` is missing from the stdlib (`stdlib-blocks.md` §9, blocked
on the generics ruling).
**Found:** worse — a two-parameter generic in expression position parses as
*indexing*: `Type Error: indexing takes exactly one index, got 2`. So the
absence is not merely "no module"; the syntax a user would reach for is
claimed by another construct.
**Node:** **F1**. Raises its cost estimate and confirms its promotion to a 1.0
gate under the jam rule.

### D-07 · std/time collides with itself in the call namespace
**Assumed:** `nowMs().ms` reads the field.
**Found:** `Type Error: 'ms' is both a field here and a declared fn — rename
one; fields and fns share the call namespace`. `std/time` declares `fn ms(...)`
*and* returns `{ms: u64}` from `nowMs` — **the stdlib collides with itself**,
and a jam dev hits it the first time they measure elapsed time.
**Node:** stdlib tier §3. Cheap fix, but it is a live defect in shipped `std/`.

### D-08 · The checker passes a program built on a dozen nonexistent functions
**Assumed:** missing stdlib shows up as errors telling you what is missing.
**Found:** `./tuck ch` → **`OK (19.0 ms)`** on a program calling `sortBy`,
`push`, `new`, `split`, `parseInt`, `randBelow`, `len` and `keys` — none of
which exist anywhere. Gradual typing types every unknown call as `Unknown` and
passes it.
**Node:** C11, and it reframes the whole stdlib branch: **the compiler cannot
tell you the stdlib is missing.** This is the known "gradual typing hides
damage" hazard, appearing at stdlib scope rather than parser scope.

### D-09 · `tuck c` emits invalid Nim and still exits 0
**Assumed:** codegen either works or errors.
**Found:** `tuck c` printed `OK (13.3 ms)`, exit code 0, having emitted
`tuck_Run(              out.push = )` and
`pick(at(table(      bag.push = )))`. The `..` chain-mutation form against an
undeclared method produces syntactically broken Nim, silently. Two green
stages on a program that cannot work.
**Node:** C11 / §9. Pairs with D-08: check is green, compile is green, only
the *host* compiler objects.

### D-10 · Tuck identifiers are not mangled against host keywords
**Assumed:** the `tuck_` prefix handles host collisions.
**Found:** a local named `out` emitted a bare `out` into Nim →
`Error: identifier expected, but got 'keyword out'`. Locals are not prefixed.
Every Nim and Odin keyword is a landmine in a user's variable names.
**Node:** codegen, both backends.

### D-11 · The failure the user finally sees names a file they did not write
**Assumed:** the two-transpile debug story is a runtime/GDB problem.
**Found:** it is a *build-time* problem too — the only actionable error was
`scratchpad/spike_weekend.nim(41, 7)`, a generated file, at a generated line.
**Node:** §9 LATER (debugger) — promote the `{.line.}`-pragma spike; this is
not only about backtraces.

### D-12 · `tuck b` does exit non-zero on a Nim failure
**Assumed (mid-spike, wrongly):** the `tuck.nim:569` fall-through-to-OK bug
applies to the Nim path too.
**Found:** `tuck b` exits **1**. The known hole stays scoped to `--odin`.
Recorded so nobody re-derives it.
**Node:** 0.4 CONNECT — no change.

---

### What S-01 changes in the map

1. **`F1` is confirmed as the top stdlib gate** (D-06), and its scope is larger
   than "add a module".
2. **A new foundation node is implied: "the checker must know what the stdlib
   does not have"** (D-08 + D-09). Two green stages on a dead program is worse
   for a newcomer than a hard error. Provisional id **F26**.
3. **The jam papercuts (D-01, D-02, D-03) are parser-local and cheap**, and
   together they are most of what "the language feels unfinished" would mean to
   a two-day user.
4. **D-07 is a shipped bug in `std/`**, not a missing feature.
