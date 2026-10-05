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

## A. Open bugs (9)

A bug here has a regression test written as the CORRECT behaviour, marked
`bug_open`. Fixing one means flipping the marker to `bug_fixed`, which locks
it in.

**A39 — a recursive sum type's boxes are never freed on Odin.** Each edge of
`type Expr: | Add({left: Expr, right: Expr}) ...` is a one-element Seq
(lowering_recursive), and the ownership pass follows the Seq slots of
records; a sum value is neither, so no box is ever deleted. Every tree built
leaks all its boxes: 200 000 small trees peak at 111 MB on Odin, 10 MB on
Nim and D. Freeing a value's own boxes alone would be wrong two ways — a
child is a SHALLOW copy shared by every parent that took it (`sum` sits in
both `whole` and `neg` in example 44), and a tree returned from a fn is
reachable only through its root. The fix is deep ownership, which Nim and D
already have: a copy of a value used again is a deep copy, a last use a
move, and a drop proc frees a tree recursively. Found 2026-10-05 by
`TUCK_TRACK` on example 44. Test: `known_bugs`, "A39: …".

**A27–A37 — constructs that do not cross a module boundary (R11 scan,
2026-09-28).** A25, A26, A28, A30, A31, A33, A35 and A36 are fixed; their pins are
`bugFixed` in `cross_module`. Ruled: importing anything should work as well as the same
module. Each construct was built declared in `lib` and used from the
importer on Nim, Odin and D, against a one-module control that passes; these
failed. Tests: `cross_module`, each named "R11: …".
- **A27** an object in the importer cannot `satisfies` an imported interface.
- **A29** `+ Mixin` from another module: `Self` is not bound (R11's origin).
- **A32** an imported actor's fields and handlers are invisible to the
  importer ("no field 'total' on type Acc", #73). Distinct from A18, which is
  an imported actor never STARTED on Odin/D.
- **A34** (Odin, D) a group bound whose provider is in another module — the
  bounded fn's module cannot name it. A14's sibling.
- **A37** (Odin, D) an imported registry's `raise` is unqualified.

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

**A16 — a fired `timeout` does not bound latency.** The right arm wins and the
right value comes back, but not until the LOSING source has completed: a 5ms
deadline against a 500ms source returns after 0.50s, and against a 3s source
after 3.00s, identically on all three backends. The delay scales with the
source, which is what says it is the await rather than a fixed cost — binding
a task's result drives the scheduler until ALL work finishes rather than until
THIS task does. `examples/29-task-timeout` says the timeout "fires WHILE the
read is outstanding", which is true of the result and not of the clock, and
that is the whole point of a timeout. Test: `task_select`, "a fired timeout
returns without waiting for the loser".

**A18 — on Odin and D, an actor declared in an IMPORTED module is never
started.** Both entry builders collect actors from the entry module only
(`runtimeUsers` for Odin, `dBootSequence` for D), so a program whose actors all
live in libraries boots no scheduler and starts no drain. Odin hangs, D returns
the wrong answer. The Nim half of this was worse and is fixed: it SEGFAULTED,
because the first `send` reached `tuckNotifySend` against an uninitialised
runtime, and tuck.nim now collects across the whole program. Odin and D need
more than a wider scan — an imported actor's drain lives in another package, so
the emitted call must be QUALIFIED. Test: `cross_module`, "an imported actor
runs on every backend". Found 2026-09-17 writing the first import/cache tests;
same scope error as #73.

A1 (an attribute name — `priority`, `error`, `stack` — reserved everywhere,
though TK-PA08's own text promised "only inside brackets") was RULED on
2026-09-27 rather than fixed: the compiler was right. A name that is read
bare can land in brackets, where an attribute word reads as an attribute
(`xs[stack]` dropped its index when the words were let through). Attribute
words are reserved words, fields included since 2026-09-28 (a field was the
one exception for a day). TK-PA08's text now says so. Test: `known_bugs`,
"an attribute word is refused as a fn name", "...and as a parameter name"
and "...as a field name too".

A2 (a fn with no declared return type accepted `return x`, and `tuck c`
wrote `proc tuck_f*(x: int): void = return x`, which nim refuses) was fixed
2026-09-27 without the ruling it was waiting on: returning a value from such a
body is wrong whether omitting `->` comes to mean `void` or becomes an error,
so it is TK-TY32 now. What omitting `->` means was RULED the same day
(issue #5): exactly `-> void`; a call to such a fn now answers `void` rather
than `unit`. Test: `known_bugs`, "a value returned from a fn with no return type is
rejected" (now `bugFixed`).

A3 (a `[read]` register field could be written — with `=`, while the `..`
form was already refused) was fixed 2026-09-27. The assignment target went
through the ordinary field-access path, which checks a READ, so the rule was
backwards for `=` in both directions: `CTRL.RDY = true` on a `[read]` field
checked clean, and `CTRL.GO = true` on a `[write]` field was refused as reading
it (TK-RE02). An assignment target is now held to the write rule (TK-RE01).
Test: `known_bugs`, "writing a [read] register field is rejected" (now
`bugFixed`) and "a [write] register field is assignable with `=`, on all
three". Issue #6.

A19 (on Odin, a loop that copies accumulated every copy — 482 MB for 20 000
copies of a 1024-element `Seq`, issue #77) was fixed 2026-09-25, in two
halves. The frees came first (`analysis_ownership`, 2026-09-22), which left
one redundant copy per iteration: `tuckSeqCopy(bump(xs))` copied a buffer
`bump`'s WRAPPER had already copied, and leaked the first. Provenance now
knows a call reaches either the wrapper (which copies the moved parameter)
or the twin (which hands back an argument the caller gave away), and asks
about the argument inside its enclosing body; the copy pass records which
bindings it left uncopied as exclusive, and the ownership pass reads that
record instead of re-deriving it. 482 MB -> 1.8 MB, `TUCK_TRACK` and
valgrind clean. Test: `known_bugs`, "a copy-per-iteration loop does not
accumulate copies" (now `bugFixed`), and `value_semantics`, "a result the
wrapper copied does not alias the argument", on every backend.

A20 (on Odin every heap `str` leaked — the whole category, because
`copyableContainer` excluded `str` on an aliasing argument that was taken as
settling ownership) was fixed 2026-09-22: `RtOwnedStr` names the runtime
procs that allocate one, and a `str` local assigned exactly once that does
not escape gets a `defer delete`. 1M `toStr` calls went from 33.4 MB to
2.1 MB on Odin, below D's 3.9 MB. Issue #86.

A17 (a handler-less actor emitting a registration call to a proc that was
never generated — the three entry-point builders asked "is this a dkActor"
while genActor asked "does it have anything to receive"; D already had the
right query and said in its own comment that both sites must ask it, so
`actorHasMessages` moved to `codegen_common` and all three now do, issue #61),
A15 (a one-armed `on select` losing its arm's return value — the emitter
required BOTH a read and a timeout arm and fell to a `discard` marker
otherwise, so both single-arm forms threw the arm's body away; each runtime
already had `tuckAwaitRead` and `tuckSleep`, issue #56),
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

- **Odin leaked one runtime allocation per task call and per `waitUntil`,
  and `TUCK_TRACK` flagged every actor program.** Once tracking covered every
  program that imports the runtime (`dd3211e`), a sweep of every runnable
  example and bench app found leaks in most of them, and its report now names
  each site. Two were real and grew with use: a task's result slot
  (`newAsyncResult`), which `awaitResult` now frees, and a `waitUntil`
  waiter, which the actor now frees once it has woken it. The rest lived as
  long as the program by design: the scheduler's queue, the event loop's
  table, an actor's slot and thread (the runtime's, from
  `tuckRuntimeAllocator`, untracked), and an actor's heap fields (handed back
  at exit under tracking, like the slabs). The sweep now reports only example
  44, which is A39. Fixed 2026-10-05. `odin_backend` now builds every
  run-gated example a second time with tracking and requires the same answer,
  so a new leak or bad free fails the suite instead of waiting for a sweep.

- **A threading fn's result was copied again at its binding, and the
  original dropped (Odin).** A fn that threads its first parameter, called
  with an argument still read later, reaches its WRAPPER, which copies that
  argument; the result is that private copy. Two things made provenance call
  it aliased: the self-append `out = {items: out, value: v} push` joined the
  call's own result into `out`, losing `out`'s link to the parameter; and
  joining "fresh" with "parameter `ns`" forgot `ns`. So the caller's binding
  copied the copy and dropped it — one buffer per call (483 MB against 10
  MB, `known_bugs`). A self-append now leaves the name's provenance alone
  (`ast_query.selfAppendValue`, moved down from codegen so both can ask),
  fresh joined with a parameter slot keeps the slot, and once the moved
  argument stamps are final, a call whose argument is not moved is known to
  reach the wrapper. Found 2026-10-05 by `TUCK_TRACK`, the first time it
  tracked such a program (`dd3211e`). A sweep of every runnable example and
  bench app under tracking reads the same before and after.

- **No parameter read through a field was `sink` on Nim**, so every
  record-threading container copied itself on each call: benches/containers
  `rec_thread`, `two_fields`, `generic_box` and `str_builder` were quadratic.
  The SSA mirror stamps a final read on the path (`b.items`). The pass it
  replaced also stamped the root `b`, and `sink` (`codegen_common.keptAt`)
  read only that. It reads the path's stamp now. A path that reads a
  scalar (`b.items.len`) keeps nothing, so a reader still borrows. Fixed
  2026-10-04. `ssa`, "the threader keeps its sink, read through a field";
  `containers_bench` holds the whole bench to its ledger.

- **Odin freed the `Seq` a generic record was returned with.** `return
  {items: xs} Box` in a `-> Box[T]` fn emitted `defer delete(xs)`, a segfault
  (benches/containers `generic_box`). `seqFieldNames` answered nothing for a
  generic application, so the escape analysis saw no buffer leave. Fixed
  2026-10-04 (`1e79b46`). `known_bugs`, "a generic record returned with a
  moved Seq keeps it".

- **A slab of a generic record could not `new`, and a generic record's
  `T?` field took no plain value.** `slab Ints = Link[int, IntsRef]` read
  the element as having no fields, so `Ints.new {value: 1, next: none}` was
  refused, and `set`'s record literal could not find its type arguments;
  they come from the slab's declared element now. Beside it, on every
  backend and with no slab: a generic construction never noted a plain `T`
  given to a `T?` field (`{v: 1, n: two} Box`), so it was emitted bare and
  built nowhere; the wrap is judged once every type argument is known. And
  `none` as the only thing naming R bound R to itself, typing the
  construction `Link[int, R]`; it is "cannot infer generic parameter 'R'"
  now. Found 2026-10-04 probing generic code over slabs; fixed the same day.
  `slabs`, "a slab of a generic record…"; `known_bugs`, two guards.

- **A plain `T` given to a binding stated as `T?` built on no backend.**
  `let x: int? = five` and `var h: NodesRef? = a` were emitted bare, and
  each host refused a plain value where its result carrier was expected.
  R8's `lowering_optional` wrapped a store into a `?T` field, but took the
  place's type from the target, which a new binding's name does not carry;
  it reads the stated type first now. Found 2026-10-04 probing generic code
  over slabs; fixed the same day. `known_bugs`, "a plain T into a stated
  `T?` binding is wrapped".

- **#98 — `for x.ok:` did not narrow x in the loop body**, so a chain of `?`
  links could only be walked by recursion. It narrows now
  (`typecheck.synthWhile`). Closing it first closed a soundness hole beside
  it: a narrowed name given a `?T` again was still read as present (`if
  x.ok: x = none; x.value` checked clean); such an assignment ends the
  narrowing now (`synthReassign`). Fixed 2026-10-04. `known_bugs`.

- **#97 — a record literal where a named record is wanted built on no
  backend** — the form TK-PA13's message calls fine. `{b: {tag: 9}} take`
  crashed the compiler: the exploded `take({tag: 9})` looked unexploded and
  was exploded again (`exkCall.argsExploded` now says it was). With more
  fields, and inside a construction (`{point: {x: 1, y: 2}} Thing`), every
  backend emitted an anonymous record its host would not pass as the named
  type; lowering constructs the named type now (`constructRecordArgs`,
  `constructRecordFields`, to any depth). Fixed 2026-10-04. `known_bugs`.

- **A38 — (Odin) a local's Seq field handed to a moved twin was freed
  twice.** `let r = {ns: l.nodes, d: ..} grow` inside `grow_moved` hands
  `l.nodes` to the twin, which keeps the buffer and returns it in `r.nodes`;
  the caller still freed `l.nodes`. The escape question treated a moved bare
  name as gone but not a moved field; `ownership_escape.escapes` does both
  now, slot by slot. Fixed 2026-10-04. `known_bugs`, "a Seq field handed to
  a moved twin…".

- **#96 — (Odin) a Seq that moved was still freed.** Two shapes, one cause
  each. A local moved into a record at its last read (`let nb = {items: x2}
  Bag`) was freed as x2 and as nb.items — the ownership pass read the copy
  decision's "left uncopied, the local is dead" as "nothing taken"
  (`analysis_ownership.takesNothingOf`). And a fn ending in the Seq it
  returns deleted it after the return value was taken, because the tail
  became a `return` only at emit time, after ownership had decided; lowering
  makes it now (`lowering.lowerTailReturns`). Fixed 2026-10-04.
  `known_bugs`, "a Seq moved into a record…" and "…tail value…".

- **`arena` parsed and did nothing.** It parsed into a `type` of the arena's
  name with an empty record and discarded its body; since 2026-09-27 a TK-ME02
  warning said so. Built 2026-10-04 over slabs (slab proposal §9, phase 4):
  `arena X [size: N]` is a declaration and a lifetime (the block form is
  TK-PA18, TK-ME02 is retired), `X.new {value: v}` hands out a `XRef[T]`, and
  `X.reset` ends everything at once. `examples/13-arena-mem.tuck` is a program
  now, run-gated at 55 on all three; `tests/suites/slabs.nim`.

- **A36 — an imported pool, on Odin and D.** A pool is not injected into an
  importer, and Odin and D named it bare — `&tuckˑpoolˑCells`, which only
  `lib` declares — so the importer did not even import `lib`. Each pool
  operation now qualifies a pool another module declares
  (`ast_query.declOrigin`), and D maps an imported pool's handle type to
  `rt.PoolHandle` as it does its own (`resolution.isImportedPoolHandle`).
  Fixed 2026-09-28. `cross_module`, "R11: …".

- **A30 — `match r.err` on an imported fallible fn.** A binding remembered
  its producer's `[error: E]` enums only when the producer was declared in
  the same module, so an imported fn's arms were never qualified and printed
  as defaults ("multiple default clauses" on Nim, `else` on Odin and D). The
  error enums now ride in the signature (`FnSig.errTypes`, and
  `SigInfo.errTypes` for one served from the index), and `rememberErrTypes`
  falls back to it. Fixed 2026-09-28. `cross_module`, "R11: …".

- **A33, A35 — an imported const and an imported saturating type.** A
  const is not injected (an importer's own const may shadow it), so Nim now
  exports it (`const Cap* = …`) and Odin and D qualify each reference to it,
  as a value and as an Array size (`ast_query.constOrigin`). An imported
  saturating type's constructor is qualified on Odin and D. Fixed
  2026-09-28. `cross_module`, "R11: …".

- **A26, A28, A31 — imported interfaces and invariant types.** A call
  through an imported interface value resolved to one satisfier's member,
  a type test on one was refused, and an imported invariant type crashed
  the compiler ("id … is held by two nodes"). Interfaces are now injected
  like types and objects; every injected copy is a deep copy under fresh
  ids (`ast_ops.freshIds` — a copy that SHARED its original's nodes became
  two objects under one id once each backend took its own copy); a copied
  object skips conformance, which its own module checked; and Odin and D
  qualify an imported interface's variant, tag enum and `__validated_*`
  proc (`importPrefix`, `validatorName`). Fixed 2026-09-28. `cross_module`.

- **A25 — an imported `object` could not be constructed**, so none of its
  members could be called: `injectImportedTypes` copied only `type`s into an
  importer. An object's copy is now its shape (fields, `satisfies`, members
  as body-less signatures); Odin and D qualify its type and member procs,
  and a changing member keeps its by-reference `self` on the importer's
  side. Fixed 2026-09-28. `cross_module`, "R11: …".

- **A24 — an actor member `fn` was emitted by no backend.** `fn` and `on`
  both parsed to a dkFn, and every backend made each one a MESSAGE (a
  `handleMsg` arm, a `sendAddIt_…` helper), while a direct call printed a
  bare `addIt(n)` that named nothing. `on` now marks a handler; a `fn` is
  a member emitted as a proc taking the actor's state as `self`, and a call
  passes `self` on. Also refused, where all of it used to check clean and
  build on no backend: an `on` handler called like a fn (TK-AC03), a
  member called from outside its actor (TK-AC04), a `send` naming a member
  (TK-AC05). Found and fixed 2026-09-28. `known_bugs`.

- **`benches/transpile/dispatch.tuck` crashed every `tuck c`** in
  assertSsaWellFormed ("the mirror misses 1 final use"). A variant
  construction bound inside an `if` (`let c = Shape.Circle {r: i}`) was
  enough. The liveness oracle the graph is checked against skipped a
  `.name {args}`'s argument, missed the read of `i`, and proved the earlier
  `if i == 0` read final; the graph was right. Unseen since 2026-09-22
  because the ssa suite's corpus left out `benches/transpile`. `ssa`,
  "a variant construction's argument is a read, on every backend".

- **A `T?` actor field read as present before anything wrote it, and a
  plain `T` could not be stored into one.** The result carrier's zero status
  is Ok, so `last: int?` started present holding 0, on all three backends;
  `last = v` stored a bare `int` where the carrier was expected and failed
  to build on all three. Found 2026-09-28 making R8's `T?` escape usable;
  `lowering_optional` emits an absent start and a wrapped store.
  `known_bugs`, "a `T?` actor field starts absent…".

- **A23 — one object as a changing member's `self` and as its argument
  keeps value semantics.** `k.absorb {other: k}` (or `k ..absorb {other:
  k}`): `self` is passed by reference, and Nim and Odin passed the large
  by-value `other` as a hidden pointer to the same `k`, so it read the
  change (101 instead of 1). Such an argument is now copied into a `let`
  before the statement (`lowering_alias`, 2026-09-28); a statement that
  also changes that variable earlier is refused rather than guessed at.
  `known_bugs`, `value_semantics`.

- **Three member-call gaps, found 2026-09-28 working through "a member that
  changes its object on a parameter".** (1) A member with no `->` called as
  `d.turn {step: 2}`, or through an interface value as `t.bump`, was
  "not declared" or resolved to the wrong object's member: the call's type
  was nil where R5 says `void`. (2) `var t: Tally = Counter{...}` was
  refused ("expects Tally but got Counter"). (3) A changing member called
  through a `var` interface value changed a copy and the change was lost;
  the dispatch now stores it back. `tests/suites/value_semantics.nim`,
  `tests/suites/typecheck.nim`.

- **An object member called on a fn parameter builds on Nim and Odin.**
  Every backend passes a member's `self` mutably (Nim `var T`, Odin `^T`,
  D `ref T`); a Nim parameter is immutable and an Odin one unaddressable, so
  `fn rate({a: Flac}) = a.sampleRate` built only on D (fixed 2026-09-27).
  Since 2026-09-28 a member that only reads takes `self` by value, and one
  that changes its object may not be called on a parameter. `known_bugs` "a
  member called on a fn parameter builds, on all three".

- **A22 — on Odin, an interface call whose payload holds a variable
  builds.** Odin's dispatch is an immediately-called proc literal, which
  cannot capture; every argument past the receiver is now a parameter of
  that literal, evaluated at the call (2026-09-27). `known_bugs` "an
  interface call whose payload holds a variable builds on Odin";
  `interfaces` "an MP3 crossfades into a FLAC through the interface".

- **A21 — a `-> Self` contract member called through an interface builds.**
  Ruled R13 = B, 2026-09-27: in an interface, `Self` is the interface; in
  the receiver `self` it is the object running. Conformance reads a
  non-receiver `Self` as the interface (`next: AudioSource`), and accepts a
  `-> Self` implemented as the object's own type, which each dispatch arm
  wraps back into the interface (Odin and D can now wrap a call, not only a
  variable). A call through an interface value now checks its payload
  against the contract; a wrong type or a missing field had checked clean.
  `known_bugs` "a `-> Self` contract member called through an interface
  builds, on all three"; `interfaces`.

- **A8 / #42 and A12 / #45 — a pool cell can be read, written and filled, and
  never read as zeroed memory.** Ruled 2026-09-26: `Cells.read {h}` /
  `Cells.write {h, value}` through the handle, and `Cells.addr {h}` for an
  extern only (TK-TY08 anywhere else). A cell starts ABSENT, so `read` is a
  `?T`; a written value is a construction, validated where it is built; and
  `addr` is refused for an invariant-carrying element (TK-TY31). Pool ops are
  their own node (`exkPoolOp`), and a pool is no longer capped at 64 cells.
  `tests/suites/pools.nim`, on all three backends; the two pins flipped.

- **A6 / #40 — on Odin, an interface method may return more than `int`.**
  The dispatch closure was typed `-> int` whatever the method returned. Calls
  through an interface are now LOWERED (`lowering_iface`, ROADMAP M4.4) to an
  `exkIfaceCall` carrying the call's own type, which the Odin closure prints
  (2026-09-25). `known_bugs` "an interface method may return an enum";
  `interface_dispatch` for `str` and `void` members on all three.

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
