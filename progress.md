# Progress Log

## 2026-07-05
- Assessed project: lexer/parser solid, semantics = effects only, codegen unverified.
- Implemented bidirectional type checker: compiler/typecheck.nim (~370 lines).
  - Pass 1: collectSigs (fns, tasks, types, nested in objects/mixins/actors).
  - Pass 2: synthesize/check per decl; fail-fast SemanticError with span.
  - Rules live: subset matching, missing/wrong-typed call fields, return type,
    field-access on known records, arithmetic/comparison clashes, `..` on let,
    numeric-group widening, Unknown propagation for undeclared symbols.
- AST/parser: exkAssign now carries isDecl/isMutable.
- lowering.nim: exported getFieldsForType.
- Tests: tests/typecheck_tests.nim (7 negative + 5 positive) — all pass.
  compile_all_examples 20/20; end_to_end unchanged + effect test still passes.
- Fixed examples/17-input-merge.tuck (let→var, real violation found by checker).

## 2026-07-05 (later) — verification loop + codegen fixes
- git init (branch main) + .gitignore for build artifacts.
- codegen.nim fixes: str/f32/f64/usize/Seq/Array/fn type mappings, uN/iN bit-width
  rounding (u2→uint8, u12→uint16), `%`→`mod`, unit sugar (5.ms → 5), !T/?T wrapper
  erasure in genType, registry: consistent field indent + forward decls for handlers.
- compile_all_examples now runs `nim check` on generated Nim; expected-pass gate:
  06-transitions, 10-invariants, 13-arena-mem, 19-event-registry (4/20).
  Remaining 16 fail ONLY on sketch-inherent undeclared identifiers (fetch, merge,
  Feed, Action...) — need stubs/pending support to go green.
- All suites green: typecheck 12/12, examples 20/20 + nim-check gate, end_to_end.

## 2026-07-05 (later still) — emitter fixes round 2
- `...` pending holes emit `discard` (was verbatim `...` — invalid Nim).
- Inline sum-type fields hoisted to named enums (`<Parent><Field>Kind`) via
  `CodegenCtx.hoisted` accumulator, prepended in emitNim (fixed m08).
- Actor with zero handlers emits bare state object (empty enum invalid; m15).
- Actor handler params now ride the message envelope: fields deduped by name,
  `let p = msg.p` prelude per dispatch arm, typed send helpers (fixed m05).
- Parser: attr allowlist extended with big_endian/little_endian/volatile/
  wrapping/trapping — `u16 [big_endian]` no longer misparsed as generics (m15).
- nim-check gate now 7/20: 05, 06, 08, 10, 13, 15, 19.

## 2026-07-05 — `pending` feature (language-level TODO)
- Semantics (user-defined, supersedes spec 5.4 wording): compile prints TODO
  list of unimplemented fns every debug build (doesn't block); stubs are noops
  that log on invocation + return zero value so the skeleton RUNS; implemented
  fn still in pending block = compile error.
- ast: isPending on dkFn. parser already parsed pending blocks (dkMixin
  "pending" wrapper) — just sets the flag now.
- typecheck: pending sigs strictly checked at call sites (were already in
  fnSigs via mixin recursion); stale-pending check both directions;
  pendingReport*() returns the TODO list; drivers print it.
- codegen: pending stub = `proc name*[T](payload: T): Ret` — generic payload
  because Tuck passes one whole struct and lowering never explodes pending
  calls; logs to stderr, Nim zero-inits result. dkMixin("pending") emits stubs.
- examples: 01 + 07 gained pending blocks; 05 gained Feed type decl.
- Verified end-to-end: generated 07 binary runs, prints TUCK PENDING line, exit 0.
- nim-check gate now 9/20 (added 01, 05, 07). Tests 15/15.

## 2026-07-05 — tuck CLI
- tuck.nim at repo root: `tuck lex|l`, `parse|p` (--ast for JSON), `check|ch`,
  `compile|c` (-o:DIR, --beef). Fail fast: first error printed as
  file:line:col + message, exit 1. Timing printed per command (~1-2 ms/file).
- check = parse + effects + typecheck + PENDING report — the fast dev loop.
- emitNim gained rtImport param; CLI computes relative path from output dir to
  compiler/tuck_rt so emitted Nim compiles from anywhere.
- Gotcha logged: strutils.tokenize iterator shadowed local proc in for-loop —
  renamed to lexTokens.
- tests/cli_smoke.sh builds CLI, runs all commands, asserts fail-fast exit code
  and file:line:col prefix.

## 2026-07-05 — correctness checks round: transitions, decisions, effects
- Transition tables (spec 4.4): endpoints must be declared variants (typo
  check); [sealed] types verify every variant reachable from initial variant
  via graph walk.
- Decision tables (spec 6.1): isDecision flag on dkFn (parser sets it; codegen
  heuristic can move over later); checks: row width == declared inputs,
  unreachable rows (earlier row covers later, per-column wildcard/equality),
  completeness v1 = mandatory catch-all row (full domain analysis later).
- Effects: found + fixed parser bug — `-> void [io]` parsed [io] as GENERIC
  args on void (same class as big_endian bug); effect names added to attr
  allowlist and harvested from return-type attrs into fnEffects. `-> !{...} [io]`
  worked already (separate path). Effect tests now in typecheck_tests.
- Suite: 22 typecheck tests green, gate 9/9, cli smoke OK.

## 2026-07-05 — decision tables: exact analysis + packed-key codegen
- Enumerable columns (bool / fieldless sum types): checker enumerates all
  combinations — exact gap reports ("no row matches (priority: High,
  encrypted: false)"), proven unreachable rows, symbol validation, no
  catch-all needed. Open domains keep pairwise + catch-all + if-elif.
- Codegen emits `case ord(a) * stride + ord(b)` packed key, outcomes grouped —
  zero comparison chains. enumDomain helper lives in ast.nim (shared).
- Example 21-decision-bitmask; runtime-verified all 4 combos. Gate 10/21.

## 2026-07-05 — transition-table codegen: real tagged unions
- Sum types now emit by shape: fieldless+no-transitions → plain enum
  (decision tables key over these); payload variants → Nim object variant
  (kind enum + per-variant payload TUPLE field named after variant — dodges
  Nim's cross-branch field-name collision, e.g. config in 3 variants of 06);
  transitions add canTransition (pure matrix, set-membership per case arm) +
  transitionTo (checked assign, raises ValueError naming frm -> to).
- Old emission dropped payload fields entirely (06 only passed because Config/
  Feed vanished). 06 gained skeleton Config/Feed decls; payloads now carried.
- Runtime-verified: Unloaded->Loading->Ready with payloads, Ready->Loading
  raises "Invalid transition Ready -> Loading".
- The compile-time half (sealed flow analysis: fns returning sealed types only
  produce reachable variants) remains on backlog — type system catches what it
  can via the kind enum; matrix guards the rest at runtime.

## 2026-07-05 — errors as first-class values (!T / ?T / or / ?)
- Mapping confirmed with user: !T ≈ Zig error union, expr? ≈ try, or ≈
  catch/orelse unified. Philosophy locked: TUCK checker rejects everything —
  the user must never read a Nim diagnostic; nim-check gate exists to catch
  OUR emitter bugs only. Runtime errors = separate category (TuckResult, matrix).
- rt: TuckResult[T] {ok, err: uint16, val} — err 0 reserved for absence (?T);
  errCode("name") = compile-time FNV-1a→16bit (no compiler-side code table);
  tok/tokVoid/terr/tnone; tuckOr templates (bool overload keeps boolean `or`).
- checker: wrapper discipline — !T consumed w/o handling (args, arith, field
  access, condition) = error; `?` requires !-returning fn; or-fallback must
  match payload; bare T where !T expected = OK (auto-wrap on return).
- codegen: wrappers → TuckResult[T] (void→tuple[]); returns auto-wrap
  (tok/terr/tokVoid); Error.name → errCode; `x?` → paren stmt-list unwrap with
  early return; `x or fallback` → tuckOr; `x or return e` → unwrap-or-return.
- Nim gotchas found: one-line `block: let ...` invalid in expr position → use
  paren statement-list `(let t = e; ...)`; exkIf double-indent inside exkBlock
  fixed (self-indenting nodes no longer re-prefixed).
- Runtime-verified: propagation carries code (errCode("tooBig")), or-fallback
  recovers, ok-path unwraps. 36 checker tests green, gate 10/10.

## 2026-07-05 — error design tightened per user rulings
- `or` unwrapping REMOVED (user: too overloaded, ?? clashes with fluent style).
  `or` is strictly boolean again. Results flow whole as structs; handling
  functions will live in stdlib prelude later; errors may get short syntax
  later. `?` propagation stays (visible at every hop, lowers to early return,
  no unwinding — not exceptions).
- New rule: fallible (!T-returning) fns MUST be [io] — pure core is total;
  errors exist only at I/O / unknown-input boundaries (user's framing).
- New rule: discarding a !T result as a bare statement = compile error.
- Parser fix: `-> !void [io]` — markers attach as attrs on the PAYLOAD inside
  the wrapper, not the wrapper; harvestEffects() now walks in. Pending sigs
  also parse effect brackets now.
- Examples 04/05/14/16 gained [io] on fallible sigs. 37 tests green, gate 10/10.

## 2026-07-06 — spec 4.9: global error policy (spec only, via fork 3589c98)
- User ruled: three modes strict/continue/exit in one `errors` declaration
  (registry-style). continue = statement-position only, NO zero values ever;
  exit = handler at first unhandled site then exit; strict = today's discard
  ban + list-ALL-sites upgrade. SHORTCUTS (n) report every continue/exit build.
- §4.8 rewritten to match implementation (boolean or, results flow whole,
  [io] rule).
- NOT implemented yet. Build items: `errors` decl parse, policy in checker
  (strict list-all; continue/exit legalize statement-position discards),
  SHORTCUTS report, handler injection in codegen.

## 2026-07-06 — ?T is a true option (fork commit 1396823)
- TuckResult now tri-state: status tsOk | tsErr | tsAbsent — absence is a
  first-class state, not reserved err code 0. errCode gets full 16-bit space
  back; !?T failure-vs-absence now exact. `ok()` proc keeps emitted `.ok`
  syntax working, codegen unchanged. Suites green.
- Known checker gap (fork-flagged, backlogged): use sites don't distinguish
  ?T from !T — e.g. `?` on a ?T inside a !T fn passes.

## 2026-07-06 — spec 4.9 IMPLEMENTED: global error policy
- `errors [policy: strict|continue|exit]:` declaration parses (dkErrors);
  continue/exit require `on unhandled({code, site})` handler (checked).
- strict (default, no decl needed): unhandled sites now collected and ALL
  listed in one error (was fail-at-first).
- continue/exit: statement-position drops marked (shortcutSite on Expr),
  reported as SHORTCUTS (n) by CLI + test drivers; codegen wraps each site:
  `(let t = expr; if not t.ok: tuck_unhandled(t.err, "site"))` (+ quit(1)
  in exit mode). Generated tuck_unhandled = rt logger + user handler body.
- Item 7 done: `?` propagation now covers wrapper kinds — ?T can't propagate
  through a !T fn (needs ?T or !?T); rt tfwd() preserves status (absence no
  longer morphs into error 0 in transit).
- Typed struct-literal returns: `return {value: 42}` in !{value: u16} fn
  casts numeric fields to the declared payload type.
- Example 22-error-policy; gate 11/22. Runtime-verified: continue keeps
  running after handler, exit dies with code 1, stderr shows TUCK UNHANDLED.

## 2026-07-06 — postfix consolidation: three changes
- Paren-calls REMOVED from expressions: `f(x)` is now a parse error ("calls
  are postfix: {payload} fnName"). Parens survive only for grouping and the
  spec 8.2 compile-time builtins sizeof/alignof/offsetof.
- Variant construction is payload-first: `{config, feed} PlayerState.Ready`
  (postfix-ident parse now builds dotted callees, incl `[unsafe]` marker).
  Constructions fed by transitionTo chains exempt from the sealed rule
  (transitions ARE the legal path; runtime matrix still checks).
- Implicit last-expression return: tail value flows out as the result;
  codegen rewrites tail stmt into the existing return emission (auto-wrap,
  typed literals ride along). Control-flow tails (if/match) keep explicit
  returns v1.
- Typing teeth per user: if-branches and match-arms in value position must
  agree on type; fn tail must match declared return ("'f' flows {v: str}
  out of its body but declares {v: int}"). Fn-body tail exempt from the
  discard rule (it's the result, not a drop).
- Examples 04/12 + tests rewritten off paren-calls (postfix `n isOdd`,
  `{} writeLog` for zero-param, `val2 echo`).
- 52 checker tests green, gate 11/22, runtime-verified: implicit return in
  plain + fallible fns, early exit intact.

## 2026-07-06 — distinct types (user-directed design corrections)
- distinct Milliseconds = u32: strictly nominal in checker (no widening, no
  resolve-through); codegen emits Nim distinct + borrowed ops.
- NO unit magic in the compiler (user correction — first attempt used a
  [suffix: ms] attr, reverted): `ms` is an ordinary function
  `fn ms(value: u32) -> Milliseconds: value Milliseconds`; `5.ms` is postfix
  application; calling a distinct type's name converts from its base
  (lowers to Nim's native conversion).
- ARTICLE.md corrected: error names = declared enums (checker validation of
  Error.x against a declared enum = backlog); actors have runtime lib +
  lower toward it; timing qualified as small-example numbers. User ruling
  on perf: no seq-based AST for now — suitable data structures over
  micro-optimizations.
- Example 23-units in gate (12 valid). 57 checker tests green.

## 2026-07-08 — real imports: `import http` + `module::fn` + msgpack cache
- `import http` loads http.tuck from the importer's dir (compiler/modules.nim:
  loadProgram — import closure, diamond collapse, cycle = error). Access is
  qualified-only: `{url} http::get`; no unqualified leakage. `::` also works
  in pending blocks (`fn http::get(...)`) for module stubs without a module.
- ORDER-INDEPENDENT (user ruling): typecheckProgram pass 1 collects EVERY
  module's sigs, pass 2 checks bodies — call site may precede any decl.
- Gradualness kept: unknown module prefix = Unknown (sketches compile, e.g.
  17's audio::play); KNOWN module missing fn = error. Wrong/missing payload
  fields checked across module boundary.
- Incremental-compilation groundwork (user ruling): imported modules cache
  their AST as msgpack (<dir>/.tuck-cache/<name>.bin, msgpack4nim) keyed by
  compiler build stamp + source hash; best-effort, falls back to reparse.
  Needs -d:nimOldCaseObjects (config.nims) — msgpack4nim unpacks case
  objects by late discriminant assign; custom unpack procs if it ever bites.
- Codegen: one Nim file per module, main `import http`, qualified call =
  `http.get(...)` (Nim namespacing, no mangling); sketch-qualified pending
  stubs mangle :: → _. Cross-module param order read from the target module.
- 14-task rewritten (import http + `?` propagation + implicit return);
  examples/http.tuck new. Gate 13 (added 14-task). 60 checker tests,
  cli smoke, end_to_end all green. Runtime-verified: binary runs, TUCK
  PENDING for get/parse, exit 0.

## 2026-07-08 — signature index: check without touching import ASTs
- Per-dir .tuck-cache/index.bin (msgpack): module name → srcHash, cachedAt,
  deps (+hashes at index time), sigs (SigInfo: params/ret/isPending/line).
- `tuck check`: import with a FRESH entry resolves from the index — no
  reparse, no AST deserialization, no body re-check. Entries written only
  after a whole-program check passes, so trusting them is sound. Freshness =
  build stamp + own source hash + recursive dep-hash chain (a changed dep
  invalidates its importers).
- `tuck compile` keeps full ASTs (must emit) but refreshes the index too.
- PENDING report still lists pendings of sig-only modules (from SigInfo).
- typecheckProgram gained preSigs param; moduleSigs()/sigLine() exported.
- Verified: warm check leaves http.bin absent (module truly never loaded);
  source edit → full reload; bad payload caught against index sigs alone.
  64 checker tests, gate 13, cli smoke, end_to_end green.

## 2026-07-10 — error model v2 (user rulings) + extern blocks
- `extern:` blocks: sigs implemented by tuck_rt (no stub, module re-exports
  rt); `extern [c, header: "uart.h"]:` emits Nim importc — C/bare-metal seam.
- Declared error enums: `[error: FsError | NetError]` (LIST) in the effect
  bracket; enums are ordinary fieldless sums. Codes = errCode("Enum.Variant")
  FNV hash (ords would collide across enums). Effects ≠ errors — [io]
  propagation untouched.
- Raise: `return err FsError.NotFound` / bare `err AccessDenied` statement
  (early error return); shorthand resolved+validated against the declared
  list (ambiguity across enums = error, qualify). Dynamic re-raise
  `err r.err`. Checker rewrites shorthand to qualified for codegen.
- `expr?` propagation operator REMOVED (user ruling). Handling = result
  introspection: `.ok`/`.err` anywhere; `.value` ONLY inside that result's
  `if r.ok:` guard (scope-limited narrowing — outside the guard it's still
  wrapped; returning it where bare T expected still fails).
- Type wrappers now postfix too: `T?`, `T!`, `T?!` (== prefix ?/!/!?);
  lexer lexes `?!` as the !? wrapper.
- rt: TuckResult.val renamed .value (matches the language).
- 14-task rewritten to if-guard + err re-raise. 69 checker tests, gate 13,
  cli smoke, end_to_end green; runtime-verified both raise paths + ok path.
- Known gaps (backlog): SigInfo doesn't carry error lists yet (cross-module
  raise validation); `.err` typed Unknown (enum-typed comparisons later);
  narrowing only via `if x.ok` then-branch (no `not x.ok` continuation).

## 2026-07-10 — stdlib v1 + tuck build: real OS programs
- std/{fs,io,sys,time}.tuck: extern sigs over tuck_rt (Nim stdlib = the
  portable OS layer). Fallible fns declare [error: FsError]-style enums;
  rt impls catch Nim exceptions → terr(errCode("FsError.IoFailed")) —
  exceptions never escape. getEnv absent → tnone (tri-state).
- Import search path: importer's dir, then TUCK_STDLIB env, then std/ next
  to the compiler binary (and ../std for tests binaries).
- `tuck build` (b): compile + nim c to a binary; declared `fn main` gets a
  `when isMainModule: main()` runner; --nim:"..." forwards flags (the
  bare-metal path: --os:standalone --cpu:arm ...); dashed/digit-leading
  names sanitized (m_24_stdlib).
- examples/24-stdlib.tuck: writes + reads /tmp file, prints content —
  BUILT AND RAN as native binary. Gate 14/25. All suites green.
- Backlog noted: sig index skips stdlib-dir entries (always full-loads,
  msgpack module cache still applies); no int→str/interp for printing nums.

## 2026-07-11 — resource registry designed (spec §7.4, docs only)
- Design session: global per-kind resource registry replaces scope-RAII as the
  primary model for OS resources (fd-table mental model; RAII thrash in hot
  loops). Full design in spec §7.4; rulings condensed in ROADMAP.
- Key points: user-declared kinds via `resources:` block; `[resource: kind]`
  attr rides the effects bracket + propagation; u32 index+generation handles
  (Tier-1 values, refs stay in rt); `defer` = mark isFinished + on_finish
  (file: flush) + generation bump (handle dies at mark under every policy);
  close policy strict/lazy/exit mirrors errors decl; sweep runs INLINE in the
  defer-release code at watermark (~75%), all-finished or `sweep_batch: N` —
  no thread/actor, no refcount, NO time-based eviction; cap optional
  (seq-backed unbounded vs static array on standalone); scope-local static
  check (defer-mark or registry escape, escape always sound); debug
  OPEN RESOURCES report; LIFO close-all.
- Implementation = new Missing entry in ROADMAP (parser/checker/rt/codegen/
  report). Not started.

## 2026-07-11 — generics v1: simple substitution, lowered to Nim generics
- User ruling: usual Nim/C# generics — no variance, no HKTs, no constraints.
- Key design: Tuck does NOT monomorphize — codegen emits `proc f*[T]` /
  `type Box*[T]` verbatim and Nim instantiates (same move as errors riding
  effects machinery). Compiler work = parse + infer + substitute only.
- parser: `fn identity[T](...)` bracket between name and paren (new fnGenerics
  on dkFn); `type Box[T] = ...` — Uppercase-first ident disambiguates generics
  from lowercase attrs in the same bracket position.
- typecheck: FnSig/SigInfo carry generics (index path included); call sites
  infer bindings by unifying declared param types against payload field types
  (recursing tkApp/tkRecord), conflict = error naming both types; substituted
  params run through the existing arg checks; return type substituted at the
  call site (unbound params degrade to Unknown — gradual). Generic type
  aliases resolve through fieldsOf with substitution (Box[int].value: int).
  Generic fn BODIES are gradual: type params bind as Unknown (Nim rechecks at
  instantiation). Direct construction of a generic record = friendly checker
  error (needs type-directed lowering; Nim requires Box[int](...)).
- Runtime-verified: tuck build of Box[T]+identity[T] program → binary ran
  exit 0. 76 checker tests green (7 new), gate 14/25, cli smoke, end_to_end.
- Ceilings: no constraints (arithmetic on T in a body errors at Nim level
  only via instantiation), positional multi-arg path not generic, generic
  record construction blocked.

## 2026-07-11 — invariants: block syntax only (user ruling)
- `invariant:` block (one predicate per line) is THE form. Single-line
  `invariant: pred` member and `[invariant: expr]` attribute are parse errors
  with a pointer to the block form. The attr form was silently IGNORED by
  codegen (only body members reached validate()) — now impossible to write.
- Examples 10/15/20 + end_to_end embedded source rewritten to block form.
  Spec §4.7 rewritten (block-only, multi-predicate example); attr list in §4.6
  no longer mentions invariant. validate() emission verified on example 10.
- Auto-insert of validate() at construction/mutation/return/deserialization
  stays backlog (ROADMAP Partial).

## 2026-07-11 — invariants auto-inserted at production sites (spec 4.7, partial)
- Technique: not a search — production is syntactically local. Codegen asks
  "does this node's type carry invariants?" (hasInvariants set lookup) at the
  two crisp sites it already emits: record CONSTRUCTION
  (`(let t = T(...); validate(t); t)` paren stmt-list) and plain RETURN of an
  invariant-carrying named type (ctx.retInvName, set per fn; tail returns ride
  the existing rewrite-to-exkReturn path).
- validate() body now wrapped `when not defined(release):` — spec's "stripped
  in release" is real; verified: violating program aborts with "Invariant
  violated" in debug, runs exit-0 under --nim:"-d:release".
- cli_smoke gained both runtime cases (violation aborts / valid runs).
- Deferred (same blocker = type-directed lowering, codegen has no var-type
  env): mutation sites (`..` emission needs the rework anyway), extern/
  deserialization returns, !T-wrapped returns.

## 2026-07-11 — forth-style refactor: dispatchers read as tables of contents
- Nim skills loaded from ~/.agents/skills (code-organization/style/api-design).
- parseDecl 644→~50-line dispatcher (9 per-decl parsers; parseDeclAttrs killed
  a 4x duplicate, parseInvariantBlock a 2x); expression/type parsers split
  (wrapper merge, parseParenType/BraceType/TypeUseAttrs/StructLiteral/
  PostfixCall/AliasStep, tryUnsafeMarker 2x dedup).
- codegen genDecl 442→~45 (genFnDecl/genSumType/genTransitionProcs/
  genRecordType/genAliasType/genActor/genRegistry); genExpr arms →
  genCall/genConstruction/genReturn. Done by sonnet subagent.
- typecheck synthesize 313→126 (synthFieldAccess/Call/Binary/Chain/If/Match);
  checkDecisionTable left whole (two self-contained algorithms). Sonnet
  subagent.
- Extraction-only, all suites green per phase. Ledger:
  thoughts/ledgers/CONTINUITY_CLAUDE-forth-refactor.md (complete).
- Commits: b7f8af0, efcfb3a, ff9dfd3, 5721e91.

## 2026-07-11 — type-directed lowering: typed AST + the blockers it kills
- Expr.ty: checker stamps every expression's type in ONE place (synthesize
  wrapper — forth-refactor payoff). Codegen reads the stamp; ty==nil always
  falls back to old emission. No side-table (TypeChecker is the transient
  semantic object; side tables wait for stable node IDs / LSP).
- Record-var payload explosion: `p advance` → `advance(p.position, p.step)`
  (param order, field-name match — mirrors checker subset matching). exkVar
  args only (double-eval guard). Root cause found on the way: constructions
  `{...} TypeName` synthesized Unknown — now typed as their decl. Also fixed
  latent bug: struct-literal args in fn bodies were emitted in WRITTEN order,
  not param order.
- Generic record construction UNBLOCKED: checker infers T from payload,
  codegen emits `Box[int](value: 41)` from the ty stamp; uninferrable = error.
  Old v1 checker error removed; tests flipped.
- NOT done, with reasons named: mutation-site validate (blocked on `..`
  emission design — `x ..field {v}` emits setter-call `x.field(v)`, needs a
  ruling on mutation lowering); ex 18 (alias() restructuring, separate
  feature); ex 04/12 (sketch decl edits only, no compiler work).
- cli_smoke gained the explosion regression. All suites green. Commits
  096da30 + follow-up. Ledger: CONTINUITY_CLAUDE-type-directed-lowering.md.

Next candidates:
1. Type-directed lowering: expand record-typed vars at call sites + real alias
   restructuring (blocks 18, 04, 12; needs typechecker info in lowering).
2. `on select` lowering to task state machines (spec 9.2; blocks 14, 16).
3. Top-level statement semantics — implicit main? (blocks 11; note: example 11 still uses removed `or return` style, needs rewrite to 4.9 policy).
4. Extend checker: match exhaustiveness, distinct/unit types, generics.
5. Qualified pending names (http.get) so 14-task can stub module calls.
6. Validate Error.x names against a declared error enum (domain module).

## 2026-07-12 — Beef backend parity: emitter rewritten, compiles and runs

- `codegen_beef.nim` rewritten to mirror `codegen.nim` construct for
  construct: !T/?T/!?T -> `TuckResult<T>` with tok/terr auto-wrap (error
  codes FNV-hashed by the emitter, so Beef needs no comptime hashing),
  error policy (`tuck_unhandled` + dropped-result routing via
  shortcutSite), record ctors with named-field matching, param reordering,
  record-var payload explosion, invariant `validate` + `__validated()` at
  production sites, generic ctor instantiation from the ty stamp, pending
  stubs, packed + chained decision tables, payload sum types (Kind enum +
  carrier class), transitions (`canTransition`/`transitionTo`), actors
  with real message envelopes (params ride in the Msg, send helpers take
  them), registries, mixins/extern (`[CLink]` bindings; rt externs forward
  to the runtime), distinct types (wrapper struct + operators incl. `<=>`),
  unit sugar, alias/bake, qualified module refs via `emitBeefModule`
  (static class per module), hoisted inline enums, implicit tail returns.
  Record shapes hoist to `TRec_*` structs (Beef has no 1-element tuples).
- New Beef runtime `compiler/tuck_rt.bf` (namespace TuckRt): TuckResult,
  tok/terr/tnone/tfwd, Mailbox<T, const N>, BumpArena/ObjectPool,
  RegisterMMIO/Bit attributes, stdlib layer (fs/io/sys/time) mirroring
  tuck_rt.nim including its error codes.
- New `tests/beef_backend.nim`: feature assertions over all 25 examples +
  BeefBuild compile check for the same 14 examples nim check covers — all
  green, and the built 24-stdlib binary runs (`hello from tuck`).
  Requires BeefBuild (looks at $BEEFBUILD_BIN, /opt/beef/IDE/dist, PATH);
  skips the compile layer when absent.
- Emitter-only change: tuck.nim/parser/checker/lowering untouched;
  `emitBeef` grew an optional realModules param (default keeps the old
  call shape). All existing suites still green (compile_all_examples,
  end_to_end, typecheck, cli_smoke).

Next candidates (Beef):
1. Wire per-module .bf emission + a `build --beef` step in tuck.nim (the
   emitter and tests are ready; the CLI still emits entry module only).
2. exkList/exkFor coverage (16/17/20) once the Nim backend gets them too.
3. `or return` in expression position (statement position works).

## 2026-07-12 — stdlib bottom-layer catalogue (planning report)

- stdlib-blocks.md: ~95 building blocks across 17 domains (prelude/result,
  strings, bytes, bit intrinsics, integer semantics, atomics/volatile,
  interrupts/MMIO, fixed-capacity no_alloc structures, collections, math,
  random, time, raw memory, os/fs/process, sockets, actor messaging,
  diagnostics), surveyed from C/C++/Rust-core/Zig/Nim/Go/BEAM (no
  reflection/macros — metal-capable set). Each block classified:
  extern (direct) ~60%, extern (shim, exception→terr reshape) ~20%,
  write (rt) ~15%, write (Tuck prelude) ~5%. Every cited Nim symbol
  verified by nim-check probe (one fix: volatileLoad/Store live in
  std/volatile, not system).
- Open rulings named, not made: generic containers vs monomorphic extern
  (blocks Map/Set/Deque), collection call style, compiler-lowered vs rt for
  checked arithmetic, §7.4 resource kinds for fs/net sigs, bytes repr.
- ROADMAP points at the report from the stdlib ruling.

## 2026-07-12 — stdlib layer map (L0→L5) + layer-audit feedback into L0

- stdlib-layers.md: dependency-layer map modeled on how Go (import DAG),
  .NET (CoreLib→Stream→Sockets→Http), Rust (core→alloc→std) and BEAM
  actually stack: L1 protocols/composition (stream iface, bufio, builder,
  fmt-without-reflection, hash/eq/ord, errors-ctx, flags) → L2 pure
  algorithms (encodings, digests, compress, bigint, regex, tz) → L3
  structured data/net infra (url, textproto, json, crypto suite, dns) →
  L4 transport (tls-via-OpenSSL-wrap flagged, http, websocket, archives)
  → L5 app services (log, testing, supervision; config/template punted).
  Includes suggested build order; shared lesson: every reference lib
  inserts a thin protocol layer directly above the primitives.
- Gap audit fed back into stdlib-blocks.md §18: stream interface, hash
  protocol (hashes.hash), radix parse/format (toHex/parseHexInt et al),
  text builder, ctrl-c/posix signals, realpath — all probe-verified
  (fix found: posix.signal returns void; std/sha1 deprecated → digests
  reclassified write-or-wrap). New open ruling recorded: derive-style
  codegen for records (fmt/hash/json all block on it).

## 2026-07-13 — `tuck build --beef` wired into the CLI

- `--beef` on `compile`/`build` now emits every imported module as its own
  `mod_<name>.bf` (via `emitBeefModule`, was entry-module-only before) plus
  the entry `.bf`. `build --beef` additionally scaffolds a throwaway Beef
  project (BeefProj.toml/BeefSpace.toml, same shape as
  tests/beef_backend.nim's compile check), shells out to BeefBuild, and
  copies the resulting binary to `<binBase>_beef` next to the Nim binary —
  both backends' binaries coexist under distinct names.
- `findBeefBuild()`/project scaffold duplicated from tests/beef_backend.nim
  (BEEFBUILD_BIN env, /opt/beef/IDE/dist, PATH). BeefBuild absent → warns
  and skips the Beef step; Nim build still completes (never fail the whole
  `build` over an optional backend).
- Toolchain gap closed to test this for real: BeefBuild requires LLVM 22
  (not in Ubuntu Noble's repos, max 20) — installed via apt.llvm.org, then
  built BeefBuild from ~/apps/Beef (cmake+ninja, full Beef self-test suite
  ran clean). Verified end-to-end: `tuck build examples/24-stdlib.tuck
  --beef` compiles fs/io as separate .bf modules, links, runs, prints
  "hello from tuck" — matches the Nim backend's own verified output.
- cli_smoke.sh gained the coverage (skips the BeefBuild-required assertion
  when no toolchain is found, matching beef_backend.nim's convention).
  All suites green: typecheck, examples gate 14/25, end_to_end, cli smoke.

## 2026-07-13 — `.`/`..` semantics settled (user rulings) + implemented

- Design session produced THE call model (spec §2.3 rewritten):
  - Whitespace, `.name`, `.name {args}` are ONE call form, resolved
    semantically: fn's first param accepts the receiver whole (structural
    when unnamed) → whole-bind, braced args fill remaining params by name;
    otherwise the receiver's FIELDS fill the params (subset matching, the
    old `p advance` explosion). Whole-bind lives in checkCallArgs, so every
    call path shares it. Empty braces harmless.
  - `.name` on a struct WITH field `name` = field read; field + braces =
    error pointing at `..`. Ambiguity resolved by lookup, not syntax.
  - `..name {arg}` (var only): field set (payload = exactly one field —
    `{8080}` sugars to `{value: 8080}`, `{episode}` to `{episode: episode}`)
    or MUTATOR call — braced args pin method form, result reassigned into
    the var via the ordinary assignment check (must return receiver's
    type). Chain always continues on the base var. `..start` in the old
    spec example was a confirmed typo (start returns bool → `.start`).
  - `{expr}` with a non-ident single value parses as `{value: expr}`
    (parser sugar; parseBraceBlock now unreachable from that position).
- Implementation: Expr.exkField gained dotArg (parser consumes `{...}`
  after `.name`) + callNode; ChainStep gained callNode — checker stamps
  the resolved exkCall, codegen (Nim × both genExpr overloads + Beef)
  just emits it. synthMethodCall = the method-form checker (arg1
  compat, named rest, positional call node in declared param order).
- Parser bug found by runtime verify: multi-step chains nested one
  exkChain per step (base = previous chain) — codegen emitted garbage.
  Steps now accumulate on ONE node. Chains emit PRETTY multi-line Nim
  (`server.port = 8080` / `server = withPort(server, 90)`), exkChain
  added to the self-indenting node sets. Runtime-verified via exit code.
- Errors all explain the fix: field-with-args, let-mutation, non-mutator
  return type, arg1 mismatch, unknown name, wrong value type. 18-case
  battery ran against the checker (scratchpad/speccases) — outcomes match
  the model 18/18.
- examples/02-builder-mutation.tuck now REAL (decls + mutator + field
  sets), in BOTH gates: nim-check 15/25, Beef compile-check 15. Example 17
  gained its missing sketch fields (currentEpisode, lastPlayed).
- Suites green: typecheck (86), examples 25 + gate 15, end_to_end,
  cli_smoke, beef_backend (25 assertions + 15 builds).
- Backlog unblocked: mutation-site invariant validate() (ROADMAP row
  updated); purity enforcement for mutators via effects = future ruling.

## 2026-07-13 (later) — strictness screws tightened (user rulings)

- Field set takes ONE BARE value only: `..port {80}` or `..host {name}`
  (bare var). Named pair `..port {host: 80}` = error pointing at mutator
  fns. Shorthand detection: single payload field named "value" (brace
  sugar) or ident-shorthand pair (value expr is the same-named var).
- Either/or namespace: a declared field name may not shadow a declared fn.
  Two enforcement points: decl-time walk (record/object/actor fields vs
  fnSigs — error names both and says "rename one") + use-site guard in
  synthFieldAccess/synthChain (covers anonymous struct receivers the decl
  walk can't see). Caught a REAL clash: example 01's pending fn `episodes`
  vs the fetch-payload field `episodes` — fn renamed selectEpisodes.
- Spec §2.3: bare-value rule + either/or paragraph + 2 error-table rows.
- 90 checker tests green; all suites green (gate 15, Beef 15, e2e, smoke).
- Still open (user asked for plain-words explanation): whether the
  whole-bind-vs-field-explosion resolution needs an ambiguity error when
  a call could match BOTH ways (currently whole-bind silently wins).

## 2026-07-13 — examples campaign phases 1-6b (ledger: examples-all-green)

- Gate 15/25 → Nim 21/25, Beef 20/25 over six phases, each committed:
  chain-tail fix (8166bb7), variant construction + 09/12 (same), 04
  composition emission (2f2da87), alias() real (357f780), bake v1
  (56d66e1), input+merge (b3ac4a9). Details per commit / ledger.
- New spec sections: §2.3 rewritten (call model + error table), §2.4b
  (input + merge). bake follows the user's Factor-fry ruling with
  Nim-generic lowering (fn type → auto, :name refs, slot.invoke).
- Remaining 4: 11+20 (`when TARGET` + implicit main + actor-transition
  lowering), 16 (`on select`, behind actor-runtime ruling). Beef bake =
  delegate-type ceiling (03 Nim-only).

## 2026-07-13 — entry model settled: declarations only, main is the program

- User ruling (after discussion): NO top-level statements of any kind —
  not even pure lets. Module top level = declarations (import/type/fn/
  object/actor/mixin/registry/register/pool/errors/pending/extern).
  `tuck build` without fn main = LIBRARY build (emits code, no binary,
  clear message). Checker: dkExpr at module level = Structure Error
  pointing at fn main.
- Rationale: predictable startup (no Nim-module-init vs Beef-Main()
  parity-by-luck), effects discipline stays on fns, embedded-friendly.
- Migration: 6 examples (01, 07, 11, 12, 18, 23) + 18 checker-test
  snippets + end_to_end's embedded source wrapped into fn main; example
  11's dead `or return` line replaced with a sketch fn. cli_smoke gained
  the top-level-rejection + library-build cases.
- Spec §2.3b added. All suites green (gate 21/25, Beef 20, e2e, smoke).

## 2026-07-13 — const declarations (the compile-time-data carve-out)

- Ruling: after surveying Zig/Rust/BEAM precedent, `const name = <data>`
  joins the declaration set — strictly compile-time evaluable (literals,
  structs/lists of them, arith; no calls/constructions), validated by the
  checker with a pointer at fns/actors/registry for runtime values.
  Order-free (bound before body checks); Nim emits `const` in the type
  pass; Beef: literal→const, structured→static field. Runtime-verified
  (const + struct-const arithmetic exits 42). Spec §2.3b extended.

## 2026-07-13 — TOUR.md + TOUR-GAPS.md (probe-driven language tour)

- TOUR.md: 15-section tour of the working language, every "runs" snippet
  actually built/executed during writing. TOUR-GAPS.md: 10 gaps found by
  writing code the natural way first (user bar: any hoop counts).
  Top finds: no int→str/interp (can't print a number!), str + str emits
  invalid Nim, list-literal-of-constructions emitter bug, transitionTo
  ergonomics, .err never enum-typed at handling sites, const rejects
  unit sugar, match `:` vs decision `->` inconsistency, actors don't run.

## 2026-07-13 — static transition checking designed (spec 4.4b, not yet built)

- Started from TOUR-GAPS.md #4 (transitionTo ergonomics); design
  conversation surfaced a much bigger idea: the type system should track
  a var's possible variant SET through the checker's flow, and check
  reassignment-as-transition at compile time — the user never writes
  transitionTo for the common case. `Type@Variant` notation (compiler
  diagnostics only, never source syntax) names the narrowed type.
- Full ruling (session, condensed): applies to every transitions-declared
  type, independent of [sealed] (sealed only restricts direct-construct
  syntax to the initial variant — a much narrower, already-built rule).
  Merges (branch/loop) UNION the possible-variant set, never discard to
  bare Type. A transition against a set is legal only if the edge exists
  from every member. Fn boundaries: param/return types stay unnarrowed in
  signatures; the checker still carries the caller's known set into the
  callee body and traces constructible returns back out; untraceable
  returns yield the full set. Loops get NO special handling — body
  checked once against the entry set, no fixed-point/simulation; an
  illegal edge in a loop body fails regardless of iteration count.
  Unprovable = compile error, never a silent runtime fallback.
- Spec §4.4b written (tuck-spec.md). ROADMAP Missing item added — scoped
  as its own implementation pass (touches the checker's core binding/flow
  model), not folded into the smaller TOUR-GAPS fixes. Not implemented.

## 2026-07-13 — static transition checking IMPLEMENTED (spec 4.4b)

- Checker-only pass, ~150 lines: tc.varVariants tracks each var's
  possible-variant set for transitions-declared sum types. Reassignment
  (plain or `..` mutator) = transition, checked pairwise (every
  from-member -> every to-member needs a declared edge; same-variant =
  payload refresh, always legal). if/match fork the state and UNION at
  the join; loops check the body once against the entry set (no
  fixed-point, per ruling); match on a tracked var narrows the subject
  to the arm's variant inside that arm (variant patterns no longer
  shadow-bind). Params enter at the full set — transitions on them
  require match narrowing (the ruling's escape valve). Fn returns trace
  syntactically (constructions at return sites, module-local); anything
  untraceable = full set. Sealed interplay: RHS of a checked transition
  assignment may construct non-initial sealed variants (transitionCtx
  reused — static analogue of the transitionTo-chain exemption).
- FIRST RUN CAUGHT A REAL BUG: example 20's `on pause` attempted
  Idle -> Paused (not in its table) — invisible under runtime-only
  checking unless that message arrived in that state. Handlers rewritten
  in the static style (match-narrow + plain reassignment, transitionTo
  gone from the example).
- 8 new checker tests (legal/illegal edges, same-variant, branch-merge
  union both ways, param full set, match narrowing, return tracing).
  All suites green: 100+ checker tests, gate 21/25, Beef 20, e2e, smoke.
- Ceilings: cross-module fns yield the full set; helper fns constructing
  sealed variants outside a transition assignment still need [unsafe];
  match arms are single-line (parser limitation, hit twice today);
  optional debug-assert emission not done (checker proof stands alone).

## 2026-07-13 — match arms take indented blocks (parser limitation lifted)

- Match arm bodies were single-expression, same-line only (`pat: expr`) —
  hit twice during the transition-checking work. Parser now mirrors
  if/for: colon followed by newline → parseBlock (indented multi-statement
  arm), else the one-line expression. Example 20's play handler rewritten
  with block arms (side effects live inside the narrowed arm now — better
  style for the static-transition idiom). New checker test; all suites
  green.

## 2026-07-13 — const v2: Nim-static semantics (pure computed constants)

- User ruling: const copies Nim's static model — arbitrary pure
  compile-time computation, not a literal whitelist. Checker now rejects
  only what would break: [io] calls (pure only), record-type
  constructions (ref values — not const-able until value semantics),
  unknown callees. Pure fn calls, unit sugar (5.ms), computed tables all
  pass through.
- Codegen emits an explicit `static:` block (`const x = static: expr`) —
  and consts moved OUT of the type pass into source-order body emission
  (they may call fns; fns must precede them, Nim decl-before-use).
- Runtime-verified: `const sum = {a: 40, b: 2} plus` exits 42 (VM
  evaluated the call at compile time); `const timeout = 5.ms` builds and
  runs. TOUR-GAPS gap 6 closed. Beef ceiling unchanged (literal→const,
  else static field, static-ctor-time init).

## 2026-07-13 — typed error handling: match r.err + namespaced ids + tables

- `match r.err` fully wired (TOUR-GAPS #5 closed): result bindings
  remember their producer's declared [error:] enums (varErrTypes);
  match arms validate against them (typo + cross-enum ambiguity, same
  rules as raise sites) and are checker-rewritten to qualified names;
  codegen emits hashed id constants (`of errCode("mod/Enum.V")`) with an
  auto `else: discard` (uint16 space is never variant-covered). Runtime
  smoke: err-match branches to exit 42 through the hash comparison.
- Error ids namespaced per user ruling: hash input = "module/Enum.Variant"
  (origin module; imported enums carry origin on the <imported:name>
  marker). Both emitters + both runtimes updated (tuck_rt.nim strings,
  tuck_rt.bf hex constants recomputed). emitNim/emitBeef gained a
  moduleName param.
- Tables: program-wide compile-time COLLISION check (fnv16 mirror in the
  checker; a 16-bit collision between two error names = compile error
  naming both). Reverse table (id → name) emitted into builds with an
  errors decl — the generated tuck_unhandled prints
  "TUCK ERROR NAME: module/Enum.Variant" (smoke-verified).
- All suites green. Ceilings: `.err` equality comparisons (only match is
  typed); Beef reverse-table diagnostics (Nim only); SigInfo still lacks
  error lists (cross-module err-match falls back to untyped).

## 2026-07-13 — tour gaps 1-3: toStr, + as concat, list/for emission

- std/str.tuck: generic extern `fn toStr[T]({value: T}) -> str` over rt
  `$`/ToString — printing a number is one call now. Sig-block parser
  (pending/extern) learned generics brackets on the way.
- `+` on str = concatenation (ruling), routed through the rt layer
  (tuckConcat / Beef concat) instead of a hardcoded backend operator.
- TWO missing emitter arms found: exkList AND exkFor had no Nim-backend
  emission at all (fell to discard; 17's rewrite had dropped the only
  for-loop, so the gate never saw one). Both added (for = self-indenting
  statement, both overloads + block sets).
- cli_smoke: one combined program asserts concat stdout, toStr stdout,
  and a list-of-constructions summed via for (exit 42). Full matrix
  green. Seq API deferred to the stdlib traits session (user ruling:
  Rust-level traits/interfaces).
