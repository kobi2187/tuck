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

Next candidates:
1. Type-directed lowering: expand record-typed vars at call sites + real alias
   restructuring (blocks 18, 04, 12; needs typechecker info in lowering).
2. `on select` lowering to task state machines (spec 9.2; blocks 14, 16).
3. Top-level statement semantics — implicit main? (blocks 11; note: example 11 still uses removed `or return` style, needs rewrite to 4.9 policy).
4. Extend checker: match exhaustiveness, distinct/unit types, generics.
5. Qualified pending names (http.get) so 14-task can stub module calls.
6. Validate Error.x names against a declared error enum (domain module).
