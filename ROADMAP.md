# Tuck Roadmap (as of 2026-07-09)

---

# THE WORK QUEUE — ordered by dependency, 2026-09-22 (revised)

**Read this section first.** Everything below it is the standing rulings
ledger and the per-feature status table; both remain authoritative for what
was DECIDED. This section is the only thing that says what to do NEXT.

Ordering rule, set by the user:

> priority to finish features, and higher priority for the SSA fixing mem
> leaks. Features completely missing leave for later.

And the architectural rule the user set later the same day, which turned out
to be the thing most of the queue depends on:

> for unique features we should run a lowering pass, the rewrite pass,
> instead of doing it in codegen.

---

## The shape of the remaining work

The first version of this queue listed work by priority tier. Doing it showed
the tiers are not independent — most of them hang off ONE spine:

```
   M1  SSA: switch to the Braun builder, built once, stored
        │
   M2  Stage C: the copy decision read off the mirror, before lowering
        │
   M3  one ownership pass, before the clone, for every backend
        │
   M4  unique features LOWERED, not decided in codegen
        │        (decision tables, actor dispatch, interface dispatch)
        ▼
   backends are printers
```

Every bug class found this session was the same bug: **one decision, several
copies, kept in step by hand.** The twin predicate in two layers. The free
rule in two files. The `str` analysis a second copy of the `Seq` one — which
shipped a use-after-free. The backend-prep sequence written out four times,
already drifted. Decision tables built three times in three backends. The
spine is what makes that class impossible rather than fixed case by case.

The side work — wrong answers, partial features, parity, effects — mostly
does NOT depend on the spine and can be interleaved whenever the spine is
blocked on thinking. Where an item gets cheaper once the spine lands, that is
marked, so it is not done twice.

---

## Where it stands — done 2026-09-22

- **Odin's threading-chain leak is closed.** `world_server` 551 MB -> 10 MB;
  Odin is now the lowest-memory backend of the three on both applications.
  Guarded in `known_bugs`. (#82)
- **A shipped use-after-free fixed**: a returned `str` was freed by the body
  that built it. Guarded with `hostRuns` on OUTPUT, not exit code.
- **The ownership decision left the emitter**: `analysis_ownership.nim`, six
  numbered steps, with `freed` recorded per decision and three invariants
  asserted on every build.
- **Braun SSA built and measured**: `ssa_ir` / `ssa_build` / `ssa_query`.
  Against the old mirror across the corpus, both apps, Savina and stdlib:
  `agree=646 onlyNew=0 onlyOld=2 structural=0`. NOTHING CONSULTS IT YET.
- **`backend_prepare.nim`**: the four copies of clone/rebase/lower/mark are
  one pass. `verbose.nim` extracted with it.
- `docs/ownership-and-ssa.md`: the design, and seven numbered mistakes.

---

## M1 — Finish the IR spine: switch to the Braun builder

The rebuild agrees with the old mirror on 646 of 648 final uses and is never
unsafe where it disagrees. Finishing it retires two passes and fixes the two
design mistakes that are correctness bugs rather than performance ones.

| # | item | size |
|---|---|---|
| 1.1 | ~~Account for the last differences~~ **DONE 2026-09-22.** `finalUses` follows the BUFFER from each read (ssa_query header); every remaining difference against the old mirror is listed in the commit messages and justified | S |
| 1.2 | ~~Build once, store beside Resolution~~ **DONE 2026-09-23.** `ssa_cache.ssaOf(res, d, stage)`, stored in `Resolution.ssaGraphs` per (decl, `ssChecked`/`ssLowered`), with `finalUses` cached beside it. world_server for Odin: 129 builds -> 55 (19 bodies checked + 36 lowered, each once). A fingerprint of every node kind and every indexed node id is asserted on each fetch — it caught nothing real, and caught a deliberate rewrite | M |
| 1.3 | ~~Switch consumers onto `ssa_build`~~ **DONE 2026-09-22.** Zero diff under `examples/`; both apps emit byte-identical Odin. SSA goldens in `tests/ssa/` (`tuck ssa`) | M |
| 1.4 | ~~Delete `analysis_ssa.nim`~~ **DONE 2026-09-23**, with its differential tooling. `analysis_liveness` stays as the oracle (`--verify-stages`, on by default) one release longer, then goes too | S |
| 1.5 | ~~Fix #21~~ **DONE 2026-09-23.** Two causes: the checker built named types bare (now `typecheck_collect.namedType`, edge at birth), and `resolveTypeTo` silently returned on a declaration with no id — which every injected IMPORTED type was. Lowering's by-name fallback is now an assertion; it found the second cause on its first run | M |

**Exit: REACHED 2026-09-23.** One SSA implementation (`ssa_ir` / `ssa_build` /
`ssa_query`), built once per body per stage (`ssa_cache`), goldens in
`tests/ssa/`. Next on the spine: M2.

## M2 — Stage C: the copy decision on the mirror

**Exit REACHED 2026-09-25** by the route below, not by 2.1-2.3 as written:
#77's pin is green (482 MB -> 1.8 MB). The missing fact was which proc a
call REACHES — the wrapper copies the moved parameter, the twin hands back
an argument the caller gave away — and what the argument is, asked inside
its enclosing body (`analysis_provenance.throughWrapper`, `provCtxFor`).
The copy pass now RECORDS its exclusive decisions (`decidedExclusive`) and
the ownership pass reads them rather than re-deriving them. 2.2 and 2.3
still stand, as the prerequisite M3 names: ownership cannot move before the
clone while the copy decision is made after lowering.

| # | item | size |
|---|---|---|
| 2.1 | Move `exclusivelyOwned`'s ORIGIN half onto the mirror. The collision half already moved and was measured irrelevant (`ssaExclusiveOwned`, 27/27, never reached) — do not redo it | M |
| 2.2 | ~~Remove `afterBinding`'s emitter prediction~~ **DONE 2026-09-25.** The prediction was the emitters' "no copy for a read through the moved parameter" — which was itself a value-semantics bug (D returned 99, Odin read freed memory). The emitters now print the copy marks and nothing else; the one special case left is `movedTransfer`, a copy-pass predicate provenance shares | M |
| 2.3 | ~~Run `markSeqCopies` before lowering~~ **MOOT.** It was M3.1's prerequisite; M3.1 turned out not to need it (below) | — |

**Exit:** #77's own pin (`known_bugs.nim` A19, 64 MB, `bugOpen`) goes green
and the suite says to flip it. The remainder of #77 is a REDUNDANT COPY
(`tuckSeqCopy(bump(xs))` copying a buffer `bump`'s wrapper already allocated
fresh), which is exactly the copy decision this milestone moves.

## M3 — One ownership pass, before the clone, for every backend

Measured, not assumed: running `analysis_ownership` before the per-backend
deepCopy TODAY is a double free, because two of its inputs — which call sites
became twin calls, and which bindings copy — are established by lowering. M2
removes that dependency.

| # | item | size |
|---|---|---|
| 3.1 | ~~Move the pass before the clone~~ **DONE 2026-09-25, as step 6 of `prepare`.** `lowerModule` takes no backend and a build targets one, so "before the clone" was never needed — what was needed was a PASS: `decideOwnership` runs after lowering, the copy marks and `fillIds`, records a decision per fn id, and the Odin emitter asks `ownershipFor` (asserted present). It had run inside the emitter, twice per fn, with provenance rebuilt a second time at emit. The assertion found member fns emitted as id-less copies on its first run | S |
| 3.2 | ~~Assert no use follows a free~~ **DONE 2026-09-25, as a BUFFER check** (`buffer_check.nim`, asserted inside `ownershipOf` on every Odin build): each value's heap slots are mapped to the buffers they may denote — parameter slots, copied vs uncopied bindings, fields, phis, moved calls — and no buffer may be released by two free sites, nor released at exit and returned. Per-VALUE `freedAt` was the plan; buffers are what several names share, which is where all three bugs found on 2026-09-25 lived. Verified to fire on two of them with their fixes reverted. The one it cannot see is statement ORDER (a free emitted before the right-hand side that reads it) — fixed at the emitter, and guarded by a runtime test | M |
| 3.3 | ~~Fold the `str` analysis into the one pass~~ **DONE 2026-09-25.** A `str` local is a value with one slot: it dies at scope exit by step 4's rule and its escape is the same query as a `Seq`'s (3.4), asked with the `str` rule. What stayed backend-specific — which runtime calls hand back storage the caller owns — is a parameter (`backend_prepare.ownedStrProcs`), and `ownership_str.nim` holds only that. The second walk, with its own copy of the sealing rules (the copy that shipped M7's use-after-free), is gone | M |
| 3.4 | ~~Replace the per-slot full-body walk with a lookup over the mirror's `uses`~~ **DONE 2026-09-25** (`ownership_escape.nim`). One walk per body indexes each node's parents; a slot escapes when a use of it sits under a node that carries it out. Its premise is asserted on every build: every read of a name in the tree is a use in the graph — that is what makes the lookup answer what the walk did. Run as a differential against both old walks over every corpus file and the whole suite before they were deleted: 0 disagreements. The assertion's first run found a read the lookup could not place: `lowering_recursive` resolves `e.left` to `tuckAt(<a fresh copy of e.left>, 0)`, and the copy is not in the tree — a resolved call's arguments are now indexed where the call is printed. On the way: the builder dropped the arguments of an unresolved `b.fn {xs}` (a missed read), and both old walks read `returnVal` off a `raise` | S |
| 3.5 | ~~The twin-call decision is still made while printing~~ **DONE 2026-09-25** (`twin_calls.nim`, step 7 of `prepare`). The pass records which calls take the moved twin and which assignments thread through one; the Odin and D emitters ask `callsTwin` / `threadedCall`, and `movedCallInto`, `movedCalleeName` and `selfThreadedCall` are gone from `codegen_common` (`ownsHeap` moved down into `twin_shape` so a pass can ask it). A member call's receiver is derived one way, D's. Every node an emitter asks about is asserted VISITED: its first run found checker-stamped calls with no id (`server.start` as `start(server)`, now numbered by `fillIdsIn`) and actor handlers the `allFns` walk never entered — each a silent "no twin" before. Zero diff under `examples/`; both apps emit byte-identical Odin and D | M |

**Exit:** closes #80 / F27. One ownership analysis. After 3.5, what #80 still
lists is its Stage 4 — a growable `str` representation on Odin and D — which is
a missing feature, not a partial one, and moves to its own issue.

## M4 — Lower unique features; codegen only prints

The user's rule, applied. Each item deletes code from THREE backends and makes
the construct visible to every pass that runs before codegen — the SSA builder
could not see a decision table's structure for exactly this reason.

| # | item | deletes | size |
|---|---|---|---|
| 4.1 | ~~**`exkOrdinal`**~~ **DONE 2026-09-25.** "The ordinal of this enum or bool value": Nim `ord(x)`, Odin `int(x)` or `(x ? 1 : 0)` for a bool, D `cast(long)(x)`. Every exhaustive `case` over ExprKind took an arm; the checker types one as `int` though a checked tree never holds one | — | S |
| 4.2 | ~~**Decision tables lowered**~~ **DONE 2026-09-25** (`lowering_decisions.nim`, run by `lowerModule` for every backend): packed -> a `match` over the key whose grouped keys are an or-pattern (`of 2, 3`), chained -> an `if` chain ending in the catch-all the checker demands; one outcome -> a bare `return`. The emitters had drifted — D packed a table of ANY size where Nim and Odin chained above 4096 combinations — and the checker kept its own copy of the combinatorics; both now read `decision_table.nim`, whose threshold the lowering depends on (a table the checker enumerates is one that packs; the rest have a catch-all). `genPatternStr` printed any pattern kind it did not know as `_` — an or-pattern would have become a catch-all in every backend; it is exhaustive now. Guarded by `tests/suites/decision_tables.nim` (both forms run on all three) | `genDecisionTable` ×3 — gone | M |
| 4.3 | **Actor dispatch lowered** to an ordinary `match` over the message tag, each arm its own scope. **#79 is fixed separately (2026-09-25)**: two lines per backend (Nim and Odin now scope `definedVars` per arm, as D did), guarded by `actor_result` on all three. A full lowering needs the message ENVELOPE — each backend's own type — represented in Tuck first, which is design work; the bug was not worth leaving open for it | — | M |
| 4.4 | ~~Interface dispatch lowered~~ **DONE 2026-09-25** (`lowering_iface.nim`, in `prepare` after `lowerModule`) — to its own node, `exkIfaceCall`, NOT a `match`: the call sits in value position, where Odin's match is a ternary chain that binds no payload and evaluates the receiver once per arm, so a `match` would first need every value-position dispatch hoisted to statements. The node carries the receiver and one arm per satisfier, each an ordinary typed member call on the payload; the satisfier set, the member and its positional args are decided once, and each backend prints only its switch (a Nim `case` block, an Odin closure typed with the CALL's type, a D lambda). An unlowered interface call reaching an emitter is an assertion. `satisfiersOf` / `findObjectMember` moved to `ast_query` | **#40** closed (Odin's closure typed `-> int`), and with it `known_bugs` #17 / MISSING-FEATURES A6 (an enum return) | M |
| 4.5 | ~~`..` chains fully lowered~~ **DONE 2026-09-25** (`lowering_chains.nim`, absorbing `hoistChainCalls`). A builder becomes one assignment per step and a closing `exkValidate` (steps are `inChain`, so an invariant is checked once, at the end, as before); a chain whose value is used runs on a temp; a fn's tail chain returns its base. The step's call is copied with fresh ids, since `res.stepCall` is shared by all three backends. `pipeline.assertChainsLowered` checks no chain survives. A BOUND chain was wrong on all three, three different ways — Nim's temp lost a field step, Odin emitted a syntax error, D wrote through the base — and is now one program (`object_composition`). Found on the way: Nim's `quit` clamps an exit status to int8 (main returning 132 exited 127 on Nim alone), now the low byte everywhere | `genChain*`, `genDChain*`, `chainSteps`, `threadReceiver` — gone | S |

**Exit:** `genDecisionTable`, the actor dispatch builder and the interface
closure no longer exist in any `codegen_*.nim`.

---

## Side work — interleave; mostly independent of the spine

### S1 — Silent wrong answers in features that exist (do early; each is small)

| # | issue | | size |
|---|---|---|---|
| — | **#87** | **FIXED 2026-09-25** — actor field initialisers are kept and checked (TK-TY29); on `type`/`object` fields refused (TK-TY30) | — |
| — | **#73** | **FIXED** in `8d5b6c6` — a const resolves across the program (`ast_query.constDeclFor`); guarded in `cross_module`. This row was not updated at the time | — |
| — | **#78** | **FIXED 2026-09-25** — the prefix keeps the first letter's case (`Tuck_Order`, `tuck_order`); `compiler/name_prefix.nim` | — |
| — | **#79** | **FIXED 2026-09-25** — per-arm scoping in the Nim and Odin dispatch; see M4.3 | — |

### S2 — Finish partial features

| # | issue | | size | depends on |
|---|---|---|---|---|
| — | **#72** | **FIXED 2026-09-26** — the checker takes an `Array`'s element from its second argument and lowers `a[i]` to the runtimes' existing `tuckArrayAt`/`tuckArraySetAt` | — | — |
| S2.2 | **#45** | `pool.acquire` hands out a copy, so a pool cannot be a DMA target | M | — |
| S2.3 | **#42** | pool invariant validation | S | S2.2 |
| S2.4 | **#85** | extend `<uninit>` to actor fields | S | S1.1 |
| S2.5 | **#55** | a fired `timeout` answers right at 100× the deadline | M | — |
| S2.6 | **#15** | typed select sources, task form; unblocks `examples/16` | M | — |
| S2.7 | **#20** | by-type payload matching for member calls | M | — |
| S2.8 | **#36** | `mod::Type` in a type position | S | — |
| S2.9 | — | a BINDING match arm (`other: other + 1`) checks clean and then fails to build on all three backends: Nim emits the name as a `case` label, Odin and D print an undeclared `other`. Found 2026-09-25 probing the SSA builder's pattern bindings, which model it correctly | S–M | — |

### S3 — Backend parity (what survives M4)

| # | issue | | size |
|---|---|---|---|
| S3.1 | **#43** | Odin invariant guard + `--odin:`/`--dmd:` passthrough | S + M |
| S3.2 | **#30** | D: volatile registers, `[saturating]`, `tuckConcat` | M |
| S3.3 | — | the D runtime has no networking; `42-net-echo` cannot link | L |
| S3.4 | **#31** | the flake is Odin's own LLVM verifier; pin the Odin version | S |
| S3.5 | — | **runtime speed parity, found by `benches/memory` (2026-09-25).** Memory is flat on all three; TIME is not: copy_loop Nim 12 ms vs Odin 97 vs D 372; chain Nim 4.6x Odin; overwrite/transfer D 8–11x the others. Causes unconfirmed — see `benches/SCORES.md`, which also has the same programs with the collectors OFF | M |
| — | **#40** | **FIXED 2026-09-25** by M4.4 | — |

### S4 — Effects

| # | issue | | size |
|---|---|---|---|
| S4.1 | **#64** | wire `[no_alloc]` and `[irq_safe]`. Only `emIo` has checker logic today; #62/#63/#65/#67 all wait on this | M |

### S5 — Stage-boundary debt

| # | issue | | size |
|---|---|---|---|
| — | **#21** | *moved to M1.5* — it is on the spine | — |
| S5.1 | **#22** | `callParamsFor` for pending fns, distinct ctors, combinators | M |
| S5.2 | **#23** | superlinear emit; closes as a consequence of #21 + #22. Nim is already linear | — |

### S7 — Kind-scoped mangling (user proposal, 2026-09-22)

Mangle by DECLARATION KIND: `tuck_fn_`, `tuck_type_`, `tuck_const_`, ...
rather than one `tuck_` for everything.

Why: Nim identifiers ignore case and underscores after the first character,
so `fn at` mangled to `tuck_at` IS the runtime's `tuckAt` — the module
rebinds every `xs[i]` to the user's fn. Today that is patched per name:
`mangle.RtFoldableIntrinsics` lists the intrinsics a user name could fold
into, and those names alone get `tuckfn_`. A kind prefix makes the collision
structurally impossible — `tuck_fn_at` folds to `tuckfnat`, which no
intrinsic is — and deletes the list, the special prefix, and the second
spelling `assertMangleIdempotent` has to accept.

Cost: every emitted identifier changes, so `examples/` re-emits in full and
every golden re-blesses. Do it as its own change, with nothing else in the
diff, so that diff is reviewable as "renames only".

| # | item | size |
|---|---|---|
| S7.1 | Prefix per decl kind in `mangle.nim`; drop `RtFoldableIntrinsics` and `FoldSafePrefix` | S |
| S7.2 | `assertMangleIdempotent` checks the kind's own prefix, not any prefix | S |
| S7.3 | Re-emit `examples/`, re-bless goldens, read the diff as renames only | S |

### S6 — Rulings (your decision; the code is small)

**#4** attribute names outside brackets · **#5** a fn with no `->` ·
**#6** none needed, spec §8.1 already says · **#84** an initialisation barrier
between two senders · **#7** full-mailbox policy.

### Deferred — completely missing, not scheduled

`arena` (parses and discards its body — give it a DIAGNOSTIC now, fifteen
minutes, so it stops checking clean) · #12 hashing · #11 recursive types ·
#10 correlation tokens · #16 numeric sigils · #17 · #32 · #33 · #57 ·
#66/#68/#69/#70 · #71 · #74 · DNS. And **#18 generic actors is closer than its
issue says** — `actor Inbox[T]: xs: Seq[T]` parses now that #52 is closed.

---

## How to work on this without wasting the day

- **The full suite is slow (~6 min). Do not run it per change.**
  `./quick-test.sh` (~13s) for the inner loop, `./tests/run <suite>` for what
  a change touches (`ssa`, `known_bugs`, `value_semantics` for memory work),
  and the full run before a PR goes up.
- **Test first, the normal way.** Write the assertion, see it fail for the
  right reason, fix, see it pass. Prefer careful code and `doAssert`
  invariants over hunting bugs after the fact.
- **Fix a bug where you meet it.** Routing round a known bug leaves two; #21
  was nearly worked around and would still be open behind the workaround.
- **Differentials, not guesses.** Replacing an analysis, run old and new
  side by side over the corpus and account for every disagreement, split by
  "never saw the read" vs "saw it, judged differently". The Braun rebuild's
  bugs were all found that way (the `TUCK_DIFF_SSA` tooling that did it went
  with `analysis_ssa.nim` in M1.4 — see git history for the shape). For the
  graph itself, `tuck ssa file.tuck` and the goldens in `tests/ssa/`.
- **The re-emit is the review.** `tools/emit_examples.sh` then
  `git diff examples/`. It caught a dropped line in a moved proc that Nim
  tolerated and Odin would not.

---

## Doc corrections found while validating, 2026-09-22

The compiler beats the documents (README's trust order). Three places where a
document is behind the tree — fix these when passing, and do not plan from them:

- **`tuck-spec.md` Appendix A** says direct construction of a generic record
  (`{value: 5} Box`) is a "checker error v1". It **works** — builds and exits 5
  on all three backends.
- **`MISSING-FEATURES.md` §D** says the event registry emits invalid Nim and
  that `examples/20-embedded-mp3-player` "fails to build on ALL THREE backends
  today". It **builds on all three**.
- **`MISSING-FEATURES.md` §A** counts 10 open bugs against GitHub's 16
  bug-labelled issues. Different ledgers on purpose — the in-tree count is
  bugs pinned by a real assertion, and it is the one `end_to_end` gates — but
  neither number should be quoted as "the" bug count without saying which.

## Traps that cost time on 2026-09-22, recorded so they cost nothing again

- **Odin's compiler crashes itself, rarely.** `malloc(): unaligned tcache
  chunk detected` (rc 134) or a silent SIGSEGV (rc 139) from `odin build` on
  the recursive-type packages — about 1 in 100 builds, at `--jobs:1` too, so
  NOT our concurrency (#31 guessed that). Gone with `-thread-count:1`, which
  the suite now passes everywhere (`harness.OdinThreads`, and
  `TUCK_ODIN_EXTRA` for `tuck build --odin`).
- **Most earlier full runs never exercised D.** `dmd` was not on PATH, so
  every D assertion SKIPPED and the suite still printed green. The cloud
  container has two: `/opt/dmd` is v2.109 and cannot build the runtime (no
  `pipe2`); `/opt/dmd112` works. The harness now looks there, and for
  `/opt/odin-cur` — but `tuck build --odin` finds Odin on PATH only, so
  `export PATH=/opt/dmd112/dmd2/linux/bin64:/opt/odin-cur:/opt/nim/bin:$PATH`.
- **A compiler outside the repo cannot find `std/`.** It resolves std next to
  its own binary, so a scratch build in /tmp fails every stdlib import —
  quietly, if you only grep its output. Measure with `./tuck`, or copy the
  binary into the repo root first.
- **Editing sources while `tests/run` is running breaks it**: the complexity
  suite globs `compiler/*.nim` in both its passes, and a file added or
  removed between them is a KeyError in the runner.

- **A use-after-free guard must assert on OUTPUT, on every backend.** Two
  versions of the `str` guard passed against the bug they were written for:
  `runs`/`outputs` run on Nim, which has ARC and never emits the free; and
  freed-but-intact memory still answers the right byte count. `hostRuns` with
  an output pattern is the shape that works.
- **`nimoutline` is not installed in every container**, despite CLAUDE.md. A
  grep over `^proc |^type` is the fallback.

- **One `-o:` directory per backend, always.** Building three backends into one
  output directory leaves the earlier binary in place, and
  `find -executable | head -1` then re-runs the WRONG one. This produced a
  false "fixed" reading on #76. Odin's binary is suffixed `_odin`; Nim's and
  D's are the bare stem.
- **`/usr/bin/time` does not exist here.** Measure peak RSS with
  `resource.getrusage(RUSAGE_CHILDREN).ru_maxrss` from a small Python wrapper,
  or use the harness's own `hostPeakRss`.
- **The toolchains are not on PATH by default** in a fresh shell:
  `export PATH=/opt/nim/bin:/opt/dmd112/dmd2/linux/bin64:/opt/odin-cur:$PATH`.
- **A reserved word as a field name misreports.** `pending: Seq[int]` in an
  `actor` or `object` body says "Expected the end of the line here, found
  `Seq`" — blaming the TYPE. The `type` parser correctly names the reserved
  word. This is why #52 read as a parser bug for its whole life. Recorded on #4.
- **`benches/apps/world_server.tuck` no longer reproduces #84.** The app now
  boots its shards through the Gateway, so `start` and `edit` share a sender.
  Restore the two-sender shape to see the bug; the one-line `sed` is on #84.

---


Status legend: DONE = parse+check+codegen+tested. Gate = generated Nim passes
`nim check` (13/24 examples).

## Done
Postfix calls, subset matching, let/var + `..`, sum types, sealed transition
tables (runtime matrix + reachability), decision tables (exact enum analysis,
packed-key codegen), distinct types/units, `!T ?T !?T` + `?` + global error
policy §4.9, effect enforcement, pending blocks + stubs + TODO report,
imports + `::` + msgpack AST cache + signature index, registry §10, register
decl §8.1, sizeof/alignof/offsetof §8.2, static_assert, invariant → validate()
proc, tuck CLI (lex/parse/check/compile), generics v1 (simple substitution,
call-site inference, lowered to Nim generics; ceilings: no generic-record
construction, generic bodies gradual, no constraints). `when TARGET == "...":`
conditionals §8.3, 2026-08-11: resolved at module load (uncached — see
modules.resolveWhenBlocks), `--target:NAME` CLI flag, both backends need no
codegen changes since the AST is already filtered before codegen runs.

`pred`/`set` fn prefixes §3.6 — DROPPED 2026-08-11 (never implemented, and
formally will not be: effect markers already gate side effects, `..`-on-var
already gates mutation, so a third purity mechanism at the keyword level
would duplicate a rule rather than add one). Spec §3.6 rewritten to record
this instead of describing unbuilt syntax.

## User rulings (2026-07-09)
- §6.3 complexity limit: ENFORCE as hard compile error (cyclomatic ≤ 5,
  ~10–15 executable lines/fn).
- `Foo {}`: legal only when the type has no fields (empty state is a valid
  type). Types with fields require every field at construction; absence must
  be explicit `?T`. Add to spec §4.8.
  RE-RULED 2026-08-14 — partial construction is LEGAL; the unsupplied fields
  are `<uninit>`, a compile-time-only state with no runtime representation.
  Three rules: never read it and the program compiles, read it unset and that
  is the error (TK-TY16), assign it and the marker is gone. Rejecting at the
  construction site would have refused the builder pattern (construct partial,
  fill by chain, then read), which works and is worth keeping — this is the
  data analogue of `pending:` (§5.4), so a walking skeleton can carry holes in
  its DATA as well as its functions. The marker rides in the field's type, so
  storing a partial record inside another cannot launder it. `{}` on a
  zero-field type is unchanged. Function CALLS still require every field —
  only type/object construction changed.
- Actors/tasks: API stays actors + tasks. Runtime strategy SETTLED (2026-08-05):
  stackful coroutines over vendored minicoro with mmap'd virtual stacks, one
  cooperative scheduler, and an epoll/kqueue reactor. Neither nim-cps nor
  hand-rolled stackless state machines — both backends drive the same C
  library, so they cannot diverge on switch semantics. §9.2/9.4 are built and
  run-gated (examples 26/27/28/42).
- Effects §3.7: RE-RULED 2026-08-11 — require-declared stays. The
  infer-and-propagate ruling above was never implemented; re-examined and
  reversed instead of implemented, since explicit declaration at every level
  fits Tuck's "everything explicit" stance (spec Part 1) better than silent
  upward inference would. Spec §3.7 rewritten to describe require-declared as
  the real (and now permanent) design.

## User rulings (2026-07-09, session 2) — error model + OS layer
- `extern:` blocks (DONE): sigs implemented by tuck_rt; `extern [c, header:
  "uart.h"]:` emits Nim importc — the C/bare-metal seam. Tuck→Nim→C→gcc
  covers embedded; `tuck build` will forward nim flags (--os:standalone etc).
- Stdlib v1 scope: fs, io, sys (os/env), time — extern sigs over Nim stdlib.
  Full bottom-layer catalogue (what to extern vs write, per domain, incl.
  embedded/atomics/net/proc): stdlib-blocks.md. Layer map above it
  (L0→L5 dependency graph, build order, derive ruling): stdlib-layers.md.
- Errors are declared enums (fieldless sums), named in the signature via
  `[error: FsError]` attr (effects bracket). Effects ≠ errors: [io] still
  propagates upward independently.
- The enum never flows bare — always inside the result struct
  {ok, err, value}. Raise site: `return err FsError.NotFound`, shorthand
  `err NotFound` resolved against the sig's declared error type.
- `expr?` propagation operator DROPPED. Handling = local if/ifErr/.ok
  access, or return the whole result up. Policy 4.9 unhandled list tracks
  the rest. (Parked idea, not firm: call-site `get!` as io marker.)
- `or return` DROPPED (2026-07-22), same reasoning as `expr?`: it was a
  second, weaker unwrap that discarded WHICH error occurred. `and`/`or`/`xor`
  are now strictly boolean, enforced by the checker (there had been no
  operand rule at all — `5 or "x"` typechecked). A `?T` operand in a boolean
  position reads as "is present": a test, not an unwrap. Pool `acquire`
  (§7.2) returns `?T` and is handled with an ordinary `if`.
- Tri-state result STAYS: `int?!` = fallible + optional in one value.
- Type wrapper position: both accepted — `int?` == `?int`, canonical
  postfix; combos `T?!`/`T!?` equivalent.

## User rulings (2026-09-11) — generic constraints are COMPILE TIME

Raised by `core.slice`: a slice is a for loop over indices, which wants an
`Indexable`-style contract, which raised "what about regular types?" —
`satisfies` takes an `object`, and a `type` is refused outright (TK-CO03,
"declares data but no members, so there is nothing for the contract to
check").

**Ruling: everything in this area is compile time.** A constraint on a type
parameter is checked at the instantiation site and has no runtime
representation. Interface VALUES keep their present meaning — a tagged
variant, object-only, dispatching at run time. One name may serve both
positions; the position decides which it is.

Measured before the ruling, and the reason it is a small feature rather than
a new mechanism:

- A generic fn over an unconstrained `C` whose body calls `count` and indexes
  `c[0]` ALREADY checks and runs on Nim, Odin and D. Tuck is structurally
  duck-typed inside a generic body today.
- So the capability exists and the CHECK is what is missing. `firstOr[C, T]`
  accepts an `int` for `C` and fails in dmd or Odin — a host error about a
  Tuck program, which is the "agree by luck" failure the D backend exists to
  prevent.

Blocks nothing today: `core.slice` and the deduplicated `find`/`has`/
`indexOf` can be written unconstrained and gain the constraint later.
Also the other half of what `core.iter` needs, alongside generic `fnsig`
on Odin and D.

## User rulings (2026-07-11) — resource registry (spec §7.4, design only)
- Global per-kind registry in tuck_rt (slot table = pool §7.2 machinery);
  user code holds u32 index+generation HANDLES (Tier-1 values), refs stay in
  the runtime layer.
- Kinds user-declared via `resources:` block (open set, like error enums);
  acquire sites marked `[resource: kind]` in the effects bracket, propagated
  by the effects machinery. Unknown kind = checker error.
- `defer` block = release INTENT: marks isFinished, runs per-kind `on_finish`
  (file: flush), bumps generation (handle dies at mark under every policy).
  Actual close per policy strict/lazy/exit (errors-decl symmetry).
- No refcount — single owner, one isFinished bool; eviction candidates =
  finished entries only.
- Cap optional: absent → seq-backed unbounded; present → on_full policy,
  static array on standalone. Watermark sweep (~75%) runs INLINE in the
  defer-release code (mark checks threshold, evicts all finished or in
  user-specified batches, `sweep_batch: 100`) — no thread/actor; explicit
  `kind::sweep` for scheduled cleanup. NO idle/time-based eviction. LIFO
  close-all.
- Static check: every acquire ends in defer-mark or registry escape (escape
  always sound); scope-local analysis only. Debug `OPEN RESOURCES (n)` report.

## User ruling (2026-08-24) — no function overloading, deliberately

**Decided: free functions do not overload, and this is not a gap to close.**
Two same-named `fn`s are rejected with `[TK-TY02] duplicate declaration`
regardless of whether their payload types differ; only object members
overload, resolved by receiver.

The reason is readability: **a call site should say which function it calls
without the reader reconstructing parameter types.** In a language where
arguments bind by name and by type across a payload — with subset matching,
so extra fields are ignored — an overload set would make the resolution
genuinely hard to see at a glance. One name, one function, is the better
fit.

Consequences, accepted rather than worked around:
- The stdlib carries suffixed pairs where a Rust/Nim design would overload:
  `dot`/`dot3`, `length`/`length3` (`core.geom`), `feedFast`/`feedSafe`
  (`core.hash`), `rollRange`/`rollFloat` (`std.random`), `getEnv`/`setEnv`
  (`sys.env`), `sqrtOf`/`lnOf` (`std.math`).
- `platform.power` loses the nicest bit of its Nim design — `wakeOn(duration)`
  / `wakeOn(pin)` / `wakeOn(time)` overloaded on argument type, so the enum
  never appeared at a call site. Now the `WakeSource` is constructed
  directly. This is the clearest cost of the ruling and is accepted.
- Odin cannot overload either, so the mangler already assumed this; the
  ruling keeps the two backends aligned rather than making Odin the
  constraint.

Supersedes the "minimum rule that unblocks the geom case" sketch produced
while investigating this (declaration-time pairwise ambiguity check plus a
mangle-time index) — that work is not wanted.

## User ruling (2026-08-24) — numeric conversion is always explicit

**Decided: crossing a numeric type boundary is always written in the source.
Both directions. No exceptions.**

Not a new rule so much as enforcing one the spec already states — Appendix B
lists *"implicit conversions"* among the things Tuck deliberately does not
have. Today `compatible()` lets any numeric primitive match any other, so
the rule isn't enforced.

```tuck-rejected
fn setDuty({channel: int, permille: u16}) -> void

let wide: u32 = 70000
{channel: 1, permille: wide} setDuty         # ERROR: u32 -> u16 needs a cast
{channel: 1, permille: wide ~u16} setDuty    # explicit, in the author's own code
```

**Widening is written too** (`^u32`), even though it cannot lose anything.
Uniform beats "the safe direction is silent": nobody has to remember which
way is which, and the sign-crossing trap stops being a special case — `-5`
into `u32` is *wider* in bits and still lossy, so a width-based exemption
would let exactly the wrong case through.

**The reason, in the user's words:** the user knows where the mistake came
from — his own code. A cast in the source is greppable and blameable; a
silent conversion inside the checker is neither.

### A casting word as well as the sigils
`to` is proposed alongside `~`/`^` for readability at call sites where a
sigil is dense. Spelling not settled — `wide to u16` vs `wide ~u16`, and
whether both exist or the word is just an alias.

### Where it lives in the compiler
`compiler/typecheck.nim:263`'s `compatible()`, final line:

```nim
when defined(strictKind): false   # measure the same-kind fallthrough
else: a.kind == e.kind
```

Every numeric primitive is `tkPrim`, so that one line is what lets `u32`
satisfy `u16`. The `strictKind` define already exists for measuring the
blast radius. `compatible()` itself may be removed later rather than
tightened — it is doing several jobs.

### Arithmetic overflow is a separate concern — and mostly unimplemented
Confirmed this pass: **only `[saturating]` has codegen.** `[wrapping]` and
`[trapping]` appear exactly once in the compiler
(`codegen_common.nim:99`), in a list that makes them imply `distinct` —
they emit nothing, so the behaviour is **whatever the backend happens to
do**. That is C semantics by inheritance, not by decision.

The intended answer is trapping and/or overflow attributes as the safe
alternative to C, likely via compiler-known internal types so a bare `u32`
can carry a policy the way a `distinct` does. Not designed here.

### Order of work
1. Enforce no-implicit-conversion at binding sites (the `compatible()` line).
2. Implement `~` / `^` (and decide `to`), so there is a way to say yes.
3. Implement `[wrapping]` / `[trapping]` for real, then decide the
   bare-primitive default — in that order, since a default that names
   `[trapping]` is theatre until trapping traps.

## User ruling (2026-08-24) — optional variant sets in fn signatures

**A fn taking a transition-typed argument MAY declare which variants it
accepts. Bare type = all variants (unchanged); a declared set narrows.**

```tuck-rejected
type ProtocolStage:
  | Handshake
  | Login
  | Active
  | Processing

fn doAfterHandshake({x: int, stage: ProtocolStage<Login|Active|Processing>})
```

Calling that with a `Handshake`-stage value is a compile error — the
function is callable only in the states it names. **Optional by design:**
existing signatures keep working, and an author opts in where the
distinction earns its keep.

*Syntax not settled* — the angle brackets above are illustrative. Tuck uses
`[T]` for generics and `[...]` for attributes, so this needs a spelling
that doesn't collide. Deferred; the semantics are the ruling.

### It relaxes a documented rule rather than reversing it
Spec §4.4b currently says:

> **Function boundaries carry the narrowing, not the signature.** A fn's
> declared param/return type stays the general `Type` (no `@Variant` in
> signatures)…

That put the knowledge in the checker's inference rather than the
declaration, and the spec names the cost itself: **"return-site tracing is
module-local (cross-module calls yield the full set)."** An optional
declared set fixes that where an author asks for it — the set travels with
the signature, so it survives a module boundary with no inference at all —
while inference stays the default everywhere else.

### Why it fits
- **Same shape as `[error: FsError | NetError]`**, which already puts a
  variant set in a signature and validates `match` arms against it. State
  and failure get the same treatment.
- **Typestate without a new concept.** "Only valid in these states" is what
  protocol bugs look like — sending before the handshake, reading after
  close — and §4.4b's flow analysis (per-var variant sets, branch merges,
  match narrowing) already exists. This gives it something declared to
  check against.
- **Documentation that cannot drift**, since the checker enforces it.

### Scope, decided
- **Params only. Return position is out of scope** — the point is to limit
  *calling* a function, statically, with the compiler's help. Narrowing a
  caller's result from a declared return set is a different feature and
  isn't wanted here.
- **Interfaces: exact match. A wider implementation does NOT satisfy a
  narrower contract.** Conformance already matches params exactly, names
  included (`tests/suites/interfaces.nim:122`), and this follows that rule
  rather than introducing variance. An interface declaring
  `ProtocolStage<Login|Active>` is satisfied only by an implementation
  declaring the same set.

### The error message is part of the feature
This exists so a user learns statically what they got wrong. The diagnostic
should name the three things they need: the states the fn accepts, the
state the value is actually in, and where it got that state.

Something like:

```
Type Error: 'doAfterHandshake' accepts ProtocolStage in Login|Active|Processing,
but 'stage' is Handshake here.
  stage became Handshake at protocol.tuck:14 (construction)
```

The "where it got that state" line is what makes it actionable — §4.4b's
per-var variant sets already track this, so the information exists. Compare
`FRICTIONS.md` #7 (the opaque-handle-in-actor-field error) as the house
standard: it names the type, the rule, the position, and a way forward.

## User ruling (2026-08-25) — numeric defaults, narrowing, and unsigned subtraction

Completes the 2026-08-24 conversion ruling above; supersedes the parts noted.

### 0. The rationale: shorten the search for a bad number
We trust the developer knows what they are doing. The risk is not that they
write a bad conversion — it is that **a weird value appears somewhere far
from where it was created**, and they have no idea which line produced it.

Everything below is aimed at that, and nothing below tries to prevent the
bug outright:

- **The sigils (`~` / `^`) mark the sites in the source.** Every place a
  number crosses a type is greppable, in the author's own code.
- **The warnings list the sites the compiler suspects.** Not proof — just
  "these are the places it could have happened."
- **Trapping stops execution at the site** rather than letting a wrong
  number travel (see ruling 4).

That is why the compile-time half is deliberately weak: it is a *search
narrowing tool*, not a correctness proof. Judged as a proof system it fails;
judged as "which of my 400 lines could have made this 65503", it works.

### 1. Bare `int` is the native word (64-bit on hosted targets)
64-bit ops are fast, and at that width ordinary counting and arithmetic do
not overflow. So there is **nothing to warn about on the common path** —
overflow is a concern only where an author *chose* a narrow type (a protocol
field, a register, a memory budget), and there the attribute applies.

**A declared type is always respected — the default never overrides it.**
If the user writes `i16`, `u32`, or annotates a literal with a numeric type,
that is the type. No silent promotion to `int64`, no "helpful" widening.
The default fills an *absent* annotation; it does not second-guess a present
one.

This supersedes the earlier instinct to warn on arithmetic generally: with a
64-bit default the warning would fire almost entirely on code that is fine.

*Note:* this likely simplifies the spec's "declared types never auto-widen
(`u8 + u8` stays `u8`)" clause — literals and intermediates are `int`, and
declared narrow types bind at storage. Worth re-reading §4.1 against this.

### 2. What the compiler can actually say — no ranges, so no proofs
**Tuck has no range/interval analysis, so the compiler cannot prove a
variable's value fits.** It has exactly two things:

- **Constant folding** — a literal or `const` is evaluated, so
  `70000 ~u16` is *certain* not to fit. That is an **error**, not a warning.
- **Type-width reasoning** — for a variable, the compiler knows only that
  *some* values of the source type do not fit the target. It cannot know
  whether *this* value does. That is a **warning**, and the honest wording is
  "might not fit".

| case | what the compiler knows | verdict |
|---|---|---|
| literal / `const` that does not fit | certainty | **error** |
| literal / `const` that fits | certainty | silent |
| variable, source width > target | nothing about the value | **warn: may not fit** |
| variable, sign crossing | nothing about the value | **warn: may not fit** |

**Arithmetic results warn too, and there is no cast to hang it on:**
`a * b` or an exponent on a declared narrow type can exceed it with nothing
in the source to draw the eye. Wording: *"this operation may reach the
type's upper limit"*.

**Two rules keep these warnings from becoming noise** (a warning people
learn to ignore is worse than none):
- Arithmetic warnings fire **only on declared narrow types**. Bare `int` at
  64 bits stays silent — ruling 1 gives this for free.
- An overflow attribute **silences it**. `[saturating]` means the author
  already said what happens, so there is nothing left to warn about.

### 3. Unsigned subtraction yields `?T`
Underflow is not an overflow-policy question — **the operation has no
answer**, exactly like `pool.acquire` on exhaustion. `?T` is already the
language's word for that, and `.ok` is already the idiom.

```tuck
let count: u32 = 3
let r = count - 5        # ?u32 — absent, because it underflowed
```

The ceremony objection is answered by ruling 1: with `int` defaulting to
64-bit signed, unsigned types are rare and deliberate. Nobody writes guards
around a loop counter; they write them where they genuinely subtract from a
byte count.

**Open (small):** always `?T`, or only where non-negativity cannot be
proven? Always is simpler to explain and impossible to get wrong;
proof-conditional is friendlier but reintroduces "why does this one need a
guard and that one doesn't". Leaning always, given unsigned is now rare.

### 4. Trapping is the default overflow behaviour, on every backend
**Not whatever the backend prefers.** Confirmed this pass: only
`[saturating]` has codegen; `[wrapping]`/`[trapping]` appear once
(`compiler/codegen_common.nim:99`) in a list that merely implies `distinct`,
so today the behaviour is inherited from Nim/Odin by accident. That is C
semantics by default, which is the thing this ruling replaces.

**Why trapping rather than wrapping or saturating:** both of the others
produce a *plausible-looking* number that keeps travelling. A wrapped
counter is a hang; a saturated reading is a silently wrong measurement — and
by the time either is noticed, the origin is gone. Trapping stops at the
site, which is the same "shorten the search" goal as the sigils and the
warnings, applied at runtime.

Wrapping and saturating remain available **where the author asks for them**
by attribute — a protocol sequence number genuinely wraps, a sensor reading
genuinely clamps. The change is only to what happens when nobody said.

**Traps stay in release builds.** A wrong number in production is worse
than a slow one, and stripping the trap reinstates exactly the
travelling-bad-value problem ruling 0 exists to kill — in the one
environment where it is hardest to debug. Overflow checking is not a
debug-only assertion.

*Implementation note:* needs real codegen for `[trapping]` on both backends
before the default can be switched.

### 5. `invariant` gets a flag too — and should be available in release
Related decision, and it revises shipped behaviour rather than a pending
design. Today invariants are stripped unconditionally:
`compiler/codegen.nim:1398` emits

```nim
proc validate*(self: T) =
  when not defined(release): ...
```

The `when not defined(release)` is hardcoded into the emitted Nim, so there
is **no way to keep invariants in a release build** even when you want them
— which is the common case for anything where a violated invariant means
corrupt data rather than a slow loop.

Ruled: **swap the define, and flip the default to on.** This is a one-line
codegen change, not new machinery — `release` is itself just a Nim define,
so the emitted guard becomes a dedicated one:

```nim
proc validate*(self: T) =
  when not defined(tuckNoInvariants): ...
```

`tuck build` passes `-d:tuckNoInvariants` only when the user asks to strip
them (it already forwards Nim flags via `--nim:`). Invariants then stay on
in release **by default**, opt-out rather than automatic-off — which is the
right way round for a check whose whole job is catching corrupt data.

Same shape applies to overflow traps once `[trapping]` has codegen: one
dedicated define, checked at the emission site, not piggybacked on
`release`.

Care needed only in that this changes shipped behaviour with existing
coverage — `cli_smoke` run-verifies invariants aborting in four positions,
and those must stay green.

### The whole numeric story, after these rulings

| operation | mechanism |
|---|---|
| arithmetic on bare `int` | nothing — 64 bits is enough |
| arithmetic on a declared narrow type | warn "may reach the type's limit"; silenced by an overflow attribute |
| narrowing a value | `~T` / `^T`; error if a constant cannot fit, warn if a variable may not |
| unsigned subtraction | `?T` — underflow is absence |
| overflow, nobody said what to do | **trap** — stop at the site (ruling 4) |
| overflow, author declared a policy | `[saturating]` / `[wrapping]` / `[trapping]` |
| any cross-type numeric flow | always written (2026-08-24 ruling) |

## Partial
| Feature | Spec | Missing piece |
|---|---|---|
| Static transition checking | 4.4b | CORE DONE 2026-07-13: per-var variant sets (Type@Variant), reassignment-as-transition vs the table, if/match/loop set merges, match narrowing, param full-set entry, module-local return tracing, sealed-RHS exemption. Caught a real bug in ex 20 on first run. Ceilings: cross-module fns → full set; helper fns building sealed variants need [unsafe]; match arms single-line; optional debug assertion emission not done |
| Invariants | 4.7 | construction + return sites DONE (2026-07-11; validate() auto-inserted, `when not defined(release)` strips). mutation sites, extern boundaries and `!T`-wrapped returns ALL DONE 2026-07-13 — every production site now validates (constructions, returns, `..` chains, extern call sites; !T payloads validate transitively via construction). Both backends, runtime-verified. Ruling: BLOCK syntax only |
| Actors | 9.1 | DONE 2026-08-05. Stackful minicoro coroutines, static ring mailboxes, cooperative scheduler + epoll reactor. `on <name>` and `on select` handlers both work on both backends (26/27 run-gated at 55). Ceiling: tuckNotifySend broadcast-wakes every actor per send, not the addressee |
| Tasks | 9.2 | DONE 2026-08-05 — but STACKFUL coroutines, not the state-machine transform this row assumed. `[io]` calls are yield points; binding a task's result awaits it. Ceiling: on Odin a task WITH ARGUMENTS still emits a direct call (proc literals cannot capture), so its body runs off-coroutine |
| bake | 3.5 | v1 DONE 2026-07-13 (Factor-fry: :name refs, fn→auto generic lowering, slot.invoke; ex 03 green+runtime-verified). Beef bake = delegate-type ceiling. True Tuck-IR inlining later if ever needed |
| alias restructuring | 2.5 | DONE 2026-07-13 (typed renamed record, both backends; ex 18 green). Non-exkVar payload args still not exploded (double-eval; bind-to-temp later) |
| pool / arena | 7.2/7.3 | acquire/release bitmask, reset, scope analysis, size verification |
| Resource registry | 7.4 | 2026-09-14: `resources:` declaration (per-kind cap/policy/on_full/on_finish/sweep_batch, block-level policy default), `[resource: k]` marker validated (TK-RS01/02) and propagated through the effect machinery (TK-RS03, cross-module), the registry table in all three runtimes (strict/lazy/exit, inline ~75% watermark sweep, LIFO close-all, stale-handle generation catch — 19 rules pinned per runtime by `tests/suites/resources_rt.nim`), per-kind `<Kind>Handle` type, and the `OPEN RESOURCES` report + close-all at exit. `defer` landed with it as a GENERAL statement on all three backends. Release is `finish <handle>, <kind>` (ruled 2026-09-14): the kind is redundant against the handle's type and CHECKED (TK-RS04), so finishing into the wrong registry is a compile error. `on_full` and `on_finish` reach the table as closed vocabularies, the latter as real syscalls. The registry surface is a symmetric pair, `acquire <raw>, <kind>` / `finish <handle>, <kind>`, one parser building both (TK-RS04/05); the raw fd exists between the extern's return and the acquire and nowhere else, and the acquire site is filled from the span so the leak report can name it. A kind may also NAME a PROTOCOL — `db [cap: 4096, states: DbState]`, where DbState is a sealed sum type with `transitions:` (ruled 2026-09-14, decoupled: a `resources:` block is a deployment decision, the protocol of an OS service is the library's). The library writes only the states, never the handle; initial and terminal are DERIVED, and the machine is checked for what a resource needs (TK-RS06..10, including "the closing state is reachable from every state"). The registry is untouched: handle and table unchanged. Protocols are validated, NOT yet tracked — narrowing a handle through the machine needs a surface for a library op to name the edge it walks, a further ruling. A kind is declared ONCE by the library that owns it and apps import it — verified end-to-end, after fixing two bugs an import exposed: `main`'s blanket kind budget was its own module's kinds rather than the program's, and it REPLACED main's declared marker instead of unioning it, so the one workaround was a no-op too. A kind may be declared by MORE THAN ONE site, one knob each (ruled 2026-09-14): the library declares the protocol and on_finish, the app declares cap/policy/sweep_batch. Per knob, with a later site OVERRIDING an earlier one — a library ships a default, the app deploying it gets the last word. Not file order: modules are dep-first, so the importer overrides the imported. `states` is the exception and refuses a second setting (TK-RS02), since a protocol is what the service does rather than a default. Coherence moved out of the parser to the merged kind (TK-RS11) — a library's `on_full` is incoherent alone and correct once an app adds a cap. The table emits at the first site in dependency order, which is where a library's own acquire site can reach it; re-opens emit nothing, so no backend learns about re-opening. Also: `on_finish: none` now parses (it lexes as a keyword, so it was reserved even where only a name can appear). MISSING: §7.4's static acquire-must-finish check — writable now that both halves have a shape, but its escape arm is already sound by construction. DEFERRED by ruling: single-owner handles (affine types), a language-wide feature rather than a resource one — and not a prerequisite for protocol tracking, which stays sound under copy because a stale `finish` is a missed error the generation check catches, not a false rejection |
| Interfaces | 5.2/5.3 | DONE. `satisfies` is checked at compile time; an interface value is a TAGGED VARIANT THAT COPIES, not a fat pointer — dispatch is a switch on the tag calling the concrete member fn, so there is no table, no thunk, and no lifetime question (escape analysis was deleted with the pointer design). Both backends |
| Type composition `+` | 4.5 | conflict detection unverified |
| match | — | exhaustiveness DONE: every match over a closed domain (sum type, bool, error enum) must cover all cases or end in `_`. Open domains (int/str) unchecked, as in Nim |
| Effects | 3.7 | switch to implicit propagation (ruling above) |
| ~~Beef backend~~ | — | REMOVED 2026-07-28. Frozen since the Odin backend landed, never compile-verified here (no BeefBuild), and every new construct meant a third unchecked emitter arm. Odin is the second backend |
| Odin backend | — | 2026-09-12: 39 examples compile-gated, 17 run-gated on exit codes; coroutine runtime over minicoro; full C FFI parity; offload worker + std/net mirrored. Known gap: a task WITH ARGUMENTS is not spawned as a coroutine |
| D backend | — | 2026-09-12: 42 examples compile-gated, 17 run-gated on exit codes, own 994-line suite. Emits `alias T = base` where Nim/Odin emit `distinct`, and concatenates with native `~` rather than a runtime `tuckConcat`. Registers are not `volatile` |
| C FFI | — | DONE 2026-07-28: functions, cstring, structs by value, enums with explicit values, callbacks, opaque handles — all run-verified against a real C library on BOTH backends. `lib:` links a system library or a vendored `.c` |
| Control flow loops | 2.6/3.6b | DONE 2026-07-19: unified for (cond/iter/indexed), loop, break/continue (innermost, depth-checked), spaced-`..` ranges (Nim convention), fn inline ({.inline.}/[Inline]). Runtime-verified exit-17 smoke both backends. No labels ever (ruling); value-returning main = process exit code |

## Missing
- `on select` §9.3: the ACTOR form is done (ex 27, both backends). The TASK
  form lowers `read <fd>` / `timeout <ms>` only — dotted sources (`resp.ok`,
  `timeout.5s`) still parse as opaque strings, which is what blocks ex 16.
  Scheduler §9.4 is done (see Partial above).
- Stack-depth budgets `[stack: N]` §6.2
- ~~Complexity limit §6.3 (ruling: hard error)~~ IMPLEMENTED for release,
  verified 2026-09-13: `tuck b --release` REJECTS a function over the budget
  with `TK-CX02` ("--release requires them under it"), and a normal build
  reports it. `--max-complexity:N` / `--max-fn-lines:N` raise it, `:0`
  disables. BOTH halves are gated: `TK-CX01` for cyclomatic complexity and
  `TK-CX02` for source lines, each verified by building a fn over each limit
- ~~Error.x validated against a declared error enum~~ MOSTLY DONE, verified
  2026-09-12: raise sites are validated (variant typo, shorthand typo,
  cross-enum) with or without a declared list, and `match r.err` arms are
  validated when the producer declares `[error: …]`. The remaining gap is
  narrow: with NO declared list, an arm naming a nonexistent variant is
  accepted and emits `of Wibble:`, which nim refuses. See issue #35
- ~~Visibility (pub/private)~~ DONE 2026-09-11: a `public:` block lists bare
  names, and the restriction reaches all three backends' visibility markers.
  Imported types resolve by bare name across a module boundary. STILL
  MISSING: `mod::Type` in a TYPE position — `let p: geo::Point = …` is
  "Expected `Assign` here, found `::`" (verified 2026-09-12). Nested module
  paths untested.

## Broken-example map (2026-07-13: Nim gate 21/25, Beef 20/25)
Remaining: 11 → when + pool + attr features (main-only ruling landed 2026-07-13); 16 → on select (actor-runtime
ruling); 20 → when + actor-transition lowering; 03 → Beef-side only
(delegate types). Everything else GREEN in both gates.

## Spec debt
None outstanding. §11/§12 (previously: describing npeg parser + flat IR +
Merkle cache while reality is recursive descent + ref-AST + hash-keyed
msgpack cache + signature index) rewritten 2026-08-11 to match the real
compiler — confirmed, per user ruling, that the built architecture is
preferred over the original design, not a gap to close.

## Experimental (2026-08-24) — three things to try

Speculative, deliberately kept apart from the status sections above.
Nothing here is committed; each is a "run the experiment, then decide."

### 1. A D (dlang) backend

A third backend beside Nim and Odin. D is a reasonable fit on paper —
value-type structs, compile-time evaluation, no mandatory GC path
(`@nogc`/`-betterC`), and a C ABI story — so much of what Tuck already
lowers should map without inventing new IR concepts.

What the experiment answers:
- **Does the two-backend discipline actually generalize to three?** The
  current invariant (each backend lowers its own deep copy; `case` over an
  enum takes no `else` so a new node kind breaks every backend that hasn't
  handled it) was designed to make this cheap. A third backend is the real
  test of that claim.
- **Where do Nim-isms hide?** Anywhere Tuck currently leans on a Nim
  feature without noticing, a D backend will fail loudly. That is worth
  knowing regardless of whether the backend ships.
- Odin already forced one such discovery (no overloading → the mangler),
  which is exactly the kind of finding to expect more of.

Cost is bounded: it's additive, and abandoning it leaves the tree no worse.

### 2. Slab allocator — the value-semantics answer for trees

**Direct self-containment: DONE, 2026-09-09.** `Add({left: Expr, right: Expr})`
now checks, builds and runs on all three backends —
`compiler/lowering_recursive.nim` gives each recursive edge a `Seq[T]` handle,
a construction wraps and a read unwraps, and none of it is visible: `e.left` is
an `Expr` and `match` is unchanged. Mutual recursion works too, in either
declaration order. `examples/44-recursive-tree.tuck`,
`tests/suites/recursive_types.nim`.

That also answers this section's ergonomics question — it is `n.left`, not
`tree.child(n, 0)` — and it settles the index-vs-slab one for THIS use: the
handle is not user-visible, so there is no index to mismatch.

Getting there cost 18 fixes, of which exactly ONE was about recursion. The
rest were pre-existing defects no program had reached: D could not construct a
payload variant after the first, Odin could not build or index a `Seq` in a
record, Odin ALIASED where Tuck copies, a variant payload was never
type-checked or even synthesized, mutually recursive fns did not compile on
Nim, and `==` on a payload sum was broken on all three backends — silently
returning the wrong answer on D. The lesson is in the ratio.

**What remains here:**

- **By-reference node identity** — a linked list or an intrusive tree where
  you hold a cursor into the structure. `alloc.list` was dropped over this,
  and boxing does not help: a handle copies, so there is no stable identity to
  hold. This is the real remaining case for a slab.
- **Sharing.** Two parents holding "the same" child hold two children, and
  replacing a subtree copies it. A DAG cannot be expressed, and a wide tree
  costs an allocation per edge. An arena-and-index representation would fix
  both, and can replace the boxing behind the same author-facing surface —
  which is why the boxing lives in a pass rather than in the emitters. The
  arena form was built and run by hand first (all three backends, correct)
  before the boxed one was chosen for being a tenth the machinery.

**The idea:** a slab — one owned arena of homogeneous slots plus integer
indices into it. Indices are ordinary values, so nothing about the
no-`ref`/no-stored-pointer rules is violated, and the slab owns every node
so lifetime stays single-owner. `Seq[Node]` + `int` child indices is
already the workaround the corpus uses; a slab type would make it a
first-class, ergonomic thing instead of a hand-rolled pattern.

Open questions the experiment should answer:
- Does it need language support, or is it a library over `pool`/`Seq`?
  (`pool` already gives fixed-count slots with `acquire`/`release` and
  `?T` on exhaustion — possibly most of a slab already.)
- Can index-vs-slab mismatches be caught? A raw `int` index into the wrong
  slab is exactly the class of bug `ref` types prevent; a `distinct` index
  per slab type might recover that.

**Why not just rely on externs:** a user shouldn't have to leave the
language to build a tree. Worth solving inside Tuck even if externs remain
the escape hatch.

### 3. SoA — struct-of-arrays for `Seq[T]` and friends

Invert container layout: a `Seq[Point]` stores `xs[]`, `ys[]`, `zs[]`
rather than an array of `Point` — same API, different memory layout. Wins
are cache locality on field-wise traversal and real SIMD opportunities;
losses are whole-element access and any code that wants a `Point` back as
one value.

Three shapes to consider, easiest first:
- **Build `Seq` with SoA in mind from the start** — likely the cheapest
  path, since `Seq`'s implementation isn't frozen yet, and callers only
  ever see the API.
- **A separate type** (`SoaSeq[T]`) — explicit, opt-in, no surprises, but
  a second thing to learn and a second thing to keep in sync.
- **A compiler transformation** — most powerful, most invasive; needs the
  layout decision to be invisible and provably behaviour-preserving across
  both (three?) backends.

Interacts with two things already open:
- **The `Seq` copy question** (`stdlib-project/FRICTIONS.md` #8): how `Seq`
  crosses a call boundary is undecided, and layout and copying should
  probably be decided together rather than twice.
- **`core.simd`** — SoA is what makes vectorized field-wise work natural;
  the two experiments reinforce each other.

Measure before committing: `benches/` exists, and the honest outcome may be
"wins on the traversal benchmark, loses on the random-access one," in which
case the answer is a separate type rather than a change to `Seq`.

## Later (2026-09-16) — effect-system leverage

Nice-to-have, none committed. Filed as issues #62–#71 so each carries its own
detail; this section is the map.

**The finding that produced the list.** `EffectMarker` (`compiler/ast.nim:45`)
has seven members — `emIo`, `emNoAlloc`, `emIrqSafe`, `emUnsafe`, `emMayBlock`,
`emStack`, `emPriority`. Grepping each one outside the parser, the AST, and the
blanket `main` budget, **only `emIo` has a specific consumer**, and it has two:

- `compiler/semantics.nim:117` — `if emIo in callee.effects:
  semLayer.markAsync(e)`. The `[io]` marker DRIVES CODEGEN; it is the async
  annotation.
- `compiler/typecheck_collect.nim:268` — a fallible `!T` fn must be `[io]`,
  "pure functions are total". It GATES THE TYPE SYSTEM.

The other six ride the generic propagation engine and nothing reads them. So
the effect system today is one propagation engine plus one effect wired to
consequences. `[io]` → async is the proof the pattern works; everything below
is that pattern applied again. The organising question is **what else can an
effect CAUSE, not just forbid.**

The second standing fact: the name-parameterized half already exists.
`compiler/semantics.nim` carries `Demands(effects: seq[EffectMarker],
resources: seq[string])` and `checkExpr` enforces both halves through identical
code — its own comment says "§7.4 asks for the identical rule on
`[resource: k]`, and gets it from the identical code." `[resource: conn]` is
already a checked, propagating, name-parameterized authority. Several items
below are that shape reused.

### Cheapest first, measured by how much already exists

- **#62 — an effect-free fn is const-evaluable.** The const evaluator
  (`ast_query.evalConstExpr`) takes literals, consts and integer arithmetic.
  "Declares no effects" is already computed and already means *total*
  (`typecheck_collect.nim:268` says so in its own error text), so it is exactly
  the gate for "safe to run during the build". One arm in the evaluator widens
  every attribute position that takes a number. Highest ratio in the group.

- **#63 — the effect manifest.** Write each fn's declared effects to a stable
  file so `git diff` shows effect creep. A previously-pure function gaining
  `[io]` is a real semantic change that is invisible in most languages. This is
  also the mechanism that catches the supply-chain case IN PRACTICE, since
  #71 says the type system cannot.

- **#64 — wire the six inert markers.** `[no_alloc]` is statically checkable
  with what is in the tree (reject a growing `Seq`, a string concat, a heap
  constructor). `[irq_safe]` has a precedent already: `tests/suites/declarations`
  asserts "an irq_safe fn may not call a may_block one". Making existing markers
  mean what they say is strictly cheaper than adding an eighth, and makes the
  language more truthful rather than bigger.

### Generalizing the `[io]` → codegen precedent

- **#65 — split `[io]` by kind.** `[io: net]`, `[io: fs]`. Worth recording even
  before any scheduler consumes it: a later scheduler is SIMPLER because the
  distinction is in the signature rather than discovered at runtime (file IO is
  not epoll-able; net IO is). Same shape as `[resource: k]`, so this is a
  generalization rather than a new mechanism. Open ruling: closed kind list or
  open, and whether bare `[io]` is the union.

- **#66 — the contention graph.** A task's `[resource: k]` set is its
  contention footprint, known statically. NOT auto-parallelism — the
  web-downloader disproves that, since all eight chunk tasks share the one
  `conn` kind. What it actually buys: **deadlock freedom by declared ordering**
  (A holds `X` acquires `Y`, B holds `Y` acquires `X` is a cycle in a static
  graph, so a compile error rather than a 3am page), **capacity arithmetic**
  (`cap: 8` plus per-task demand answers "can this exhaust and hang?" — with
  `on_full: absent` it cannot, with `on_full: error` it can), and scheduling
  hints. Every fact it reads is already declared and already checked.

- **#67 — actor isolation as a checked property.** A handler declaring no
  effects provably cannot touch anything outside its actor. Turns the
  informal isolation promise into a machine-checked one.

### Because "declares no effects" is itself a useful predicate

- **#68 — generated property tests.** Property testing is normally too
  expensive to adopt because you write both the generator and the oracle. Here
  the user has often written both already, for other reasons: an effect-free fn
  is safe to call with arbitrary input, and the return type's `invariant:` block
  IS the oracle — already compiled into a validator in all three backends
  (`proc validate*` in `examples/15-type-attributes.nim`). `spanOf -> Chunk` in
  the web-downloader is the worked example: four ints in, three invariants
  asserted, zero test code written. Distinct from `tests/suites/fuzz_corpus.nim`,
  which fuzzes THE COMPILER.

- **#69 — opt-in memoization.** Effect-free plus total means a repeated call
  with equal arguments is redundant, so memoizing is LEGAL. It is not
  automatically a WIN — a hashtable probe costs more than `a * b` — so the
  compiler checks the precondition and the author asks for the transform.
  Lives in `optimize.nim`, off unless `-O` names it.

- **#70 — the mock surface is computable.** Effects originate only at `extern`
  (verified: `semantics.nim` special-cases it nowhere), so a fn's true IO
  surface is the reachable-extern set — a walk propagation already performs and
  then discards. `downloader.tuck` type-checks but cannot RUN because
  `netdl.h` does not exist; its mock surface is exactly `dial, ask, take,
  putAt, onDisk, sizeOf, say`, and a generated stub module is what would make
  it runnable. Every backend already emits a body-less signature with a
  substitute body (`genPendingStub` × 3); a recording mock is that shape.

### The trust root

- **#71 — effects have no unforgeable base.** Filed as `design-gap`, not
  `enhancement`. Effects originate only from declared signatures and `extern`
  is special-cased nowhere, so a module mints its own primitives and describes
  them as it likes. Spiked both directions: an unannotated `extern puts` lets a
  fn declaring NO effects call libc and `tuck ch` answers OK; adding `[io]` to
  that one line correctly rejects it. So the machinery is right and the
  annotation is simply the declarer's to write. **Against mistakes the system
  works; against an adversary it does not**, and the spec should say so rather
  than let readers infer a stronger guarantee. The real fix is a MODULE-SYSTEM
  change (an extern's effects supplied by the importer, or `extern` refused in
  an untrusted module), not an effect-system one — the machinery underneath
  needs nothing new. The cheap half is the spec paragraph, and it is worth
  doing on its own.
