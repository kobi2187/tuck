# Missing Features & Gaps — snapshot 2026-09-12

Every claim below was re-verified against the compiler on the date in the
heading. The previous snapshot (2026-08-05) had drifted less than most: its
"2 open bugs" claim was still accurate on this pass. What changed this time is
coverage, not correctness — the Odin backend was actually built and
`odin build`/`odin run`-verified for the first time in a while (a nightly
binary, since GitHub access in that audit's sandbox was scoped away from
odin-lang/Odin), which is how the C1 "task with arguments" ceiling below
moved from "measured" to "attempted to reproduce, blocked by a separate
issue." If you are reading this more than a few weeks out, re-run the checks
rather than trusting the text — the suite is the source of truth, this file
is a summary.

**How to get the real list:** `./run-all-tests.sh` prints every `OPEN` line.
That is authoritative; this file explains them.

**For everything else** — design gaps, unimplemented features, checker and
backend bugs, diagnostics that misdiagnose — see `TODO.md`, which indexes
all of it in one place by category. This file stays focused on the pinned
open bugs and the measured async/concurrency gaps.

---

## A. Open bugs (7)

A bug here has a regression test written as the CORRECT behaviour, marked
`bug_open`. Fixing one means flipping the marker to `bug_fixed`, which locks
it in.

**A1 — an attribute name is reserved everywhere, not just inside brackets.**
`priority` names a field fine, but `fn priority(...)` is "Expected function or
event name" and `{priority: int}` as a parameter is rejected too. The TK-PA08
diagnostic states the intended rule in its own text — attribute names "are
reserved only inside brackets, so they stay usable as fields, parameters and
function names" — so the compiler contradicts its own explanation on two of
those three. Test: `known_bugs`, "an attribute name is free outside brackets".
Found 2026-09-12 writing `bake {key: :priority}` in `core/cmp`'s API doc; the
doc now says `:rank` to work around it.

**A2 — a fn with no declared return type accepts `return x`, and emits Nim
that does not compile.** `fn f({x: int}):` followed by `return x` passes
`tuck ch`, then `tuck c` writes `proc tuck_f*(x: int): void = return x` and
`nim c` answers "no return type declared". Whether omitting `->` should be
rejected outright or should mean `void` is a ruling; returning a value from
such a fn is wrong under either. Test: `known_bugs`, "a value returned from a
fn with no return type is rejected". Found 2026-09-12 checking TUTORIAL.md's
claim that a return type is mandatory — it is not.

**A3 — a `[read]` register field can be written.** tuck-spec 8.1 states both
directions: reading a `[write]` field is an error, writing a `[read]` field is
an error. Only the first is enforced (`TK-RE02`). Test: `known_bugs`, "writing
a [read] register field is rejected". Found 2026-09-12 auditing the spec's
error claims. (The emission this originally blamed turned out to be A5, a
separate and larger bug — the getter is emitted for EVERY register
assignment, `[write]` fields included.)

**A6 — on Odin only, an interface method may only return `int`.** The dispatch
closure is emitted as `proc(v: Iface) -> int` whatever the method returns, so
it is right by luck for `int` and wrong for everything else: an enum, `bool`,
`u8` and a record were all measured and all fail ("Cannot assign value
'(proc(v: Detector) -> int)(d)' of type 'int' to 'tuck_Demand'"). Odin has no
switch expression so its dispatch is wrapped in a closure
(`docs/interfaces.md`); the closure's return type is what is wrong. Nim and D
build all five. An interface whose methods return `bool` — a `Validator`, a
`Predicate` — is Nim/D-only today and nothing says so until the Odin build
runs. Test: `known_bugs`, "an interface method may return an enum".

**A14 — a group with two implementations cannot be used.** A group takes free
fns — an object's own member belongs to the `interface`/`satisfies` mechanism
instead, ruled 2026-09-13 and now refused with a message offering both routes.
Two free fns of one name in a single module is a Structure Error, so the
multi-provider case, which is the only reason to declare a group, is by
construction the CROSS-MODULE case — also the stdlib's shape, a module per
implementation. That then fails for a different reason: the bounded verb's body
calls the requirement UNQUALIFIED, and two imports exporting that name trip the
ambiguous-import rule before group dispatch is consulted — *"'reads' is exported
by 2 imports (sensa, sensb) — call it as 'sensa::reads' to say which"*.
Qualifying is exactly what the verb must not do; it has to reach whichever
provider matches `T`. `requirementKey`'s own doc comment anticipates the
situation ("a program may import two implementations of the same contract");
the call site never asks it. SINGLE-provider groups work end to end on all
three backends and are pinned, including cross-module. Issue #38. Test:
`known_bugs`, "a group bound picks the provider of the RECEIVER's type".

**A8 — a pool hands out a slot without validating it.** `Slots.acquire` on a
`pool Slots = Live [count: 2]` yields a zeroed slot, so with `invariant: n > 0`
the program can read `s.value.n == 0` — a value of the type that violates its
own invariant, which is the one thing an invariant exists to prevent. Whether
the fix is "acquire validates" or "a pooled type must have a valid zero" is a
ruling. Test: `invariants`, "a pool slot is validated before it is handed out".

**A12 — a pool slot cannot be read or written.** `acquire` now answers with a
handle that names the cell, which is what made `release` correct, but there is
no spelling for "the cell this handle names". So a pool still cannot be a DMA
target, a frame buffer, or anything hardware or another task fills in place —
which is what pools are for. `examples/25` says "hand b.value to the DMA
controller"; `b.value` is the handle and nothing takes it further. Wants a
read/write pair through the handle, plus a sanctioned way to give a cell's
ADDRESS to an extern — the one place a raw pointer is legitimate. Test:
`known_bugs`, "a pool slot can be read and written through its handle".

A4 (a group bound picking the LAST-declared provider — the conformance site
now selects by receiver type, the same way the two member-call paths have
since 2026-09-05, issue #38),
A11 (release freeing the wrong slot and leaking), A5 (a register assignment
lowering to the getter), A7 (an invariant not
firing after a field assignment), A9 (a handler payload field named `kind`),
A10 (D building the envelope positionally) and A13 (an `errors` handler body
never mangled, so it could not call a fn — `dkErrors` yielded nothing from
`ast_ops.childDecls`, issue #48) were all fixed on 2026-09-13 and are locked
in as `bug_fixed`.

The two entries that stood here before are fixed and locked in as regression
guards (`bug_fixed`): the Odin `Seq[Interface]` literal and the qualified
mutator in a `..` chain.

**Tracked but without a test yet — attempted to reproduce this session,
blocked by a separate issue:** on Odin a task WITH ARGUMENTS is claimed to
still emit a direct call, so its body would run on the main context and the
first `tuckAwaitRead` would panic. Compiling `examples/29-task-timeout.tuck`
(a task with a `{fd: int}` param, real `on select` read+timeout) against Odin
to isolate this hits a DIFFERENT, earlier compile error first — `on select`
with a real (non-synthetic) yield point is not lowered for Odin at all
("Expected 1 return values, got 0" / `Undeclared name: openSource`) — so the
narrower "args + real yield" claim above stays unverified in isolation; a
task with args but only SYNTHETIC `[io]` calls (`examples/28-async-task.tuck`,
which never truly parks) compiles and runs correctly and does not exercise
the claim either way.

## B. Broken examples (1)

**16-actor-tasks-unified-syntax** — two causes:
1. `.fn {args}` on an undeclared method (`copyFrom`) is now a checker error,
   which is correct behaviour; the EXAMPLE needs a `pending:` stub.
2. Dotted select sources parse as opaque strings: `| resp.ok -> {body}:` and
   `| timeout.5s -> {}:`. Needs typed SelectSource variants and `5s` duration
   lexing.

Everything else in `examples/` compiles. `37-ffi-handle` compiles only with the
examples dir as `--root` (its `lib: "cffi/point.c"` is relative to that), which
is why it is gated in `tests/suites/odin_backend.nim` rather than `tests/suites/examples.nim`.

## C. Async / concurrency gaps

Measured, not guessed — see `thoughts/async-endgame-measurements.md`.

- **DNS.** `net::connect` accepts dotted quads only; a hostname is rejected as
  `Unreachable`. `getaddrinfo` blocks, so it belongs on the offload worker.
- **A pool, if ever.** One worker serializes blocking calls. A pool of K caps
  at exactly K and then goes linear again — it buys a constant, not asynchrony.
  Only worth it behind a benchmark showing a real program does concurrent file
  I/O.
- **`readLine` is on the worker but need not be.** stdin has real readiness, so
  it could reach the reactor like a socket. The worker was the fix that removed
  the hang, not the right long-term shape.
- **Typed select sources.** `on select` lowers `read <fd>` / `timeout <ms>`
  only. Blocks example 16 (see B).
- **The D runtime has no networking.** `listen`, `accept`, `connect`,
  `sendAll` and `recvSome` exist in `compiler/tuck_rt.nim` and not in
  `compiler/tuckrt_d/tuck_rt.d`, so `examples/42-net-echo` emits valid D that
  cannot link ("undefined identifier `listen` in module `tuck_rt`"). Codegen
  is fine; the runtime is the gap, and it is why that example is deliberately
  absent from the D compile gate. A third hand-mirrored runtime is exactly
  the drift the item below is about.
- **One C implementation of the runtime.** The Nim and Odin runtimes are
  mirrored by hand and have drifted three times already (see
  `thoughts/bugs-found-while-building-net.md`). Collapsing the offload seam
  into one C file bound over the existing FFI removes the class.

## D. Design items with a ruling, not yet built

- **The event registry emits invalid Nim.** A registry whose event carries a
  payload emits a type whose fields are indented inconsistently —
  `kind*:` at four spaces, `code*:` at two — which nim rejects as "invalid
  indentation". Reproduces via `examples/20-embedded-mp3-player`.
- **`tuck build` on a file with no `fn main` never compiles what it emits.**
  That is the documented library-build behaviour (§2.3b), but it is also why
  both defects above went unseen: every example demonstrating `register`,
  `arena` or the event registry is main-less, so the gate checks EMISSION and
  stops. The emitted code is never handed to nim/odin/dmd. The one example
  using these features that does have a `main`,
  `examples/20-embedded-mp3-player`, fails to build on ALL THREE backends
  today while sitting on the gate list.
  This is the sharp form of §F's "gate lists are the real coverage": a
  feature can be listed, emitted, and entirely unexercised.

- **`arena` parses and does nothing** (spec §7.3, now marked "not
  implemented" there). There is no `dkArena` kind and no backend support:
  `parseArenaDecl` reads the body and discards it, returning a `type` of the
  arena's name with an empty record body. A file using an arena therefore
  CHECKS CLEAN while allocating nothing and resetting nothing, and its block
  is absent from the tree. `examples/13-arena-mem.tuck` is a syntax specimen
  (no `fn main`), so the corpus is not claiming otherwise — but nothing
  before this said so out loud. Found by `tuck validate`, which is what that
  tool is for.
  Its siblings are in three different states. §7.2 `pool` WORKS — verified
  behaviourally: `count: 2` hands out two, reports absence on the third, and
  recycles after a release, identically on all three backends. §8.1
  `register` now works on all three (fixed 2026-09-12: the Nim backend's
  `registerMMIO` macro was dropped for ordinary emitted code, matching Odin
  and D).
- **Three token kinds are dead.** `tkArena`, `tkPool` and `tkRegister` are
  declared in `TokenKind` and referenced nowhere else — the lexer emits none
  of them, so `arena`/`pool`/`register` (and `extern`, `errors`, `resource`)
  arrive as `tkIdent` and are recognised by spelling. `pool` and `register`
  parse correctly that way, so being contextual is not itself the defect;
  the dead kinds are just misleading. Either make them real keywords or
  delete them. (`tkSymbol` is dead too, and says so: "legacy fallback".)

- **Effect propagation is require-declared, not inferred.** The ruling is
  implicit propagation; the checker still makes you declare. `ROADMAP.md:26`.
- **`[may_block]` has no checker meaning.** It parses and propagates. Its real
  job is the `[irq_safe]` treatment — an `[irq_safe]` fn calling a
  `[may_block]` one should be a compile error, exactly as spec §3.7 already
  specifies for `[irq_safe]` calling `[io]`.
- **Postfix binds tighter than operators** (`x + y sys::exit`) with no
  precedence hint in the error.

## E. Fixed since the last snapshot — do not re-report

- **Field access on a primitive is rejected.** Resolved receivers now have a closed field surface; an undeclared field reports `TK-TY02` instead of manufacturing a missing type.

Fixed 2026-08-05, later in the same day (7 open bugs -> 3):

- **An assignment target must name something.** `nosuchfield += n` typechecked
  in a fn and in an actor handler alike — the target synthesized as Unknown,
  and Unknown is compatible with everything. Checked in the target position
  only, so Unknown stays load-bearing for gradual typing everywhere else. This
  one fix closed three open bugs, including a void handler assigning `result`
  (which is simply not bound when the handler declares no return type).
- **Sum types are nominal.** Two differently-named sums were compatible.
  `compatible` resolved a name mismatch through to the body, which destroyed
  the names, and the fallthrough `a.kind == e.kind` then saw tkSum == tkSum.
  Now rejected before resolving.
- **An attribute name may be a type argument.** `Box[error]`, `Box[sealed]`,
  `Box[stack]` all parse. Fixed at the SOURCE rather than in the parser: bare
  markers (sealed, io, unsafe, packed, saturating, …) are now reserved words
  with their own token kind, so they can never be an ordinary identifier, and
  the 19-name list in `parser_type.nim` is gone. Attribute PARAMETER names
  (count, size, queue, header, lib, c, …) stay ordinary identifiers — they
  always appear as `name: value`, which is identifiable by shape, and they are
  good field names (`{c: Counter}`, `count: int`).
- **User-declared type names must be Capitalized** — type, object, interface,
  actor, distinct, fnsig, registry, pool, arena. The corpus already followed
  this everywhere; one mixin in example 04 was the sole violation.
- **`std/io` is now `std/console`**, because `io` is the `[io]` effect marker
  and a reserved word cannot also be a module name.

Verified fixed earlier on 2026-08-05:

- `/i=` on ints emits `div`, not float `/`.
- `toStr` + string concat picks concat.
- `if` has an expression form (`let x = if c: 1 else: 2`).
- `match | A -> 0` parses; the old bare `[Parse Error]` is gone.
- `fnsig` named function signatures — shipped, example 31, run-gated.
- `20-embedded-mp3-player` compiles (was listed BROKEN for two reasons).
- Actors run; `on select` actors work on both backends.
- Interfaces are a copying tagged variant; escape analysis was deleted with it.
- `[saturating]` implies `distinct` on BOTH backends.
- A `-> void` task can be fire-and-forget.
- `scheduler::stop` exists, so a parked coroutine cannot hang a program.
- std/net: real TCP through the reactor, flat to 32 connections on one thread.
- std fs/io no longer block the scheduler — they run on the offload worker.

## F. Watch-outs the test suite does not cover

- **An intermittent `Bad file descriptor` reading a child's output.** Seen
  twice in full runs (once aborting cli_smoke with a stack trace, once as
  recursive_types 72/73) and never reproducible on demand — three consecutive
  full runs clean, and the fd limit is 1M so exhaustion is not it. The runner
  is single-threaded, so it is not a concurrent-spawn race either. UNDIAGNOSED.
  Both read sites (harness.sh and the runner's reap) now catch it and fail
  that ITEM with the command and the errno, rather than letting one transient
  abort the whole run with no command named — which is why the first two
  occurrences left nothing to work from. The next one will identify itself.
- **Odin compiles a DIRECTORY as one package.** `tuck b FILE --odin` in a
  directory that already holds other emitted `.odin` files fails with
  "Redeclaration of 'main'" (or of any shared symbol) naming a file you did
  not build — `examples/` holds 44 of them. Not a compiler defect: the Odin
  suite stages each example into its own package dir for exactly this reason,
  and a scratch directory with two emitted files behaves the same way.
  Mistaken for a compiler bug twice in one session, hence this entry.

- **`Mailbox.lock`** was free under `--threads:off`; programs now build with
  `--threads:on`, so it is real uncontended cost on every message. Sends still
  only happen on the scheduler thread, so it currently protects nothing.
- **`--threads:on` widens `system`'s namespace.** `system.running(Thread)` beat
  `tuck_coro.running()` in overload resolution once already. `inCoroutine()`
  exists so callers avoid the ambiguous form.
- **Gate lists are the real coverage.** `tests/suites/examples.nim` gates 41 examples and
  `tests/suites/odin_backend.nim` gates compile+run separately. Anything off a list is
  unchecked — that is how an Odin actor emitting undefined send procs, and a
  `24-stdlib` whose fs round-trip never ran, both survived.
