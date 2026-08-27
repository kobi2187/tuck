# Continuity: D (dlang) codegen backend

## Goal
Third backend beside Nim and Odin: `tuck c --dlang` emits `.d`, `tuck b --dlang`
builds a binary with dmd. Done = the run-verified examples that pass under
`--odin` pass under `--dlang` (same exit codes), suite `d_backend` green.
This is ROADMAP "Experimental #1" — the experiment also *answers* "does the
two-backend discipline generalize" and "where do Nim-isms hide"; findings go
in a DISCOVERIES section at the bottom of this ledger.

## Constraints
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
- Now: [→] M3 records & calls: T11 TRec hoisting, T12 payload explosion+
        qualified, T13 chains, T14 alias/merge, T15 pending stubs,
        T16 objects/self, T17 slice-aliasing audit
- Remaining:
  - [ ] M3 records & calls: T11 TRec hoisting, T12 payload explosion+qualified,
        T13 chains, T14 alias/merge, T15 pending stubs, T16 objects/self,
        T17 slice-aliasing audit
  - [ ] M4 sums & errors: T18 sum types, T19 match/final switch, T20 TuckResult,
        T21 error policy, T22 invariants (version(tuckNoInvariants)),
        T23 interfaces, T24 decision tables+saturating+const+static assert
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
