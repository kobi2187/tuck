# Missing Features & Gaps — snapshot 2026-08-05

Every claim below was re-verified against the compiler on the date in the
heading. The previous snapshot (2026-07-24) had drifted badly: it listed four
bugs as open that were fixed, called two examples broken that compile, and
described `fnsig` as an unbuilt proposal when it ships in example 31. If you
are reading this more than a few weeks out, re-run the checks rather than
trusting the text — the suite is the source of truth, this file is a summary.

**How to get the real list:** `./run-all-tests.sh` prints every `OPEN` line.
That is authoritative; this file explains them.

---

## A. Open bugs (2, all with a failing test that pins them)

Each has a regression test written as the CORRECT behaviour, marked `bug_open`.
Fixing one means flipping the marker to `bug_fixed`, which locks it in.

| # | Bug | Test | Where the fix belongs |
|---|---|---|---|
| 1 | A member fn shadows a top-level fn of the same name. `collectSigs` registers object members under their bare name into the same flat `fnSigs` as top-level fns, so `Dog.noise` overwrites the free `noise`. Attempted and reverted: a member must STAY in that table, because `d.noise` resolves through `asFnByName`, which looks the bare name up there — so letting the free fn win simply breaks the member call instead. Needs call resolution to distinguish them. | member_names | `typecheck.nim` `collectSigs` + call resolution |
| 2 | Odin: a list literal cannot reach a `Seq` parameter. `[dynamic]T` has no literal form, only `append`, and Odin rejects the inline braced compound literal at the call site. A plain `Seq[Record]` fails identically, so it is not interface-specific. Needs statement hoisting in the Odin emitter (declare, append, then pass). | interface_seq | `codegen_odin.nim` |

**Tracked but without a test yet:** on Odin a task WITH ARGUMENTS still emits a
direct call, so its body runs on the main context and the first
`tuckAwaitRead` panics. Nullary tasks are fixed. Odin proc literals cannot
capture (verified with a two-line program), so the arguments need a heap
context the thunk owns and frees.

## B. Broken examples (1)

**16-actor-tasks-unified-syntax** — two causes:
1. `.fn {args}` on an undeclared method (`copyFrom`) is now a checker error,
   which is correct behaviour; the EXAMPLE needs a `pending:` stub.
2. Dotted select sources parse as opaque strings: `| resp.ok -> {body}:` and
   `| timeout.5s -> {}:`. Needs typed SelectSource variants and `5s` duration
   lexing.

Everything else in `examples/` compiles. `37-ffi-handle` compiles only with the
examples dir as `--root` (its `lib: "cffi/point.c"` is relative to that), which
is why it is gated in `odin_backend.sh` rather than `examples.sh`.

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
- **One C implementation of the runtime.** The Nim and Odin runtimes are
  mirrored by hand and have drifted three times already (see
  `thoughts/bugs-found-while-building-net.md`). Collapsing the offload seam
  into one C file bound over the existing FFI removes the class.

## D. Design items with a ruling, not yet built

- **Effect propagation is require-declared, not inferred.** The ruling is
  implicit propagation; the checker still makes you declare. `ROADMAP.md:26`.
- **`[may_block]` has no checker meaning.** It parses and propagates. Its real
  job is the `[irq_safe]` treatment — an `[irq_safe]` fn calling a
  `[may_block]` one should be a compile error, exactly as spec §3.7 already
  specifies for `[irq_safe]` calling `[io]`.
- **Marker plumbing is duplicated.** Two name→marker maps (`parser.nim:117`,
  `parser_type.nim:184`) and two marker→name maps (`typecheck.nim:2040`,
  `semantics.nim:152`), none sharing code. Adding a marker means four edits.
- **Postfix binds tighter than operators** (`x + y sys::exit`) with no
  precedence hint in the error.

## E. Fixed since the last snapshot — do not re-report

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

- **`Mailbox.lock`** was free under `--threads:off`; programs now build with
  `--threads:on`, so it is real uncontended cost on every message. Sends still
  only happen on the scheduler thread, so it currently protects nothing.
- **`--threads:on` widens `system`'s namespace.** `system.running(Thread)` beat
  `tuck_coro.running()` in overload resolution once already. `inCoroutine()`
  exists so callers avoid the ambiguous form.
- **Gate lists are the real coverage.** `examples.sh` gates 41 examples and
  `odin_backend.sh` gates compile+run separately. Anything off a list is
  unchecked — that is how an Odin actor emitting undefined send procs, and a
  `24-stdlib` whose fs round-trip never ran, both survived.
