---
date: 2026-08-11T08:43:14+00:00
session_name: spec-code-audit
researcher: Claude
git_commit: b336ba2
branch: claude/spec-code-audit-34xh4q
repository: tuck
topic: "tuck-spec.md vs. the actual compiler: what's stale, what's undocumented, what's untested"
tags: [spec, audit, effects, actors, interfaces, gaps, discrepancies]
status: complete
last_updated: 2026-08-11
last_updated_by: Claude
type: state_of_the_project
---

# Handoff: spec-vs-code audit, and where the project's own docs disagree with the tree

Requested task: compare `tuck-spec.md` (the canonical spec) against the actual
compiler, using git history for recorded decisions, and flag gaps that lack a
regression test. Instruction from the requester mid-session: **treat every
markdown status doc (ROADMAP.md, MISSING-FEATURES.md, TODO.txt, findings.md,
TOUR-GAPS.md) as potentially stale** rather than authoritative — so every
claim below was re-verified against the built compiler, the source, or git
history directly, not copied from those files. Where a status doc's claim
held up under re-verification, that's noted; where it didn't, that's noted
too — several didn't.

## Method

1. Built the compiler fresh (`choosenim` → Nim 2.2.10, `nimble install
   msgpack4nim jsony`; the environment had no Nim toolchain at all going in).
2. Ran `./run-all-tests.sh` for real — this is the project's own authoritative
   gate (per MISSING-FEATURES.md's own instruction: "run the checks rather
   than trusting the text"). All 25 suites pass; the two `OPEN` markers
   (`interface_seq`, `member_names`) both still reproduce, so that doc's
   headline claim ("2 open bugs") held up.
3. For every concrete claim in `tuck-spec.md`, wrote a minimal `.tuck` file
   and ran it through the actual `tuck` binary (`check`/`compile`), or read
   the relevant compiler source directly, rather than trusting prose.
4. A background agent read the **full** git history (318 commits, after
   `git fetch --unshallow` — the checkout was a 50-commit shallow clone) for
   every commit that records a design ruling, cross-referenced against the
   spec sections above.

**Coverage gap, disclosed up front:** the Odin backend could not be
build-verified here — no `odin` toolchain in this sandbox, and GitHub access
this session is scoped to `kobi2187/tuck` only, so the Odin release couldn't
be fetched either. Everything below that touches Odin is from source-reading
and the project's own test-list structure (`odin_backend.sh`'s gated example
lists), not a live `odin build`. `odin_backend.sh` itself silently reports
"0 passed, 0 failed" and exits clean when the toolchain is absent — worth
knowing, since that means CI could be silently not-checking the Odin path
too if it doesn't set `TUCK_REQUIRE_ODIN=1`.

---

## A. Spec describes a mechanism the code doesn't have (highest severity)

These aren't wording nits — the spec's description of *how the feature
works* is the opposite of what ships. A reader implementing against the spec
would build the wrong thing.

### A1. Actors/Tasks (§9.1–9.4): "stackless" vs. the actual stackful OS runtime

Spec, `tuck-spec.md:1180-1181`:
> Compile to stackless coroutines — explicit state machines with static ring
> buffers. Suitable for 32KB Cortex-M0 environments

and `§9.4` (line 1232): *"No preemption, no kernel context switches, **no
per-task stack allocation**."*

Reality (`compiler/tuck_coro.nim:1-13, 56-66`): actors and tasks run on
**stackful** coroutines via vendored `minicoro`, built with
`MCO_USE_VMEM_ALLOCATOR` — every coroutine reserves a `mmap`/`VirtualAlloc`
virtual-memory stack (minicoro's own default under that flag is ~2MB;
`tuck_async`'s `TuckStackSize` is 1MB). The reactor is `std/selectors`
(epoll/kqueue). This is a **POSIX-hosted-only** runtime — `mmap` and epoll
don't exist on a bare Cortex-M0. A single actor's coroutine stack reservation
alone would blow the "32KB" budget the spec claims the design targets.

This isn't a stale doc — it's a recorded **reversal**. Git commit `bdd4788`:
*"step back from hand-rolled actors/schedulers/C-coroutines"*; `c07b028`:
minicoro breakthrough; `20a9b0c`: actors+tasks unified onto this one runtime.
ROADMAP.md:23-28 records the ruling ("Runtime strategy SETTLED... stackful
coroutines... Neither nim-cps nor hand-rolled stackless state machines") but
`tuck-spec.md` Part 9 was never rewritten to match — it still describes the
rejected design.

**Why this matters more than a typo:** Part 1 of the spec frames the whole
language around embedded/Cortex-M targets. If actors/tasks as currently
built are hosted-OS-only, that's a scope claim the rest of the spec leans
on, not an implementation detail.

### A2. Interfaces (§5.3, Appendix B): "borrows, doesn't copy" vs. the actual copying variant

Spec, `tuck-spec.md:830-869`:
> It is a **two-word pair: a reference to the data, and a reference to the
> function table**... **The data reference borrows. It points at the object,
> not a copy** — so mutation through an interface value is visible to the
> original, and no allocation or copy happens at the boundary.

And Appendix B (line 1518): *"Vtables (dispatch is fat pointer field reads)"*,
(line 1519) *"no runtime type... nothing can ask 'what is this really?'"*

Reality (`compiler/codegen.nim:569-580, 604-618, 1780-1799`), verbatim
comments in the emitter:
> `# A concrete object entering an interface slot is COPIED into the variant`
> `## ...the semantics: an interface value OWNS its data.`
> `# An interface value is a VARIANT over the types that satisfy it: a tag...`

This is the **opposite** design: a copying tagged union with dispatch by
switch-on-tag, not a borrowing fat-pointer pair. It's a recorded, deliberate
reversal — git commits `94cfcfc`→`1505544` delete the borrow-pointer
implementation (vtables, per-type thunk tables, and the escape-analysis
solver that was built specifically to make borrowing sound — commits
`78644f5`, `547be5d`, `3a25f51`, `202a6a2`) and replace it with the copying
variant. ROADMAP.md:91 records the current state correctly; the spec was
never brought in line.

**Follow-on question this raises, not just a doc fix:** §5.3's storability
restrictions ("not legal as an object/actor field, nor as a return type") are
justified in the spec entirely by borrow-safety reasoning ("the object is
always in an enclosing scope"). Under copy semantics that reasoning doesn't
apply — copying removes the lifetime hazard the restriction exists to
prevent. Worth a real ruling on whether those restrictions still make sense,
rather than just rewriting the mechanism description and leaving stale
restrictions bolted onto a design that no longer needs them (see Q3 below).

### A3. Effects (§3.7): "implicit propagation" vs. the actual require-declared checker

Spec, `tuck-spec.md:386-388`:
> Effect markers propagate upward — a function that calls an `[io]` function
> is **itself implicitly `[io]`**. The checker verifies this.

Reality — verified directly, not just read:

```tuck
fn helper({n: int}) -> int [io]:
  return n
fn caller({n: int}) -> int:      # no [io] declared
  return n helper
```

```
$ tuck check
Semantic Error: Expression requires effect [io], which is not allowed
in context of 'caller'
```

`compiler/semantics.nim:11-14` (comment, verbatim): *"The rule this file
enforces: a function may only perform effects **it declares**. Call an
`[io]` function from one that never declared `[io]`, and that is an
error."* That's mandatory explicit declaration, not implicit inference —
the opposite of "itself implicitly `[io]`". ROADMAP.md:29-31 already flags
this exact gap ("the ruling is implicit propagation; the checker still
makes you declare") but it dates from 2026-07-09 and nothing has changed
since — this is over a month of drift between a recorded ruling and both
the spec and the implementation.

Note this cuts against the "propagate upward" framing narrowly — the
*upward-requirement* propagates (declaring `[io]` is contagious up the call
graph, you can't hide it), but the *permission* does not auto-grant. Whether
that's actually the better design is Q2 below — Tuck's "everything explicit"
philosophy (Part 1) arguably fits require-declared better than silent
inference would.

---

## B. Spec describes syntax/behavior the parser rejects outright

Each of these is a spec code example that does not compile against the
current tree, or a described rule that's now a parse error.

### B1. §3.3 precedence table still lists bare `/`, which is a hard parse error

`tuck-spec.md:309`: `Precedence (high to low): * / % → + - → ...`

```
$ tuck check   # `let b = a / 4`
[Parse Error] `/` is not an operator in Tuck — write `/i` for integer
division (truncating) or `/f` for float division...
```

This is ruling **R1** (`TODO.txt:49-54`, git commit `0212973`), pinned by
`known_bugs.nim` bug #1, with a dedicated example (`38-division`) gated on
both backends. `tuck-spec.md` has **zero** mentions of `/i`/`/f` anywhere —
not just an omission, the precedence table actively shows a token that no
longer parses.

### B2. §3.5's own `bake` example doesn't parse; only the un-shown form does

Spec's worked example (`tuck-spec.md:328-330`):
```tuck
let y = x.bake {someFunc: :add}
```
```
$ tuck check
[Parse Error] Expected field name after '.'
```
The working form — confirmed against `examples/03-functions-bake.tuck`,
which is green in the suite — drops the dot:
```tuck
let y = x bake {someFunc: :add}   # parses, checks OK
```
Small, but it's a direct counterexample to the spec's own universal-call
claim in §2.3 ("whitespace, `.name`, and `.name {args}` are the same call
form") for at least this one keyword, and it means copy-pasting the spec's
own §3.5 example doesn't work.

### B3. §3.6 `pred`/`set` prefixes: not implemented at all, not even lexed

`tuck-spec.md:336-349` presents `pred isReady() -> bool` and
`set volume(...)` as working syntax with enforced constraints. There is no
`pred`/`set` keyword in `lexer.nim`'s keyword table and no reference to
either anywhere in `compiler/parser*.nim` — this was never started, not
partially built. ROADMAP.md's "Missing" list agrees. No commit in the full
318-commit history implements or explicitly drops it — genuinely unclear
whether this is abandoned-but-not-removed, or still intended (Q4).

### B4. §8.3 `when TARGET` conditionals: a dead keyword

`tkWhen` is in `lexer.nim`'s keyword table (line 127) but is never referenced
anywhere in `compiler/parser*.nim` — it's lexed and then nothing consumes it,
so any `when` block in source hits a generic parse error. Matches
ROADMAP/TODO.txt's "Missing"/G5 entries.

### B5. §7.4 Resource Registry: ~90 lines of detailed spec, 0% implemented

`tuck-spec.md:1040-1129` is one of the most detailed sections in the whole
document — declaration syntax, handle/generation semantics, `defer` release
policy (strict/lazy/exit), watermark sweeping, static tracking rules. None
of `resources:`, `defer`, or `[resource: k]` exist anywhere in the
lexer/parser (`grep` for all three returns nothing). This is fully designed
and fully unbuilt — TODO.txt's G4 agrees, but note TODO.txt files this under
`area: spec` rather than `area: lang`, i.e. even the project's own tracker
treats it as a documentation exercise rather than a build task, which may or
may not be the intent (Q5).

---

## C. Spec claims an enforcement that doesn't run where claimed

### C1. §6.3 Complexity limit: not a compiler error

Spec, `tuck-spec.md:954-956`: *"The compiler enforces a cyclomatic
complexity limit of ≤ 5... **This is not a linting suggestion — it is a
compile error.**"*

Verified: a 6-branch function (`if` ×6, cyclomatic complexity 7) compiles
clean —
```
$ tuck check /tmp/complex6branch.tuck
OK (1.8 ms)
```
The actual complexity measurement lives entirely in `tools/cc.nim` — a
**separate standalone binary** that imports the Nim compiler as a library
and re-parses the *emitted Nim output*, invoked only by `tests/complexity.sh`.
It is not called anywhere in `tuck.nim`'s pipeline. So the spec's claim that
*the compiler* enforces this as a compile error is false as built: it's an
opt-in external linter over generated code, several steps removed from
`tuck check`/`tuck compile`. Either the spec needs to describe it as an
external tool, or `tools/cc`'s logic needs wiring into the real pipeline —
these are very different amounts of work, so this is a real question (Q6),
not just a wording fix.

### C2. §5.4 `pending` blocks: one mode exists, spec describes three

Spec, `tuck-spec.md:900-901`: *"Compiler flags control runtime behavior of
`pending` functions: **trap (default in debug), return zero value (release
stub), or log and continue**."*

`compiler/codegen.nim:1116-1126`, the entire implementation:
```nim
# Pending stub: logs on invocation, returns the zero value (Nim zero-inits result).
proc genPendingStub(d: Decl): string =
  ...
  return "proc " & fnNameSanitized & ... &
    " =\n  stderr.writeLine(\"TUCK PENDING: " & d.name & " invoked (not implemented)\")\n"
```
One unconditional behavior (log + zero-init), every build. No trap/panic
mode, no compiler flag selecting between the three.

---

## D. Silent-wrong-answer gaps with zero regression-test coverage

These are the ones worth prioritizing regardless of what happens to the
spec text, because the failure mode is silence, not an error — exactly the
"code isn't feature-complete, tests should record the gap" ask. This
project has a strong existing convention for exactly this
(`tests/suites/known_bugs.nim`, the `bug_open`/`bug_fixed` marker pattern) —
neither of these is in it.

### D1. Constructing a type with missing required fields passes the checker silently

```tuck
type Config:
  port: int
  timeout: int

fn main() -> int:
  let c = {} Config    # zero fields supplied
  return 0
```
```
$ tuck check
OK (1.2 ms)
```
`compiler/typecheck.nim:1504-1512`, the `{fields} TypeName` construction
path, synthesizes each *supplied* argument's type and returns the named
type — there is no check that the supplied field set matches the type's
*declared* field set. Contrast with the function-call path (same file,
lines ~300, ~1278), which does check and produces `"...is missing required
field '...'"`. Grepping every `"missing required field"` test in
`tests/suites/typecheck.nim` (7 hits) confirms all of them exercise the
function-call path; none construct a type directly with fields omitted.

This appears to directly contradict a ROADMAP-recorded ruling
(`ROADMAP.md:19-22`, 2026-07-09): *"`Foo {}`: legal only when the type has
no fields... Types with fields require every field at construction; absence
must be explicit `?T`."* Either that ruling was never implemented, or it
regressed since. Either way: what do the unfilled fields actually contain
at runtime right now? That's worth answering before writing the fix (Q7).

### D2. `on select` with an unrecognized arm shape silently emits `discard` — no error, no warning, nothing

```tuck
task handleConn({conn: int}) -> void:
  on select:
    | timeout.5s -> {}: return
```
This is close to the spec's *own* §9.3 example verbatim. It passes `tuck
check` with **zero** diagnostics, then compiles to:
```nim
proc tuck_handleConn*(conn: int): void =
    discard  # select: only read+timeout arms supported (first cut)
```
The entire handler body is dropped. `compiler/codegen.nim`'s fallback arm
(around the `genSelect` logic) is a literal comment admitting the gap, but
it's a code comment, not a diagnostic — no `PENDING` report entry, no
`SHORTCUTS` entry, no compile warning. Grepping the whole test tree for this
pattern (`"only read.*timeout"`, `"first cut"`, `select.*discard`) returns
nothing — it's not pinned anywhere. MISSING-FEATURES.md/TODO.txt (G3) know
the *feature* is unfinished ("dotted sources parse as opaque strings,"
blocks example 16), but neither flags that the failure mode is **silent
data loss** rather than a compile error — which is a materially different
severity, and exactly the class of bug this project's own `PENDING`/
`SHORTCUTS`/`OPEN RESOURCES` reporting philosophy (spec §5.4, §4.9, §7.4)
exists to prevent everywhere else (Q8).

### D3. A function can declare `[irq_safe, may_block]` on itself — no rejection

Smaller, but same shape: `[may_block]` on a function called from a fn that
doesn't declare it already errors correctly (verified — the generic
"undeclared effect" mechanism catches it, so MISSING-FEATURES.md's claim
that `[may_block]` "has no checker meaning" appears to be **stale** on that
specific point). But a function is free to declare **both** `[irq_safe]`
and `[may_block]` on *itself* — self-contradictory (a fn safe to call from
an interrupt handler cannot also block), and nothing rejects the combination.
No test covers this either direction.

---

## E. Code ahead of the spec (implemented + tested, never documented)

Not everything drifted the same direction — some shipped, tested features
have no spec coverage at all.

- **`alias`** — the field-renaming construction operator
  (`value alias(field: newField, ...)`). Implemented, tested
  (`examples/18-alias.tuck`, green), referenced by ROADMAP.md as DONE. The
  canonical spec mentions it exactly once, in passing, contrasting it with
  `merge`/`bake` (`tuck-spec.md:195`) — no syntax, no semantics, no worked
  example anywhere in the document.
- **Numeric conversion sigils `~T`/`^T`** (rulings R5/R6, `TODO.txt:64-93`,
  git commit `e61d165`) — this one cuts the other way: it's a *recorded*
  ruling, tracked as `G11`/`G12` and marked `OPEN` (not yet implemented —
  confirmed, no `~`/`^` handling anywhere in the lexer). Spec's own
  "Appendix A: Open Questions" list (the place this belongs) doesn't mention
  numeric-conversion sigils at all, so even as a *planned, undecided* item
  it's invisible from the spec side.

---

## F. Where §11/§12 (compiler architecture) stands

This one was already flagged by the project's own docs weeks ago
(`findings.md:30-32`, 2026-07-05; `ROADMAP.md:121-124`, "Spec debt... Rewrite
§11 to match implementation, as was done for §4.8") and **still hasn't been
touched** — `tuck-spec.md:1283-1483` still describes:
- an **npeg** grammar-based parser (`§12`'s entire "Grammar Sketch (npeg)"
  section) — reality is a hand-rolled recursive-descent parser across
  `compiler/parser.nim`/`parser_expr.nim`/`parser_type.nim`; no npeg
  dependency exists anywhere in the tree.
- a **flat `seq[IRNode]`, index-based IR** — reality is a `ref object` tree
  AST (`compiler/ast.nim`'s `Decl`/`Expr` are ref types with child
  pointers), never flattened.
- a **Merkle-hash cache with an `AnalysisEnvelope`** (Summary/BaseIR/
  Specialized slots) — reality (`compiler/modules.nim`) is a msgpack-based
  signature-index cache, real but shaped differently than described, and
  not Merkle-keyed.

This is the largest single stale section by volume, and — per the ROADMAP
note referencing §4.8 as the precedent — the project has a working pattern
for how to fix this kind of thing (rewrite the section to match reality)
that just hasn't been applied here yet.

---

## G. Calibration: what did NOT turn out to be stale

Worth naming so this doesn't read as "everything is wrong" — several
spec sections matched the tree exactly on direct verification:

- §4.1 overflow attributes (`[saturating]`/`[wrapping]`/`[trapping]`,
  clamp-at-storage-not-per-operator, never stripped in release) — matches
  ruling and code exactly.
- §4.7 invariants (block-form only, no inline/attribute form) — matches the
  `9acb8ac` ruling exactly; the spec text already reflects a *correction*
  made after an earlier attempt.
- §4.8/§4.9 error model (declared enums, `err X`, `.ok`/`.value` narrowing,
  `strict`/`continue`/`exit` policy, `SHORTCUTS` report) — verified present
  and wired into `checkOrDie`.
- §2.5 composition rename-conflict rule ("no automatic resolution, user
  renames at the composition site") — matches `c0e9d47` exactly.
- MISSING-FEATURES.md's specific "2 open bugs" claim — reproduced live,
  still accurate.

And a caution the other way: **`TODO.txt` itself is measurably stale**,
which matters since it's the project's primary bug/gap ledger. It lists
`B1` ("[saturating] does not clamp on Odin") and implicitly `B2`
("`on select` not lowered on Odin") as `OPEN`, but the current
`known_bugs.nim` suite — which I ran — shows the saturating-Odin case as
`bugFixed` and passing, and `27-actor-select` is odin-compile-gated. The
file's own last-updated marker is 2026-07-28, about two weeks before this
audit. This is the same drift pattern as the spec, just in a different
document — worth re-running `TODO.txt`'s BUGS section against
`known_bugs.nim` before trusting it for planning.

---

## Open questions for a ruling (collected, not answered here)

1. **Effects (§3.7):** keep the spec's "implicit propagation" as the target
   and change the checker to match it (ROADMAP already leans this way), or
   formally re-rule to require-declared (arguably fits "everything explicit"
   in Part 1 better) and fix the spec text instead? This has sat as a known
   gap since 2026-07-09 with no resolution either way.
2. **Actors/Tasks (§9):** is the hosted-OS stackful-coroutine runtime the
   permanent design, or is a bare-metal/stackless path still intended
   eventually? If permanent, Part 1's embedded-target framing and §9.1's
   "suitable for 32KB Cortex-M0" claim need to change, not just §9's
   mechanism description — this is a scope claim, not an implementation
   detail.
3. **Interfaces (§5.3):** now that dispatch is a copying variant rather than
   a borrowing pointer pair, do the storability restrictions (no
   object/actor field, no return type) still need to exist? Their stated
   rationale (borrow-safety) no longer applies under copy semantics.
4. **`pred`/`set` (§3.6):** dead letter or still planned? No commit builds
   or explicitly drops it across the full history.
5. **Resource registry (§7.4):** ~90 lines of detailed spec, 0% built, and
   even `TODO.txt` files it under "spec" rather than "lang" — still the
   intended design, or has it been superseded/deprioritized?
6. **Complexity limit (§6.3):** should `tuck check` itself enforce this
   (matching the spec's "compile error" claim), or is `tools/cc` as a
   separate opt-in linter the actual intended final shape (in which case the
   spec text needs to say "a separate tool enforces this," and it probably
   wants wiring into `run-all-tests.sh`'s main gate, not just its own
   suite)?
7. **`{} Type` construction (§4.8):** the ROADMAP ruling that non-empty
   types require every field at construction was apparently never
   implemented (or regressed). What should currently-missing fields contain
   at runtime in the meantime — is this silently producing zero-initialized
   garbage today?
8. **`on select` fallback (§9.3):** should an unrecognized arm shape be a
   hard compile error (matching the project's own PENDING/SHORTCUTS
   philosophy of surfacing every unfinished path) rather than a silent
   no-op, even before the dotted-source feature itself is finished?

## Suggested immediate action, independent of the above rulings

D1 and D2 (silent missing-field construction, silent `on select` discard)
are correctness bugs today, not documentation debt — they produce wrong
programs with zero diagnostic. Whatever happens to the spec, these two
would benefit from `known_bugs.nim`-style pinning entries now (as
`bug_open`, per the project's existing convention) so they're at least
visible and can't regress further in silence while the design questions
above get resolved.
