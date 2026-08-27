# Continuity: D (dlang) codegen backend

## Goal
Third backend beside Nim and Odin: `tuck c --dlang` emits `.d`, `tuck b --dlang`
builds a binary with dmd. Done = the run-verified examples that pass under
`--odin` pass under `--dlang` (same exit codes), suite `d_backend` green.
This is ROADMAP "Experimental #1" — the experiment also *answers* "does the
two-backend discipline generalize" and "where do Nim-isms hide"; findings go
in a DISCOVERIES section at the bottom of this ledger.

## Constraints

**Portable runtime semantics (user, 2026-08-27).** Runtime semantics AND
runtime characteristics must be identical across backends — a program's
observable behaviour and its performance shape should not depend on which
backend built it. That is why fibers/async/actors/scheduling ride on
minicoro everywhere rather than each backend's native coroutines. Other
subsystems should follow the same principle; today some are per-backend
reimplementations (tuck_rt.nim / tuck_rt.odin / tuck_rt.d) rather than one
shared library, which is a known divergence risk, not a design choice.
Implication for M7: the D backend gets minicoro too, NOT core.thread.Fiber
(supersedes the earlier plan note).

**Idiomatic output is allowed, semantics are not negotiable (user).** Goldens
exist, so D may emit its own idiomatic parallel of a construct rather than a
transliteration of the Nim/Odin shape — and the codegen should be tweaked
toward that best-looking output. The constraint is unchanged: whatever it
emits must still deliver exactly what Tuck promises.

**Refactor periodically (user).** Every few milestones, do a pass over the
new code: simplify, improve readability, apply hindsight. Not only when the
complexity gate complains.
- Written in Nim like the rest: `compiler/codegen_d.nim` (+ `codegen_d_util.nim`
  if size demands), mirroring codegen_odin.nim's structure.
- Pipeline invariants (CLAUDE.md): backend lowers its OWN deepCopy; `case` over
  ExprKind/DeclKind/TypeKind takes NO `else`; complexity gate CEILING=22 per
  proc, HEAVY = count of cc>=15 — keep procs small like the Odin file does.
- Mangling already ran whole-program before the backend sees the tree.
- Emitted `.d` under examples/ stays git-ignored initially (the `.bf` precedent)
  until the backend matures; then tracked like `.nim`/`.odin`.
- dmd on PATH: DMD64 v2.113.0-beta.1 (named struct-literal args OK, >=2.103).

## Key Decisions
- Flag: `--dlang` (not `--d`, reads like a typo of `-d:`).
- One `.d` file per Tuck module: entry `<base>.d`, imports `mod_<name>.d`
  (D modules are files, no directory dance like Odin packages). Qualified
  refs via aliased import: `import time = mod_time;` → `time.tuck_ms(5)`.
- Runtime: `compiler/tuckrt_d/tuck_rt.d` copied beside output (Odin tuckrt
  pattern); emitted `import rt = tuck_rt;`, intrinsics as `rt.printLine(...)`.
- Build: `dmd -i -I<outDir>` so imports resolve without listing files.
- Type map: Tuck `int` → D `long` (D int is 32-bit!), `str` → `string`,
  `Seq[T]` → `T[]`, f32/f64 → float/double, iN/uN → byte/short/int/long +u.
- Actors/tasks: NOT phase 1. Emit a loud "D backend: not yet supported" die,
  not silent wrong code. Phase 4 uses core.thread.Fiber (druntime, no minicoro).

## State
Approved plan: ~/.claude/plans/fancy-yawning-karp.md (T1-T29, 7 milestones).
Ruling: most-identical native D construct, ONLY where semantics identical —
see memory d-backend-semantics-identical. !T = TuckResult value, no exceptions.

- Done:
  - [x] Orientation: driver flow (tuck.nim:400-530), Odin emitter skeleton +
        call machinery read, AST kinds enumerated (24 exk, 21 dk, 9 tk)
- Done:
  - [x] Milestone 1 — plumbing (hello world end to end, exit 7, stdout ≡ Nim
        backend; dmd build 213ms). Also fixed pre-existing red complexity
        gate: complexity.nim walk cc=23>22, split walkMatch/walkSelect out.
  - [x] T1 tuckrt_d/tuck_rt.d (print/printLine/toStr template)
  - [x] T2 hand-written target hello.d + mod_console.d
  - [x] T3 codegen_d.nim skeleton, exhaustive dispatches, loud dUnsupported;
        extern fwd TODO-comment policy for not-yet-portable signatures
  - [x] T4 --dlang compile path (mod_<name>.d files, aliased imports,
        resolveDCallee for bare-name cross-module calls)
  - [x] T5 --dlang build path (dmd -i -I<outDir>, _d suffix, skip if absent)
  - [x] M2 statements & scalars (T6-T10): let/var with checker-typed decls,
        ops, if/ternary/while/loop/break/continue, foreach ranges (incl +1),
        list literals, tuple foreach, strings (~ concat, .length cast),
        field access (resolved calls, .len), echo→writeln. Probes exit
        77 and 38 on both backends, stdout identical.
  - [x] T28 pulled forward (user: unit tests after each part): harness
        vEmitD verb + emitsD/omitsD/needD/findDmd, --quick includes D
        emission, tests/suites/d_backend.nim (17 assertions incl. dmd
        build+run via needCmdAfter chain). Grow it per milestone.
  - [x] M3 records & calls (T11-T17): TRec hoisting (same FNV hash naming
        as Odin), named-arg struct literals, payload/record-var explosion,
        combinators (bake/alias/merge ports), chains (.. steps as
        statements), pending stubs (fn templates, stderr like Nim), objects
        (struct + Obj_member free procs, ref self — probe: 9), imported
        type qualification, input payload rebuild, generic extern
        forwarders (templates), bracket at/setAt via resolved calls,
        Seq .dup on assignment (aliasing probe: 64 both). Examples 01, 02,
        07, 18, 41 run-identical to Nim backend; 17 compiles (specimen).
        Suite now 28 assertions. Invariant-carrying paths die loudly (M4).
- Remaining:
  - [ ] M3 records & calls: T11 TRec hoisting, T12 payload explosion+qualified,
        T13 chains, T14 alias/merge, T15 pending stubs, T16 objects/self,
        T17 slice-aliasing audit
  - [x] T18/T19 sum types + match: payload-free sums are plain D enums,
        match is `final switch` (D re-checks exhaustiveness — the guarantee
        Tuck makes), value-position match is an immediately-called lambda
        keeping that check. Bare tags qualify to their enum. Example 39
        run-identical. PAYLOAD sums deferred: broken in Nim AND Odin too
        (see DISCOVERIES) — fix the authority first, in one pass for all
        three backends.
  - [ ] M4 rest: T20 TuckResult, T21 error policy,
        T22 invariants (version(tuckNoInvariants)), T23 interfaces,
        T24 decision tables+saturating+const+static assert
  - [ ] Sweep status (44 examples): 13 compile clean, 22 die naming their
        own task, 9 dmd-fail (5 are FFI = T26). Re-run after each task.
  - [ ] M5 modules & extern: T25 mod_*.d, T26 extern flavours, T27 emit_examples
  - [ ] M6 tests: T28 harness+d_backend suite, T29 example sweep
  - [ ] M7 concurrency (Fiber) — own plan when reached

## Open Questions
- UNCONFIRMED: D sum-type shape — mirror Odin (tag enum + one struct holding
  every payload) vs D unions vs std.sumtype. Start with the Odin mirror,
  revisit when match emission lands.
- UNCONFIRMED: ?T lowering — Nullable!T (std.typecons) vs tiny TuckOpt(T) in
  tuck_rt.d. Leaning TuckOpt: no phobos dependency question, same shape both
  backends.
- UNCONFIRMED: whether `dmd -i` picks up tuck_rt.d reliably from outDir or
  needs explicit file list.

## Working Set
- Branch: claude/spec-code-audit-34xh4q
- New files: compiler/codegen_d.nim, compiler/tuckrt_d/tuck_rt.d
- Touched: tuck.nim (compile + build paths), later tests/harness.nim,
  tests/suites/all.nim, tests/suites/d_backend.nim
- Test: ./quick-test.sh (must stay green — D backend is additive),
  scratchpad hello: /tmp/claude-1000/-home-kl-prog-tuck-lexer/*/scratchpad/
- Reference emitters: compiler/codegen_odin.nim (structure to mirror),
  compiler/codegen.nim (Nim semantics), compiler/codegen_common.nim (shared)

## DISCOVERIES (the experiment's real product)
- D `int` is 32-bit; Tuck/Nim/Odin `int` is 64. First Nim-ism found before
  writing a line: any backend assuming `int` widths silently truncates.
- Nim-ism #2 (verified with dmd, wraps at 2^31): `auto x = 0` in D is a
  32-bit int, while Nim's `var x = 0` infers 64-bit. The Nim backend gets
  64-bit inference FREE from Nim; any other backend must state the
  checker's type at every declaration. Fix: genDAssign emits the stamped
  type (dDeclType), auto only for sketch-mode Unknown.
- Nim-ism #3: `.len` rides through the Nim backend untranslated because
  Nim shares Tuck's spelling AND signedness. D's `.length` is size_t
  (unsigned) — poisons later arithmetic via promotion. Emitted as
  `cast(long) x.length`.
- Checker lets a PREFIX call slip through silently: `echo total` (wrong —
  Tuck is postfix) typechecks and emits `total(echo)` in the Nim backend.
  Gradual typing reads both names as Unknown. Same §0 trap family as
  FRICTIONS #1's fnsig workaround. Not fixed here (recorded per user
  instruction: record bugs midway, go on).
- BUG (Nim backend, pre-existing): a value-returning call as a bare
  statement emits an un-discarded Nim call — `{self: c} bump` alone on a
  line dies in the Nim backend with "expression 'bump(c)' is of type 'int'
  and has to be used (or discarded)". Needs a `discard ` prefix on
  dropped-result statements (Odin already has genDroppedResult plumbing).
- BUG (checker, pre-existing): `items[0] = 0` where items is a PARAM
  typechecks — bracket assignment bypasses the TK-TY15 write-through-param
  rule — then dies in the Nim backend (`setAt` wants var). The checker
  should reject at the bracket-assign site.
- D slices alias on assignment where Tuck/Nim seqs copy — verified
  divergent (b[0]=50 wrote a[0] before the fix). Emitter now .dups every
  Seq-typed assignment except fresh list literals. KNOWN GAP: a record
  containing a Seq field still shallow-copies the slice on struct assign;
  needs a probe + per-field dup (or a postblit) when records-with-seqs
  actually appear.
- D function templates instantiate per call site, so pending stubs and
  generic externs (`toStr[T]`) map 1:1 onto Nim's generic procs — no
  boxing, same monomorphization story.
- BUG (Odin backend, pre-existing): a `match` whose arms are `return`
  statements emits Odin's ternary with `return` inside it —
  `return ((s == Kind.Dot) ? return 0 : ...)`, which is not valid Odin.
  Found probing sum types for M4. The Nim backend emits a proper `case`
  for the same source. D follows Nim's shape (final switch), not this.
- BUG (both existing backends, pre-existing): **payload-carrying sum types
  do not work end to end.** `type Shape: | Dot | Line({length: int})` with
  `match s: Line: return s.length` typechecks, then:
  * Nim backend emits `case s` (not `case s.kind`) → "selector must be of
    an ordinal type"; payload reads emit `s.length`, but the declared
    layout is `s.line.length`; and construction drops the payload
    entirely (`tuck_Shape(kind: Line)` for `Shape.Line {length: 5}`).
  * Odin backend emits the invalid ternary-with-return above.
  Payload-FREE sums are fine in both (probe: exit 23). So M4's T18/T19
  scope to payload-free sums + match; payload sums need the AUTHORITY
  fixed first — a language-level gap, not a D one. Worth its own task
  after the backend, since fixing it in three backends at once is the
  cheapest moment.
