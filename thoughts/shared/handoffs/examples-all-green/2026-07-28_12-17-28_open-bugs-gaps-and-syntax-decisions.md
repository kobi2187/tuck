---
date: 2026-07-28T12:17:28+03:00
session_name: examples-all-green
researcher: Kobi
git_commit: b0bbff3
branch: main
repository: tuck_lexer
topic: "Open bugs, missing features, and the syntax decisions still outstanding"
tags: [bugs, gaps, syntax-decisions, stdlib, ffi, odin, roadmap]
status: complete
last_updated: 2026-07-28
last_updated_by: Kobi
type: state_of_the_project
---

# Handoff: what is broken, what is missing, what still needs deciding

Written after the FFI/Beef-removal/refactor session (11 commits, `b807c8e..b0bbff3`).
Everything below was **verified against the current tree**, not copied from the
older docs — several entries in `MISSING-FEATURES.md` turned out to be stale.

## Task(s)

Survey task, complete. No code work is in flight. The tree is green:
**31 Odin compile / 8 run, 25 Nim `nim check`, typecheck / mangle / parser /
known_bugs all passing.**

## What changed this session (context for everything below)

- **C FFI is finished and run-verified on both backends**: functions, `cstring`,
  structs by value, enums with explicit values, callbacks, opaque handles.
  Examples 33–37, each gated on an exit code against a real C library
  (`examples/cffi/point.c`).
- **The Beef backend is gone** (~2385 lines). Odin is the second backend.
- **`codegen_shared.nim` → `ast_query.nim`**, and the ~60 open-coded AST scans
  in the backends, lowering and the type checker now go through named helpers.
- **The Odin coroutine runtime turned out to already work** — see A1.

---

## A. Bugs — verified real, with the evidence

### A1. ~~Odin has no coroutine runtime~~ — FIXED THIS SESSION, but read this

The long-standing belief (encoded in a code comment and in the previous
handoff) was that Odin tasks run inline for lack of a runtime. **False.**
`compiler/tuckrt/tuck_coro.odin` is complete and correct over minicoro. The
driver simply copied *one of the three files* in `compiler/tuckrt/`, so
`tuck build --odin` died with `'tuckAsyncInit' is not declared by 'rt'`.

Fixed in `b0bbff3`. `28-async-task` now exits 42 on Odin, gated.

**The lesson worth keeping:** this was invisible because `tests/odin_backend.nim`
copies the whole runtime directory into its own project dir, so the gate passed
while the actual CLI was broken. *A test harness that stages files differently
from the driver can hide a driver bug indefinitely.* Worth an audit of any other
place the two diverge.

**The narrower ceiling that remains is real**: task bodies are emitted as plain
procs and are not spawned ONTO the runtime, so suspension points run inline
(`compiler/codegen_odin.nim:1701`).

### A2. `[saturating]` does not clamp on Odin — backend divergence

`tests/known_bugs.nim` #4. Nim clamps via `saturatingBase` (`codegen.nim:176`);
Odin emits a bare `SafeRPM(70000)`. **The same program wraps on one backend and
clamps on the other** — the worst class of bug this project can have, and the
reason the parity commitment exists.

Fix: mirror `saturatingBase` into `compiler/codegen_odin.nim`.

(The entry used to test the Beef backend; I repointed it at Odin this session
and confirmed the gap is genuinely there.)

### A3. `on select` is not lowered on Odin

`compiler/codegen_odin.nim:995` documents it; `29-task-timeout` and
`30-async-read` fail to build on Odin (`Expected 1 return values, got 0`).
`rt.tuckAwaitReadOrTimeout` exists in the runtime for exactly this; the branch
lowering is unwired.

### A4. Four open known-bugs (`tests/known_bugs.nim`, run it — it is the truth)

1. **`/=` on ints emits float `/`** — integer compound-divide picks Nim's
   float-returning `/`.
2. **`toStr` under `+` loses str-ness** — `n.toStr + "x"` picks numeric `+`.
3. **`if` has no expression form** — `let x = if c: a else: b` unsupported.
4. **A type argument named like an attribute fails** — `Box[error]` parses as
   `[error: ...]` because the parser decides attribute-vs-generic from a
   hardcoded 19-name word list (`parser_type.nim:128`). Fix is to decide by the
   *declared* set, not a literal list.

### A5. Two examples do not compile at all

- **`16-actor-tasks-unified-syntax`** — `.fn {args}` on undeclared `copyFrom`.
  Pre-existing; I confirmed it fails identically on `b807c8e`. In **no** test
  suite, so nothing catches it.
- **`20-embedded-mp3-player`** — MMIO register-field access (`DAC_CR.EN`) is
  unimplemented, and `transitionTo`-with-payload inside an actor handler emits
  garbage.

### A6. Examples emit into a shared directory, which collides on Odin

`tuck compile --odin` writes `<name>.odin` next to the source. Odin builds a
*directory* as one package, so two emitted examples in `examples/` collide
(`Redeclaration of 'tuck_Config'`). The test harness works around it by copying
each example into its own dir. Not urgent, but it makes the CLI awkward and it
cost me time twice this session. `-o:` per example is the workaround.

---

## B. Missing features, in the order they block real programs

1. **Task spawning on Odin** (A1's remainder) — until then Odin's async is
   structurally present but semantically synchronous.
2. **`on select` lowering on Odin** (A3).
3. **Real async I/O externs.** std fs/io/sys are BLOCKING externs over Nim's
   sync stdlib. There is no socket recv or async readFile that yields through
   the reactor, so `29-task-timeout` races a *placeholder idle pipe*. The
   timeout mechanism is proven; there is simply nothing real to race yet. This
   is the single biggest gap between "the async design works" and "async is
   usable".
4. **Typed select sources.** `on select` arms only lower `read <fd>` and
   `timeout <ms>`. `resp.ok` (future readiness) and `timeout.5s` (duration)
   parse as opaque strings. Needs typed SelectSource variants + `5s` duration
   lexing. Blocks example 16.
5. **Resource kinds (spec §7.4)** — designed, unimplemented. Matters *now*
   because every file-handle and socket signature should declare its kind from
   day one or the sigs churn later.
6. **`when TARGET` conditionals (§8.3)** — blocks the embedded examples.
7. **MMIO register-field depth** — nested bitfield writes (A5).

---

## C. Syntax and design decisions still outstanding

### C1. FFI surface — settled, but two loose ends

The block now takes `fn`, `type`, and `fnsig`. Two things I would raise before
the next FFI push:

- **`emit:` is usually redundant.** It names the real C symbol, but externs are
  already unmangled, so `fn compressBound(...) [emit: "compressBound"]` is an
  echo. Keep the key for the escape-hatch case (a C symbol that is not a legal
  Tuck identifier), but the examples should stop writing it when it matches.
- **`cstring` vs `cstr`.** Tuck accepts both `string` and `str`; `cstring` has
  no short form. Minor, but the asymmetry is odd and cheap to fix now.

Not loose ends, deliberately settled: `lib:` takes a bare name or a path to a
vendored `.c`; declaring a thing *inside* the extern block is what makes it
foreign; a fieldless extern type is an opaque handle.

### C2. Generic containers vs the extern mechanism — **the big one**

`stdlib-blocks.md` §9 calls this "the biggest open design question", and it is
still unmade. Map/Set/Deque need either checker-blessed types (the `Seq` route)
or generic externs. **Everything in §9 below the `Seq` rows is blocked on this
one ruling.**

New evidence from this session that bears on it: generic externs *do* work now.
`std/str.tuck`'s `fn toStr[T]({value: T}) -> str` was broken on Odin all along
(it emitted `value: T` instead of `value: $T`, so *every* generic extern failed
to compile); that is fixed. So "generic externs" is no longer hypothetical —
it is a demonstrated, working mechanism, which should make the ruling easier.

### C3. Collection call style

Free fns (`{xs, x} push`) vs chain mutation (`xs ..push {x}`). Interacts with
the `set`-fn rule (§3.6). Note the settled call-syntax decision (payload / bake
/ dotArg = three lifetimes) does not cover this case.

### C4. Derive-style codegen for records

`fmt`, `hash` and `json` all block on the same ruling: Tuck has no reflection,
so per-record `toStr`/`hash`/`encode` must be compiler-derived or hand-written.
One decision, three payoffs.

### C5. Bytes representation

`Seq[u8]` everywhere vs a distinct binary type (BEAM-style). Affects §3 slicing
semantics and the string↔bytes seam. **The FFI work makes this more urgent
than it was**: `cstring` now exists as a C-boundary type, and any real byte API
(`recv`, `read`, zlib's `compress`) needs to say what a buffer *is*. Deciding
this late means re-cutting every byte-taking signature.

### C6. Compiler-lowered vs stdlib for checked arithmetic

`[saturating]`/`[wrapping]`/`[trapping]` are spec'd as type attrs; the rt
helpers are stdlib-bottom but the lowering belongs to codegen. A2 is the live
consequence of this split not being finished.

---

## D. Does `stdlib-blocks.md`'s path forward still make sense?

**Yes, and the FFI work strengthens it — but two of its assumptions have moved.**

The report's core bet is that ~60% of the bottom layer is `extern (direct)`:
Nim procs usable as-is behind an `extern:` signature. That bet is now
*better* supported than when it was written, because this session proved the
extern mechanism handles far more than scalars: structs by value, enums,
function pointers, opaque handles, and generic type parameters all work, on
both backends, verified by running binaries.

**What has changed and should be reflected in the document:**

1. **The doc still says "Beef runtime (tuck_rt.bf) mirrors all of these"**
   (line ~297). Beef is gone. Every `extern (direct)` row now means *two*
   backends, and the Odin side is not free — the `[saturating]` gap (A2) is
   exactly the kind of divergence that will bite when the rt helpers land.
   **Recommend: add a "both backends" column, or state the parity rule once at
   the top.**

2. **The classification is Nim-shaped.** "Nim mapping" is the only mapping
   column, but an `extern (direct)` row is only free on Odin if Odin's core
   library has the same thing. `bitops.countSetBits` → Odin's
   `intrinsics.count_ones`, fine; `strutils.split` → Odin has no direct
   equivalent returning the same shape. **Recommend: spot-check the ~15 rows
   most likely to diverge before committing to the effort estimate**, because
   "≈60% direct" is currently a Nim-only number and the real figure for
   two backends is lower.

3. **§14's `lib:` story is now solved.** The doc predates the linking
   mechanism; any OS/hardware block that needs a system library
   (`-lasound` for the volume example in the line-9 decision note) can now be
   bound directly with `extern [c, header: "...", lib: "..."]`. **The line-9
   decision — "allow all hardware and OS access" — is now mechanically
   achievable**, which was not obviously true when it was written.

4. **§9's blocker (C2 above) is the one real dependency**, and it now has more
   evidence to decide on (generic externs demonstrably work).

**Sequencing recommendation.** The doc lists domains, not an order. Given what
is now true, the highest-value first moves are:

- **§2 strings + §18 radix/builder** — pure, no wrappers, no blocked
  decisions, and immediately makes example code less awkward.
- **§5 integer semantics** — because A2 is already a live bug and the rt
  helpers plus lowering fix it properly rather than patching one backend.
- **§12 monotonic clock + §17 panic** — tiny, and everything else debugs better
  with them.
- **Defer §9 (collections) until C2 is ruled**, and defer §15 (net) until C5
  (bytes) is ruled — those two rulings gate more surface than any other.

Nothing in the report looks wrong. It looks like it was written before the
extern mechanism was known to be this capable, and it is more achievable now
than it claims.

---

## Critical References

- `tests/known_bugs.nim` — **run this, it is the source of truth** for open
  bugs; the prose in `MISSING-FEATURES.md` drifts.
- `tests/odin_backend.nim` — the gate that matters: examples must RUN with the
  expected exit code, not merely compile.
- `compiler/ast_query.nim` — the AST query vocabulary. Add a helper here rather
  than open-coding a decl scan.
- `examples/cffi/point.c` + examples 33–37 — the FFI conformance set.
- `compiler/codegen_odin.nim:995` (`on select`), `:1701` (task spawning) — the
  two documented Odin ceilings.
- `stdlib-blocks.md` — the bottom-layer plan discussed in section D.

## Post-Mortem

### What worked

- **Building a real C library and running the binary.** Every FFI claim this
  session was settled by an exit code, not by reading emitted source. Two bugs
  (enum numbering, callback ABI) compiled perfectly and returned wrong answers;
  nothing short of running would have caught them.
- **Checking a claim against the tree instead of trusting the previous
  handoff.** The last handoff said `externEmit` was dead — it was not, it just
  parses somewhere unexpected. The code comment said Odin had no coroutine
  runtime — it did. Both cost minutes to verify and would have cost hours to
  act on.
- **Deleting the Beef backend before refactoring.** 2385 fewer lines meant the
  refactor was two-backend, not three, and immediately exposed four helpers
  that had been copy-pasted between them.

### What failed

- Tried: linking a vendored static archive through `{.passL.}` → Failed
  because Nim emits passL flags *ahead* of the object files, and an archive
  only contributes members that resolve already-pending symbols. Fixed by:
  `{.compile:}` on the `.c` instead. **Do not assume a `.a` and a `-lfoo`
  behave the same.**
- Assumption that a test suite passing means the CLI works → Failed: the Odin
  async gate passed for weeks while `tuck build --odin` could not build an
  async program at all (A1).
- Wrote a plan whose verification step asserted "exit code 307". An exit status
  is one byte. **Check that the observable you are asserting on can hold the
  value.**

### Key decisions

- Decision: a thing declared **inside** an extern block is foreign — no
  per-declaration `[c]` attribute.
  - Alternatives: an attribute on an outside-the-block declaration.
  - Reason: mirrors how a C header groups a struct with the functions taking
    it, and keeps the header/lib named once.
- Decision: a **fieldless** extern type is an opaque handle.
  - Reason: having no fields is precisely the property that makes it opaque —
    unknown size, pointer-only. No new syntax needed for the common case.
- Decision: remove Beef rather than maintain a third emitter arm.
  - Reason: never compile-verified here, and every FFI construct would have
    needed an arm nothing could check. The stale `[CLink]` code found in the
    Odin backend was a fossil of exactly that problem.

## Action Items & Next Steps

Ordered by value, with the cheap-and-live ones first:

1. **Mirror `saturatingBase` into the Odin backend** (A2). A live
   wrong-answer divergence, and `known_bugs` already asserts it.
2. **Audit driver-vs-harness staging** for other A1-class blind spots — any
   file the test harness copies that the driver does not.
3. **Spawn task bodies onto the Odin runtime** (A1 remainder), then
   **lower `on select`** (A3). These two make Odin's async real.
4. **Rule on C2 (generic containers)** — unblocks all of `stdlib-blocks.md` §9,
   and generic externs now demonstrably work.
5. **Rule on C5 (bytes representation)** before any byte-taking stdlib
   signature is written; §15 net depends on it.
6. **Start §2 strings** — no blocked decisions, immediate payoff.
7. Fix the attribute-vs-generic word list (A4.4) — the fix is known
   (decide by declared set) and it removes a whole class of surprise.
8. Either gate `16-actor-tasks-unified-syntax` or mark it explicitly
   unsupported; a broken example in no suite is invisible debt.

## Other Notes

- Odin lives at `/home/kl/apps/Odin/odin`, interactive PATH only —
  non-interactive shells need `export PATH="/home/kl/apps/Odin:$PATH"`.
- `tuck` CLI takes options AFTER the file: `tuck build examples/x.tuck --odin`.
- Clean `examples/*.odin` between Odin builds of different examples, or the
  package-level collision in A6 produces confusing redeclaration errors.
- The C fixture `examples/cffi/` ships `.c`/`.h` only; the `.o` is built on
  demand by both the driver and the test harness. Do not commit build products
  there.
- `stdlib-blocks.md` line 9 carries a standing decision — allow full hardware
  and OS access — which section D argues is now mechanically reachable.
