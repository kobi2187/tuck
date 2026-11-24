# Compiler audit, phases 1 and 2: findings ledger

Six parallel reviewers, one per guarantee domain, each did its own inventory (phase 1)
and then adversarial bypass probes (phase 2) with the built compiler. This ledger merges
their reports. Repro programs are in `repros.tar.gz` (extract in a scratch directory;
paths below are relative to its root, e.g. `effects/fnsig/plain/t.tuck`).

**Evidence marks.** `V` = reproduced by me with `tuck ch` after the report (the checker
accepts the program). `R` = reported by a reviewer with a built-and-run repro, not yet
re-run by me. A finding is never listed unless its reviewer ran it.

**Severity.** S1 safety or identity bypass (checker accepts something its rules forbid, or
silent wrong or unsafe behaviour). S2 checker accepts, a backend rejects, or backends
disagree. S3 valid program rejected or compiler crash. S4 diagnostics.

Raw reports contain roughly 100 findings; many share a root cause. Below they are grouped
by the root cause, which is also the order I propose to fix them in.

## Status (updated as fixes land)

Each fix is at the root of its class, pinned in `tests/suites/known_bugs.nim`
(`bugFixed`, the repro as the assertion), and guarded by an invariant where one fits.

| Fixed | Pin | Invariant |
|---|---|---|
| E7 `main` privilege | A178 | `assertMainBudgetOnce` |
| T6 open-domain match, T7 match on a wrapper, T8a sealed bare variant | A179-A181 | |
| E3a restriction subset in conformance | A123 | one rule, `ast_ops.effectFitProblem` |
| Y9/Y10 operand kinds | A124 | |
| M9 two `fnsig Op`: each is its module's own (`type_identity`) | A125 | |
| Y17 body-spelled type edges | A126 | `typeEdgeErrors` covers body types |
| M3 const scope | A127 | per-module const table |
| E1 fnsig slots carry effects | A128 | `assertCallEdges`: a slot call has a contract |
| E3c interface calls in the restriction check | A129 | |
| E5 registry raise charges its handlers | A130 | `assertCallEdges`: a raise has a contract |
| E13 `..` step calls | A131 | `callSites`; edges checked for step calls |
| E10 invariants, E15 actor field initialisers effect-free | A132, A133 | |
| E12, E14 task restrictions; task calls get edges | A134 | `assertCallEdges` covers tasks |
| E6 `[pure]` touches no shared state; `[irq_safe]` does not wait (TK-EF12) | A135 | |
| E9 pending `[io]` members | A136 | |
| O1b `[writes: p]` on externs (`setAt`) | A137 | |
| O1c self-writes through an extern; views across them | A138 | |
| O5 member calls registered on every path | A139 | `unregisteredMemberCalls` |
| C3 slab ownership through slots, dispatch, predicates | A140 | |
| E2/M4 effect tables scoped per module by the checker's own scope | A141 | `typecheck.moduleScopes` is the one scope |
| M1 two files of one module name | A142 | `claimModuleName` at load |
| M2 `type`/`object` of one name; M8 two `group`s of one name | A143, A145 | `type_identity.Nominal` |
| M19 rename onto another import's name | A144 | |
| M13 a qualified extern call keeps its `[emit:]` (Nim reads it off the callee's declaration) | A147 | |
| M16, C12 actor member/handler names: every owner kept, the actor's own inside it, the module's fn outside | A148 | |
| M5 const/const and const/fn collisions across imports are explicit | A149 | |
| M6 a name with arguments in front is a fn call: the member the payload's `self` names, else own fn, else import's; a member is not exported as a module fn | A150 | |
| M21 imported tasks: task-ness from the call edge (`taskCallee`); the scheduler boots for the program's tasks, not the entry module's | A151 | |
| `mod::name` written bare is a value (const or nullary call); `:mod::name` is the reference | A152 | the id invariant caught the first draft |
| interfaces and actors of one name in two modules are told apart (`a::Logger send log`); an object's missing member is refused, not found on a namesake | A153-A155 | |
| M14 generic clones resolve names in the library's scope (a name the caller cannot reach is refused with the fix named) | A146 | |
| M7 a group requirement met in an imported module is found there (the receiver decides among imports); a generic group's provider keeps its arguments on Odin | A156 | |
| M10 a conversion to an imported alias, distinct or wrapping type names it through its module on Odin and D | A157 | the saturating-type constructor is looked up by the declared name |
| M17/M12 two spellings Nim folds to one (`my_val`/`myVal`) in one scope, or two module names, are refused on every backend: TK-TY50 (`name_fold.nim`) | A158 | |
| M18 `states:` is a type reference: ambiguous bare name is TK-TY47, `states: b::DbState` parses and resolves | A159 | |
| M24 a type written through its module (`{key: 4} a::Entry`, `a::Shape.Dot`) when only one module declares it | A160 | the parser read `{..} a::Shape.Dot` as `({..} a::Shape).Dot` |
| M20 mixins, pools, slabs, arenas, registers of one name in two modules are each their module's (type_identity) | A161 | a registry stays one per program (TK-RG05, by spec) |
| M23 a type named like a generated one (`<Pool>Handle`, `<Slab>Ref`, `<Arena>Ref`, `<Kind>Handle`) is refused: TK-TY51 | A162 | |
| M10b a module that renames at an import loads its imports from source, so a warm `tuck ch` agrees with a cold one | cross_module | |
| T1 a name narrowed on loop entry and un-narrowed in the body is checked un-narrowed on a second pass | A163 | |
| T2/T3 a write through a slab alias, `self ..f {v}`, or a call of the actor's own member ends field guards | A164 | |
| T10 TK-TY16 holes follow a parameter passed on, copied or returned, a partial local returned, a one-path fill and an assignment | A165 | (c16 was no bug: Tuck has no string interpolation) |
| O7 the arm's subject reassigned in its arm holds the new value's variant, for every sum | A166 | |
| O4 a copy is no final read when an overlapping place is first read in a later block (SSA `readAfter`) | A166 | |
| T8b/c only the construction a tracked assignment's transition produces may build a sealed non-initial variant | A167 | `transitionSite` replaces the flag |
| a group provider borrows its parameters (a generic body reaches it by name): Nim double-freed `keyOf`'s `self.s` | A156 | |
| T4 a result handed on (`return r`, `return f(..)`, `err r.err`) carries its producer's error enums, each of which the fn must declare | A168 | stdlib-project socket and net-http client now declare `NetError` |
| T5 a copy and a `mod::fn` result keep their error enum; with no knowable enum (a `!T` parameter) a bare capitalized arm is refused, not read as a catch-all binding | A168 | |
| T16 an arm after a catch-all, a variant matched twice, a misspelled variant and a literal against a sum are refused; `Door.Open:` counts as its variant | A169 | |
| T11 a decision row's literal has its input's type, its result the table's | A169 | |
| O1a a write through an element of a parameter or `let` (`xs[0] ..v {7}`, `xs[0].v = 7`) is refused | A170 | `mutationRoot` |
| O2 a call of the actor's own member ends views of its fields | A171 | |
| O3 a `for` whose body writes the walked collection walks a copy of it | A171 | |
| O6 a task owns its parameters: the caller hands over a copy or its last use, the task drops it | A172 | |
| C1 another actor's field read into a local is a copy, never a move | A173 | C2 (may it cross threads?) still open |
| Y12 a record literal under a stated named type is that type's construction | A174 | |
| Y13 a plain value into a `T?` is wrapped for a generic `T` field and branch by branch in an `if`/`match` value | A174 | |
| T14 `with` on a sum type is refused (spec: it replaces fields of a declared record) | A175 | |
| Y14 an imported extern's params are recorded, so extra payload fields are ignored (spec §2.5) instead of passed | A174 | the in-place `push` recogniser reads the exploded form too |
| Y2/Y3 division by zero, minimum `/i` -1 and out of bounds stop with a message and exit 1 on all three backends, as overflow and invariant traps already did (S3.1); `%` by -1 is 0; D flushes stdout before it stops | A176 | integer `/i` and `%` go through `tuckDivI`/`tuckModI`; Odin bounds checks no longer depend on `assert` |
| Y8 a `+ - *` chain STORED into a `[saturating]` type (`let`/`var` init, assignment, `+=`, field set, construction) is computed on a saturating 64-bit intermediate and clamped once, on every backend (spec 4.1); D builds it | A177 | `lowering_saturating` marks the stores (`Resolution.satStores`); a 64-bit base keeps the spec's stated ceiling |
| Overflow and division traps name the TUCK type (`i8`, not `int8`/`byte`): the emitter passes it, since D cannot tell `int` from `i64` | A177 | |
| Y15 `usize` is `size_t` on D; Y16 `0 .. top` with a narrow `top` names the type on both ends on Nim | A177 | |
| Y4 the minimum literal of a signed type (`-128` on `i8`, `-9223372036854775808`) is the type's minimum on Nim and D; a subnormal float literal is its exact hex form on D | A177 | |
| Y7 a float literal the checker typed `f32` is `'f32` on Nim; D float arithmetic on a literal no longer folds in 80-bit `real` (`0.1 + 0.2`) | A177 | |
| Y5 a const that divides by zero, or whose narrow-integer `+ - *` overflows, is a Const Error (it built on Odin only, stopping at start) | A177 | `int`/`i64` const overflow is Y1, untouched |
| An invariant violation reports the predicate as written and the type's Tuck name, one text on all three (it was each host's emitted code) | invariants suite | |
| Merge with main's registry rulings (2026-11-22): a synchronous raise is charged its handlers' effects (E5, confirmed 2026-11-23) only for handlers its own module sees; a queued event (`[stream]`/`[signal]`/`[latest]`) carries none; registries are no longer told apart per module (names are unique, TK-RG07); my shared-state rule moved to TK-EF12 (main took EF10/EF11); my A119-A122 pins renumbered A178-A181 (main's own A119-A122 kept) | A182 | the call-edge invariant skips a queued raise |
| C6/C7 stackless: a frame call on a path that may not run (value-`if` branch, `match` arm, right of `and`/`or`) is cut inside that path, not hoisted before the test; an operand left of a pause is pinned into a temp before it (`count + {ms: 20} nap`) | A183 | `stages.conditionalToTemp`, `hoistChildren`/`pin` |
| T15 (H) the SSA mirror walks a value that is control flow (`let z = match s:`, `return if ...`) by its blocks, not as one read; Odin's value `match` over a payload sum tests the variant through generated `S_is_V` procs | A184 | `ssa_build.walkValue` |
| C15 a task awaited from an actor handler builds on Nim stackless: the stage passes its frame's `tuckSlExit` to `tuckSlRet` instead of the runtime finding it by `mixin`, which `codeReordering` cannot see | A185 | |
| C8 `return err X` in a Nim stackless frame finishes the frame once (genRaise already did); C10 a written `<Pool>Handle` maps to the runtime's PoolHandle in every backend's type mapper (`resolution.poolOfHandleType`); C17 an actor with no handlers still has its singleton and member fns on Nim | A186 | |
| c_member/b a fn reference to an actor's member (`:bump`) is refused: it built on no backend, inside the actor or out (a bound method; recorded as a missing feature) | A187 | `failIfMemberRef` |
| C9 a stackless frame local takes its STATED type (`let o: Runner = o0`); a call through an interface whose member may wait runs on a helper stack (`stages.dispatchMayWait`) | A188 | |
| C14 main's `awaitResult` polls the reactor on every step on all three runtimes, so a task awaiting a sleeping child no longer hangs under stackful | A189 | |
| C13 `[queue: N]` holds per message under Nim's `--actors:batch` (room reserved per run against waiting + reserved messages, as Odin's batch mode): `on_full: drop` and `assert` now act | actor_mode suite | |
| C7 (Nim) a task's yield goes before the statement holding the [io] call, not inline (a statement-list expression Nim hoists ahead of the whole expression); a read of shared state left of a call is pinned first (`Counter.n + f()`, which C left unordered) | stackless suite: tests/stackless/paths.tuck | `genPinnedLeft`, `yieldsBefore` |
| I: E18/M11 an error raised in an imported module by a whole-program check (name folding, generated names, registries) names that module's file (`semantics.inModule`); Y19 TK-TY41 keeps the sign, a value `if`/`match` with a returning branch says so; TK-EF02 fires for any declared I/O marker on a body that does none; a block-bodied `if` taken as a value (statement form by R2) is refused, where it built to a wrong value on Odin and D | A190 | |
| M14 (end state) a clone of a library's interface-bounded generic calls the library's private fns and its own imports' fns, as written in the library's scope (`resolution.cloneReach`: named for the clone only, emitted exported, Nim imports the module `import nil`); the caller's own code still cannot name them. A requirement call in payload form inside a bounded generic is typed from the contract (A191) | A146, A191 | |

**Ruled 2026-11-24.** A value `if`/`match` may not have a branch that returns
(`let x = if c: 5 else: return 0`): refused, as it already was (pin A190, AGENTS.md §3).

**Waiting on a ruling.** E4 (does binding a task's result, an await, need `[io]` in the
caller?), E16 (`on select` arm budgets, F2), C18's second half (a predicate reading only its
own actor's fields; c_pred/a, b, d hang on Odin and D where Nim re-tests), the concurrency
items C2/C4/C5 (c_seqrace/r reads a torn `str` from another actor; c_poolrace/p and
r_res/race race a pool and a resource table), Y1 (int/i64 overflow policy), Y11 (generic
bodies: rigid type parameters, or re-checked per instantiation?), T13 (may a type parameter
bind a `T?`, so that `len` takes a `Seq[int]?` unguarded?), Y18 (`int` and `i64`: the
2026-08-25 ruling says they never need a cast, open bug A116 says the checker should refuse
the mismatch; today Odin returns 12 where Nim and D return 0 on types/mix1), T9 (spec
§4.4b rules out a loop fixed point for variant sets, so a transition legal on iteration 1 and
not on 2 passes), Y6 (what an out-of-range or NaN float `~int` gives: Odin 0, Nim and D the
minimum; and a constant one Nim and Odin refuse to build), Y8's other half (a `[saturating]`
chain that is compared, passed or returned rather than stored still wraps; spec 4.1 names only
stores), the precedence of `-128 Temp` (it is `-(128 Temp)`, so -127 on a saturating `i8`),
a value `match` whose arm is a multi-line block (the checker accepts it, no backend builds it: is the block's last line the arm's value, or is it the statement form, as a block-bodied value `if` is by R2/R3?), and two TK-TY16 holes the checker cannot follow: a partial record put in a
sum payload (un/c11) and a slab `new` that omits a field (sl2) — refuse the store, or track?

---

## Class A. Calls the checker cannot see (S1, the largest and most dangerous class)

The effect, ownership and slab rules are enforced per recorded call edge. Several call-like
forms never get an edge, so the rules do not apply to them.

| ID | What bypasses | Mark | Repro |
|---|---|---|---|
| E1 | A call through a `fnsig` slot (field, param or local) launders `[io]`; `[pure]`/`[no_alloc]` silently dropped; also loses suspend marking (two tasks interleave wrongly) | V | effects/fnsig/plain/t.tuck, effects/yield1 |
| E3a | Interface conformance subset rule inverted for restrictions: impl may allocate under a `[pure, no_alloc]` contract | V | effects/iface/t2.tuck |
| E3c | Interface member calls are `ckUnknown` in the restriction check | R | effects/iface/t7.tuck |
| E5 | Registry `raise` has no edge to its handlers; `[io]` handler effects launder | V | effects/registry/t.tuck, t2.tuck |
| E13 | `..` mutator chain steps are never resolved as calls (an `[io]` member runs in an unmarked fn) | V | effects/spell/s1d/t.tuck |
| E6 | `[pure]`/`[irq_safe]` ignore actor reads, `alive`, `waitUntil`, pool ops (TK-EF07 matches `exkSend` only) | R | effects/pure_state/t.tuck |
| E9 | `pending:` object members with `[io]` do not propagate | R | effects/pending1/t_c.tuck |
| E10 | A type invariant calling `[io]` is unchecked | R | effects/invariant/t.tuck |
| E11 | `[no_alloc]` is blind to implicit copies (`let ys = xs`) | R | effects/noalloc/c1.tuck |
| E12, E14 | Tasks ignore restrictions; imported tasks are not in `taskNames` (and do not link: M21) | R | effects/restr2/t2.tuck, effects/imptask |
| E15, E16 | Actor field initialisers and `on select` arms are not budget-checked (E16 is documented as pending ruling F2, not pinned) | R | effects/const2, effects/select1 |
| E4 | An unmarked fn awaits an `[io]` task (hidden yield point; `[pure]` is refused) | R | effects/task1/t.tuck |
| O1b | An explicit `setAt` call (void body-less extern) is never checked for write-through-parameter or write to a `let`; stale views follow | V | ownership/s10/a.tuck |
| O1c | A member whose only self-write is `self.recs.setAt {..}` is not classed as a self-writer | R | ownership/vw3 |
| O5 | A self-writing member in value position (`let r = h.bump`, `return h.bump`) is accepted on a parameter or a `let` | R | ownership/m6r |
| C3 | Slab ownership (TK-AC08/09) bypassed through fnsig callbacks, interface dispatch and `waitUntil` predicates | V | concurrency/c_slabown/a5.tuck, a6.tuck, c_slabpred/q.tuck |
| C18 | Spec says a `waitUntil` predicate is effect-free and reads one actor's fields, "checked rather than trusted"; nothing enforces it | R | concurrency/c_pred |

**Root cause.** `calleeDecl`/`assertCallEdges` cover ordinary calls. A call through a
fnsig slot, an interface, a registry raise, a chain step, an extern that writes, or a
predicate registered for another thread is resolved to nothing, and "nothing" passes.
**Fix by class:** every call-like node kind must either carry an edge or an explicit
conservative marker (a fnsig carries its effects as part of its type; an unresolvable call
requires the most restrictive reading); extend `assertCallEdges` to fail the build when a
call-like node kind has neither.

## Class B. Names where identity should be (S1/S2)

| ID | What | Mark | Repro |
|---|---|---|---|
| E2 / M4 | Effects and restrictions looked up by bare name program-wide, last writer wins; body fn vs extern clash is never "ambiguous"; the accepted state is written into `.tuck-cache` | R | effects/fncoll, effects/extbody, modules/eff1c |
| E7 | Any fn or member named `main`, in any module, gets main's full effect budget | V (`effects/mainpriv2/c.tuck`: `tuck ch` is OK) | effects/mainpriv2, mainpriv |
| M1 | Two modules with one file stem are one module (silent miscompile, exit differs) | R | modules/dupname |
| M3 | A private or non-imported const is reachable by bare name (Odin/D build and return it) | R | modules/m2.tuck family |
| M8 | `group` names collide across modules (last import wins) | R | modules/grp2 |
| M14 | Interface-bounded generic clones resolve bare names in the CALLER's scope | R | modules/ifg1, ifg2, ifg3 |
| M19 | `import ka {put -> putEntry}` hijacks `putEntry` exported by another import | R | modules/ren1 |
| M2 | Objects/interfaces/cross-kind types of one name in two modules get no TK-TY47; first copy wins | R | modules/typeobj |
| M9 | Two modules each declaring `fnsig Op` crash the compiler (KeyError) | R | modules/fnsig1 |
| M5, M7, M16/C12/E17 | const vs fn same name; local provider hides ambiguous imported providers; imported actor handler/member names poison same-named local fns (valid code rejected) | R | modules/coll1, grp1, eff2; concurrency/c_member/a.tuck |
| M13, M10, M21 | Qualified call drops `[emit:]`; imported alias/`[wrapping]`/`distinct` type fails on Odin/D; imported `task` does not link | R | modules/emit1, attr1, tsk2 |
| M6 | An object member named like an imported generic fn (`push`, `at`) shadows it for method calls | R | modules/mem1 |
| M17/M12, M18, M20, M23, M24 | Nim-style identifier folding collisions pass the checker; `states:` type names; singleton-name tables (mixins/pools); synthesised `XHandle` names shadow user types; qualified construction of non-colliding types | R | modules/style1, slug1, res1, mix1, gen2, qv |
| M10b | `check` fails after a warm cache where `build` passes (renames against the signature index) | R | modules/cache1 |

**Root cause.** About 24 checker-state tables and 11 resolution tables are keyed by a bare
string; a name is treated as an identity. **Fix by class:** key by declaration id (or
module id plus name), scope every lookup to the module's visible set, make `main`
privilege a property of the entry module's top-level fn, and make module ids path-based.

## Class C. Flow-insensitive narrowing and state (S1)

| ID | What | Mark | Repro |
|---|---|---|---|
| T1 | Narrowing of `r` survives a loop back edge (`s = s + r.value; r = none-able` in the body) | V | totality/t1/main.tuck |
| T2 | A slab reference alias defeats a field-path guard (`b = a; b.next = none; a.next.value`) | V | totality/t2 |
| T3 | Actor-field narrowing survives `self ..slot {none}` and helper writes | R | totality/t3, t4 (two variants) |
| T9 | Transition checking has no loop back edge (`Done -> Busy` on iteration 2) | R | totality/tr/c1 |
| T10 | TK-TY16 uninitialised-field holes launder through a second call, a return, a conditional fill, interpolation, slab `new` | R | totality/un, sl2 |
| O7 | Sum-type payload read after the scrutinee is reassigned inside the arm (Option narrowing is invalidated correctly; sum narrowing is not) | R | ownership/mt3 |
| O4 | A move (`var m = q`) judged final although `q.xs.len` is read later in a nested block (SSA carry across the edge) | R | ownership/mv2, mv3 |
| T8(b,c) | Sealed non-initial variants built inside a call argument on a tracked right-hand side; `transitionCtx` is one global flag | R | totality/s1, cx |

**Root cause.** Loop bodies are checked once against the entry state ("no fixed point, by
design"), and narrowing is keyed by a name path, not by the cell it denotes. **Fix by
class:** two-pass loop bodies (entry state joined with the back-edge state); alias-aware
invalidation for shared cells (slab/arena refs, actor fields); one narrowing implementation
for all three state kinds (optional, sum variant, uninit).

## Class D. Totality and exhaustiveness holes (S1, backends then disagree)

| ID | What | Mark | Repro |
|---|---|---|---|
| T4 | `err r.err` / `return r` propagates an error list that is not declared; nothing compares error lists (Nim fails, Odin returns, D throws) | V | totality/e1 |
| T5 | `match r.err` loses its enum for imported fns, copies, fields, fnsig results and `!T` params; unknown arms silently become catch-all binders | R | totality/imp_4, et4 |
| T6 | Match exhaustiveness skipped for inline sum types and for int/str subjects without `_` (Odin returns the wrong arm, Nim fails, D throws) | V | totality/x4, x6 |
| T7 | `match` on a `!T`/`T?` subject is accepted (silently discards the error); `discard r` is refused, so the two are inconsistent | V | totality/m1, mo |
| T8a | A bare payloadless variant of a sealed type is constructible (`return Locked`); the qualified form is refused | V | totality/bv2 |
| T11 | Decision-table row results and literal patterns are not type-checked | R | totality/dt5, dt6 |
| T16 | Qualified pattern `Door.Open:` not counted; a misspelled variant arm becomes a catch-all binder; duplicate arms and arms after `_` silent | R | totality/mt |

## Class E. Value-semantics and memory-safety holes (S1, silent reads of freed memory)

| ID | What | Mark | Repro |
|---|---|---|---|
| O1a | `x[i].f = v` and `x[i] ..f {v}` on a parameter or a `let`: `assignRoot` stops at the bracket; Odin and D mutate the caller's value | V | ownership/br5r/a.tuck |
| O2 | A view `let` is not invalidated by a member call that writes its source (double free on Nim, freed read on Odin/D) | R | ownership/vw4, av1 |
| O3 | The `for` binding is a view and the body may mutate the walked Seq (Nim assertion, Odin hang, D wrong result) | R | ownership/fr1 |
| O6 | A fire-and-forget task borrows the caller's buffer while the caller keeps mutating it (Nim segfault); contradicts "a task owns its parameters" | R | ownership/tk1, tk2 |
| C1 | Odin: reading an actor `str`/`Seq` field into a local aliases it then drops it (segfault) | R | concurrency/c_seqrace/s4.tuck |
| C2 | The documented "safe" cross-thread public-field snapshot is torn or use-after-free | R | concurrency/c_torn/p.tuck, c_seqrace/r.tuck |
| C4, C5 | A top-level pool and the resource registry table have no cross-thread ownership rule and are unlocked | R | concurrency/c_poolrace, r_res/race.tuck |

## Class F. Type-system escape hatches (S1/S2)

| ID | What | Mark | Repro |
|---|---|---|---|
| Y11 | A value of generic type `T` fits any slot inside a generic body; each instantiation is rechecked only by the backend | V | types/gp1/t.tuck, types/chk/h2.tuck |
| Y12 / T12 | A bare record literal under a stated named record type is accepted, built by no backend (TK-TY45 only covers call arguments) | V | types/rec1/t.tuck, totality/an1 |
| Y9, Y10 | Unary `-` and binary operators are not checked for operand kind (`not 5`, `5.5 % 2.0`, `true < false`, `Seq < Seq`) | R | types/neg2.., ar_a.. |
| Y13 | A plain value into an optional list element or `if` branch is not wrapped | R | types/opt2, opt3 |
| Y14 | Extra payload fields to an extern are forwarded as extra arguments | R | types/ex3 |
| T13, T14 | Generic parameter instantiated with a wrapper type bypasses the operand check; `with` on a sum type accepted | R | totality/lenopt, w1 |
| Y18 | A116 is wider than arguments: `int`/`i64` interchangeable in arithmetic, comparison, lets | R | types/mix1 |

## Class G. Backends disagree at run time (S2)

| ID | What | Mark |
|---|---|---|
| Y1 | `int`/`i64` overflow traps on Nim, wraps on Odin and D (docs say unchecked) | R |
| Y2 | Division by zero / MIN `/i` -1 exit code differs per backend (Nim 1, Odin 132, D 136); policy says exit 1 | R |
| Y3 | Out-of-bounds exit differs (Nim 1, Odin 132, D 134); D loses buffered stdout | R |
| Y4, Y5, Y6 | Literal edges (`i8 = -128` on D, `i64` min on Nim), constant overflow, float-to-int casts: accepted by the checker, different or failing per backend | R |
| Y7 | `f32` arithmetic with a float literal computed in `f64` on Nim | R |
| Y8 | `[saturating]` arithmetic does not saturate (only the `N Sat` constructor clamps); D does not build | R |
| Y15, Y16 | `usize` does not exist in D; `for i in 0 .. top` with `top: u8` fails on Nim | R |
| C6, C7 | Stackless hoists a frame call out of short-circuit, `if` and `match` arms (dead-branch side effects) and evaluates earlier operands after the pause | R |
| C13 | `--actors:batch`: Nim ignores `on_full: drop` and `assert` | R |
| C8, C9, C10, C15, C16, C17 | Nim stackless `return err X`; frame local with interface annotation; pool handle names unmangled; `tuckSlExit` undeclared; `waitUntil` hang under `--actors:single`; actor with fields and no handlers | R |
| C14 | Stackful hangs when a task awaits a child task that sleeps (stackless works) | R |

## Class H. Compiler crashes (S3)

| ID | What | Mark |
|---|---|---|
| Y17 = T15 | `var xs: Seq[Point] = [{x: 1}]` asserts at `lowering.nim:60` "no edge" | R |
| T15 | Assigning the matched subject in its own arm: "SSA mirror is malformed"; Odin `match` expression over payload sums: `Undeclared name tuckˑtypeˑSessKind` | R |
| M9 | Two `fnsig Op` (KeyError, above) | R |

## Class I. Diagnostics (S4)

E18/M11 (errors inside an imported module reported against the entry file); M22 (no description survives beyond the id; not reproducible as written); Y19
(TK-TY41 drops the sign; diverging branch in value position refused with "int vs unit");
TK-EF02 only fires for a bare unused `[io]`.

---

## Proposed order of work (fix by class, one invariant per class)

1. **Class A.** Call-edge completeness for every call-like node, fnsig effects as part of
   the type, extern write-through checks (`setAt`), conservative reading of the unresolvable.
   Invariant: extend `assertCallEdges`.
2. **Quick, low-risk S1 fixes** in the same pass: E7 (`main` privilege only for the entry
   module's top-level `main`), T6/T7 (closed domains, match subject handled), T8a, E3a (invert
   the restriction subset test), Y9/Y10 operand kinds, M3 const visibility, M9/Y17 crashes.
3. **Class B.** Declaration-id keyed tables and scoped lookups; path-based module ids.
   Invariant: a debug check that no bare-name lookup crosses a module boundary unscoped.
4. **Class E and C.** Views and borrows (`assignRoot` through indexes, member-call writes,
   `for` bindings, task parameter ownership); two-pass loops and alias-aware narrowing.
5. **Class F (Y11).** Generic bodies checked with rigid, opaque type parameters instead of
   "flexible" ones (or rechecked per instantiation like interface-bounded generics).
6. **Class G.** Decide the numeric and trap policy once (overflow, division, bounds, exit
   codes) and add a differential harness: whatever the checker accepts must build and agree
   on all three backends; add it to CI.
7. **Class D, H, concurrency rules (C1-C5, C18).** Per-finding, with the C-rules needing a
   language decision (cross-thread reads of multi-word fields, pool/registry ownership).

## Method notes and coverage gaps

- Reviewers covered effects, ownership/value semantics, totality, modules and names,
  type system and numerics, concurrency and regions. Not yet audited: the parser and
  rewrite stages, lowering passes as a group, the optional `-O` passes, the three runtimes
  against a written contract (#106), and the signature cache beyond the cases in M4/M10b.
- Slabs and arenas, task spawn in a loop, and `with` on registers were flagged unprobed.
- Findings marked `R` should be re-run by whoever fixes them; the repro commands are in
  the reviewers' helper scripts inside the archive (`run3.sh`, `q.sh`, `run6.sh`).
