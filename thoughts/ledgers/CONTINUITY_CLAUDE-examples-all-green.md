# Continuity: examples-all-green

## Goal
All 25 examples emit Nim that (a) passes `nim check`, (b) is semantically
equivalent to the Tuck source (emitted code DOES what the source says —
runtime-verified where a main exists). Gate grows from 15/25 toward 25/25;
each newly-green example joins nimCheckExpected (and beefCheckExpected
when Beef also compiles it).

## Constraints
- TDD: failing gate entry / test first, then the fix.
- Semantic equivalence beats nim-check: alias() currently emits a NO-OP
  pass-through (genCall: `alias` → args[0]) — 01's alias line is silently
  wrong today even though 01 nim-checks. Fixing alias fixes 01's semantics
  and 18.
- Suites after every phase; commit per phase (standing OK).
- Beef backend mirrors every codegen change (parity commitment).

## Key Decisions
- Audit method: compile each example, nim check with sanitized module name
  (m_NN_name), read first error (scratchpad/exaudit script, rerunnable).
- Order: bugs first, then sketch-decl edits, then features by size.

## State
- Done:
  - [x] Audit: 15 green / 9 broken, each classified (2026-07-13).
  - [x] Phase 1: chain-in-tail-return BUG fixed (both backends,
        idempotent across shared AST; cli_smoke runtime case exits 42).
        17's residue = `merge`/`input` keyword feature → new phase 6b.
  - [x] Phase 2: 09 rewritten (enum columns → exact analysis, catch-all row
        was provably unreachable and removed) + 12 rewritten (real decls;
        pseudo `transition` calls → comments). Exposed + fixed a REAL
        emitter gap: payload-variant construction `{p} Type.Variant`
        emitted `Type.Variant(args)` — invalid in both backends. New
        sumVariantCtor (Nim: kind-tagged object ctor; Beef: kind +
        positional TRec) hooked into both call paths + bare exkField.
        Gates now 17/25 both backends.
  - [x] Phase 3: 04 GREEN both backends. Interface contracts (dkMixin
        member, nil body) emit nothing; mixin fns with `self` materialize
        only at `+ mixin` composition (Self → object, self: var T / ref T);
        `+ RecordType` embeds as a field; object member fns gain
        self: var ObjName (Nim) / ref ObjName (Beef — call-site ref marker
        is a named ceiling); checker binds `self` in object scope; emitNim
        now two-pass (types before procs — Nim decl-before-use vs Tuck
        order-independence; object type headers via ctx.typeSection).
        Gates 18/25 both.
  - [x] Phase 4: alias() REAL. Checker types the result (renamed record;
        bad source field / non-ident target = errors). Nim emits the
        renamed tuple (temp-bind for non-var receivers); Beef emits the
        renamed TRec positional ctor (exkVar+ty only, else pass-through
        ceiling). Fixes 18 AND 01's silent no-op. Gates 19/25 both.
  - [x] Phase 5: bake v1 LANDED (user ruling: Factor-fry model, Nim-generic
        lowering). `:name` fn refs emit bare; `fn` type → `auto` (Nim
        monomorphizes); bake = typed struct rebuild (override/add, value
        overrides type-checked); `slot.invoke {args}` builtin calls
        through the slot. Runtime-verified: partial application exits 7.
        03 in Nim gate (20/25). CEILING: Beef bake pass-through — needs a
        delegate-type story (03 not in Beef gate, still 19).
  - [x] Phase 6b: `input` + `merge` LANDED (user rulings). input = the fn's
        whole payload struct, bound by the checker (params record),
        codegen rewrites input.x → x and bare input → param-tuple/TRec
        rebuild. merge = FLATTEN: union of member structs' fields, name
        collision = error, non-struct member = error; Nim emits the flat
        tuple, Beef the union TRec. Runtime-verified (merge probe exits
        33). 17 rewritten and in BOTH gates: Nim 21/25, Beef 20.
  - [x] Control flow loops (2026-07-19, spec 2.6/3.6b): unified for
        (cond/iter/indexed), loop:, break/continue (depth-checked), spaced-..
        ranges (Nim convention), fn inline. Runtime exit-17 smoke both
        backends. Bugs fixed on the way: block:-captured break (now
        `if true:` wrapper), value-returning main → quit(main()), msgpack
        cache Defect-vs-stamp, continue-keyword vs errors-policy.
  - [x] AST architecture pass (2026-07-22): the tree is now pure SYNTAX and
        the semantic layer lives beside it. Every Expr/ChainStep carries a
        NodeId assigned at the parse boundary; the checker writes calls,
        types and shortcut sites into a Resolution keyed by that id
        (compiler/resolution.nim, global `semLayer`). ty, shortcutSite and
        all five side-node fields (callNode x2, varCallNode, brCallNode,
        brAssignNode) are GONE from ast.nim. Each backend deep-copies the
        checked tree before lowering, so Nim's lowering no longer mutates
        what Beef then reads — ids survive the copy, which is why the
        id-keyed layer was worth having. Also: the two genExpr overloads
        merged into one (they had diverged in BOTH directions, 196 lines
        deleted), and every ExprKind dispatch lost its `else` so a missing
        arm is now a compile error. Research basis: rustc TypeckResults /
        Roslyn SemanticModel vs Nim semArrayAccess; rulings recorded in the
        commits.
  - [x] `[saturating]` REAL (2026-07-22, spec 4.1). Root cause was the
        PARSER: `type X = u16 [attr]` had its trailing attrs clobbered by
        the pre-`=` ones, so the attribute never reached any backend —
        [wrapping] and [trapping] were dead too. Store-guard design (clamp
        where a value is stored, on a wider intermediate) not per-operator:
        `a + b - c` all 60000 is 60000, not 5535. ~3 branchless instructions
        (cmov), measured. Ceiling: u64 has no wider intermediate.
  - [x] `or return` DROPPED (2026-07-22). Never worked — codegen-only
        pattern match, emitted invalid Nim. and/or/xor are strictly boolean
        now, ENFORCED (there had been no operand rule at all: `5 or "x"`
        typechecked). ?T in a boolean position reads as "is present".
  - [x] Pool §7.2 LANDED (2026-07-23). `pool X = ElemType [count: N]` —
        arbitrary element type (not always an array; 7.4 pools files and
        connections). Own DeclKind like registry/arena. count REQUIRED (a
        pool without one has no static footprint). No on_full: exhaustion
        is ?T absence and the caller decides. release goes through the POOL
        (the element may be a primitive with no methods). rt ObjectPool
        rewritten from ptr/nil to TuckResult[T]. Example 11 GREEN + new
        example 25-pools (runtime-verified, exit 4). Gate 23/25.
  - [x] Early-return guards NARROW (2026-07-23). `if not r.ok: return` now
        narrows the rest of the fn, for !T and ?T alike, provided the branch
        always exits. Underneath was a parser bug: `not r.ok` parsed as
        `(not r).ok` — unary took a primary, so the guard shape the checker
        wanted never existed. Unary now binds looser than `.field`/`[i]`
        (`-p.v` was equally wrong). Narrowing lives in exkBlock, since an
        early-return guard narrows its SIBLINGS, not its subtree.
- Now: [→] Phase 6: 16/20 — `.fn {args}` ruling + `when TARGET`.
- Remaining:
  - [ ] Phase 3: 04 — `Self` mapping + interface/manager emission + empty
        setMany body indent (`proc setMany(self: Self,...)` invalid Nim).
  - [ ] Phase 4: alias() restructuring lowering (spec 2.5) — fixes 18 AND
        01's silent no-op (semantic!). Checker knows field maps; codegen
        emits tuple rebuild `(id: x.trackId, name: x.title, ...)`.
  - [ ] Phase 5: 03 — bake real specialization (spec 3.5; emits garbage
        `x((someFunc: _add))` today).
  - [x] Phase 6: 11 GREEN (2026-07-23) — pool landed and SensorEvent (a
        defect in the EXAMPLE, undeclared) added.
  - [ ] Phase 6b: 17 — `input` keyword + `merge` (structural merge = future
        language keyword per user). Needs a design ruling first.
  - [ ] Phase 7: 20 — transitionTo-with-payload inside actor handler emits
        `PlayerState.Decoding(transitionTo(self.state))(rate)` garbage;
        register DSL depth (`DAC_CR.EN = true` — MMIO attrs).
  - [ ] Phase 8: 16 — `on select` §9.3 + timeout sugar (`timeout.5s` emits
        invalid case arm). BLOCKED on actor/task runtime strategy ruling
        (nim-cps vs hand-rolled state machines, ROADMAP 2026-07-09).
  - [ ] Phase 9: semantic-equivalence pass — runtime-verify every example
        with a main (extend gate to build+run+assert where feasible).

## Gate: Nim 23/25, Beef 20/25 (2026-07-23)
Remaining broken: **16** (`.fn {args}` on an undeclared fn emits a bare field
access, argument dropped — needs a ruling: resolve as a call, or error as
undeclared?), **20** (MMIO register fields — `DMA1_CH3 ..EN` — after its pool
and match-indent blockers cleared), **03** Beef-side only (delegate types).

## known_bugs suite (tests/known_bugs.nim)
Every confirmed bug, open or fixed, written as an assertion of CORRECT
behaviour plus a `fixed` flag. Fix a bug -> flip its flag -> the same
assertion becomes a permanent regression guard. The suite fails BOTH when a
fix lands unflagged and when a fixed bug returns. Currently 6 open, 6 fixed.
Open: `/=` on ints emits float `/`; toStr loses str-ness under `+`; `if` has
no expression form; Beef does not clamp [saturating]; a type ARGUMENT named
like an attribute (`Box[error]`) still fails (the valued half `[name: value]`
is fixed, bare markers still use the word list); `.fn {args}` on an
undeclared fn.

## Open Questions
- bake (03): what is v1? (a) true inline rewrite per spec 3.5, or (b) bind
  the fn-ref into the struct (proc-typed field, call through it) with
  inlining later. Also needs rulings: `:name` fn-ref literal semantics,
  `op invoke {args}` call-through syntax, and the `fn` field TYPE story
  (currently maps to `pointer` — uncallable).
- `when TARGET` §8.3 + top-level statements / implicit main (20).
- **16's `.fn {args}` on an undeclared fn** — `buf.copyFrom {data}` emits
  `self.buf.copyFrom`, a field read with the argument silently dropped.
  Ruling needed: resolve it as a call anyway (sketch-friendly), or report
  copyFrom as undeclared? Silently emitting a field access is neither.
- User asked for MORE TESTS AND EXAMPLES, a few per feature. Pool now has 8
  tests + a usage example; most older features still rest on one example
  each. That was the standing request when the session ended.
- `input` keyword + `merge` (17) — structural-merge keyword design.
- on select §9.3 (16) — still behind the actor-runtime strategy ruling.
- 20: transitionTo-with-payload inside actor handlers emits garbage —
  mechanical fix possible once the intended lowering is confirmed
  (what does `{rate} PlayerState.Decoding transitionTo` mean in a
  handler? construct-then-checked-assign to self.state?).
- UNCONFIRMED: does 04 need interface satisfies-checking (spec 5.2/5.3) or
  just emission fixes to go green?
- Phase 8 needs a user ruling on the task runtime before it can start.
- `{5}`-style timeout sugar in 16 (`timeout.5s`) — syntax itself may need
  a ruling (5s lexing).

## Working Set
- Audit script: scratchpad/exaudit (rerun: see 2026-07-13 session)
- Gate lists: tests/compile_all_examples.nim nimCheckExpected,
  tests/beef_backend.nim beefCheckExpected
- Test: full matrix — typecheck_tests, compile_all_examples, end_to_end,
  cli_smoke.sh (BEEFBUILD_BIN=~/apps/Beef/IDE/dist/BeefBuild), beef_backend,
  known_bugs
- known_bugs (2026-07-22): every confirmed bug, open or fixed, asserted as
  CORRECT behaviour plus a `fixed` flag. Fix a bug -> flip its flag -> the
  same assertion becomes a permanent regression guard. Suite fails both when
  a fix lands unflagged and when a fixed bug returns. 5 open, 1 fixed.
