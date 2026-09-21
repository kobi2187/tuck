# Event registry: bugs found 2026-08-14

Found while reducing cyclomatic complexity in the checker. Both are real,
both reproduce on a clean build, neither is fixed — the pass they turned up in
was meant to be behaviour-preserving, so they are recorded here instead.

The registry system (spec Part 10) is preliminary. These are the failure modes
its current shape produces, not a criticism of the design.

---

## EV-1 — a raise inside a TASK body emits garbage

**Severity: high.** Produces Nim that does not compile, with an error message
naming generated code the user never wrote.

### Reproduce

```tuck
registry AppEvents:
  | Boom({n: int})

on AppEvents.Boom({n: int}):
  let x = n

task work() -> void:
  AppEvents.raise Boom {n: 1}
  return

fn main() -> int:
  {} work
  return 0
```

`tuck ch` says `OK`. `tuck build` fails:

```
taskraise.nim(7, 3) Error: invalid indentation
tuck: nim compilation failed
```

### What is actually emitted

The same raise, in a `fn` versus in a `task`:

```nim
# fn work()   — correct
proc tuck_work*(): void =
  raise_tuck_AppEvents_Boom(1)

# task work() — garbage
proc tuck_work*(): void =
  Boom(tuck_AppEvents.raise)(1)
```

The task version is the **pre-lowering parse shape printed verbatim**:
`AppEvents.raise Boom {n: 1}` parses as a call whose callee is a call whose
single argument is a `.raise` field access. `lowering.nim`'s
`flattenRegistryRaise` exists to collapse exactly that into
`raise_Registry_Event`. It never ran.

### Why

`lowerModule` (compiler/lowering.nim:150) walks fn bodies and nothing else:

```nim
for fn in m.allFns():
  lowerExpr(fn.fnBody, m)
for d in m.decls(dkExpr):
  lowerExpr(d.expr, m)
```

`allFns` (compiler/ast_query.nim:152) yields `dkFn` only. A task keeps its body
in `taskBody`, a different field on the same variant object, so `lowerExpr`
never reaches it.

**This is already known and worked around one file over.**
compiler/rewrite.nim:153-156 says:

> Tasks are walked SEPARATELY: allFns yields dkFn only, and a task keeps its
> body in taskBody. Seven examples declare tasks, so a rule that skipped them
> would be silently half-applied. (lowerModule has this same gap — it walks
> allFns and never reaches taskBody.)

The parenthesis is the bug, written down and left.

### Why nobody noticed

Lowering has two transforms, and the other one is done twice. Payload
explosion (`{a: 1, b: 2} f` -> `f(1, 2)`) is performed by `lowerExpr`, but
codegen ALSO performs it independently from the checker's recorded mapping
(compiler/codegen.nim:311-318). So inside a task body the payload transform
still happens — verified, including scrambled field order `{b: 9, a: 8}`
correctly emitting `(8, 9)` — and only the registry-raise transform, which has
no second implementation, is missing.

That is why this reads as "tasks are fine" until you put a raise in one.

### Fix

Widen the walk in `lowerModule`, matching what rewrite.nim already does:

```nim
for d in m.decls(dkTask): lowerExpr(d.taskBody, m)
```

The deeper fix is `allFns` itself, whose own comment warns that per-site kind
lists are how `dkActor` came to be silently skipped — this is the same shape,
one level up. Anything that walks "every body in the module" through `allFns`
has this hole; `mangle.nim:285` and both codegens handle `taskBody` explicitly
and are unaffected.

---

## EV-2 — a raise inside a task body is never CHECKED

**Severity: medium.** A typo'd event name in a task passes `tuck ch` clean.

### Reproduce

```tuck
registry AppEvents:
  | Boom({n: int})

on AppEvents.Boom({n: int}):
  let x = n

task watch({fd: int}) -> void:
  on select:
    | read fd -> {}: AppEvents.raise Typo {n: 1}
    | timeout 5 -> {}: return

fn main() -> int:
  return 0
```

`Typo` is not a declared event. `tuck ch` reports `OK (2.2 ms)`.

The same raise at statement level in a `fn` is correctly rejected:

```
Semantic Error [TK-RG01]: registry 'AppEvents' declares no event 'Typo'
  — `raise` may only name variants the registry declares
```

### Why

Same root cause as EV-1, on the checking side. `checkRaiseSites`
(compiler/typecheck.nim, the registry pass) iterates `m.allFns()` and calls
`raisedEventsIn` on each `fnBody`. A task's body is never handed to it, so
none of the four registry rules — event exists, payload matches, no
self-raise, every event handled — is applied to raises in tasks.

`raisedEventsIn` itself was separately widened today (commit `e42e7e1`): it
used to list ten node kinds and `else: discard`, missing raises nested in
kinds it did not name. That is fixed. It does not help here, because the task
body never reaches the walker at all.

### Fix

Same as EV-1 — the caller must feed task bodies in. Both fixes are the same
one-line widening in two places, or one fix to `allFns`.

### Note on scope

The four registry rules are enforced only over the bodies `allFns` yields.
Worth auditing whether actor handler bodies (`dkActor` members) reach it —
`members()` (ast_query.nim:102) does yield actor members, so those are
probably covered, but it was not tested.

---

---

## EV-4 — an `[io]` call inside a `send` payload escaped the effect audit

**FIXED 2026-08-14.** Recorded because it is the same shape as EV-1/EV-2 and
because it reached codegen, not just diagnostics.

### Reproduce (against a compiler older than this commit)

```tuck-rejected
actor Sink:
  hits: int
  on ping({n: int}):
    self.hits = n

fn noisy() -> int [io]:
  return 5

fn quiet() -> void:            # declares NO effects
  Sink send ping {n: {} noisy}
  return
```

Old compiler: `OK (2.5 ms)`. Correct answer, and what it now says:

```
Semantic Error: Expression requires effect [io], which is not allowed in
context of 'quiet'
```

### Why

`synthesizeExpr` (compiler/semantics.nim) gathered effects with a case over
fourteen Expr kinds and `else: discard`. `exkSend`, `exkSelect`, `exkField`,
`exkBracket` and `exkBracketAssign` were not among them, so nothing inside a
send payload or a select arm contributed its effects.

Two consequences, and the second is worse than a missed diagnostic:

1. the enclosing fn's declared effects were not checked against the call;
2. `semLayer.markAsync(e)` never fired for it — and that mark is what tells
   codegen to emit the async transform. An unseen `[io]` is an unmarked
   suspend point.

`exkSend` and `exkSelect` are precisely the actor and task constructs, which
is where effects concentrate.

### Fix

The walk is `ast.children`, exhaustive by construction. Regression test in
tests/suites/end_to_end.nim beside the existing "a pure fn cannot call an
[io] fn" case.

Verified by running the pre-refactor binary against the same program: `OK`
before, rejected after.

---

## EV-3 — the duplicate-mechanism pattern behind EV-1

Not a separate bug; the shape that produced one. Recorded because it recurs.

Three roles in this compiler have TWO implementations, one feature-full and
one simplistic. In each case the simplistic copy is the one with the hole, and
the feature-full one hides it:

| Role | Feature-full | Simplistic |
|---|---|---|
| payload explosion | `codegen.nim:311-318`, from the checker's recorded mapping | `lowerExpr`'s `explodePayload` |
| decision-table combinatorics | `codegen_table.nim:37` `columnDomains` | `typecheck_decisions.nim:57`, same loop, var out-params |
| AST traversal | `ast.children`, exhaustive and compiler-checked | ~8 hand-rolled walks with `else: discard` |

EV-1 is what this costs. Payload explosion inside a task body works — because
codegen does it independently — so `lowerModule` never walking `taskBody`
looked harmless for years. The moment a transform with no second
implementation (registry-raise flattening) took that path, it emitted garbage.

The decision-table pair carries its own irony: `codegen_table.nim:21` says the
constant is "shared so the two cannot disagree", and there are two constants.

The traversal pair is being closed as encountered — `clearIds`, `lowerExpr`,
`raisedEventsIn`, `scanReturns` and `mentionsName` now use `ast.children`.
Each had a different silent gap before.

---

## EV-5 — the Odin and D runtimes never got thread-per-actor

**Severity: high, Odin worst.** Found 2026-09-20 while measuring the Nim
mailbox. Thread-per-actor (`cdeec03`) changed all three backends' SCHEDULERS
— `tuckStartActor` in `tuckrt/tuck_coro.odin:661` and `tuckrt_d/tuck_coro.d:723`
both spawn a real OS thread per actor — but only the Nim runtime's MAILBOX
and send path were updated to match. Three separate defects follow.

### 1. The Odin and D mailboxes have no synchronization at all

`tuckrt/tuck_rt.odin:612` and `tuckrt_d/tuck_rt.d:347` are plain structs with
non-atomic `head`, `tail` and `data`, written by senders and read by the
actor's own thread with nothing between them. `tuck_rt.odin:610` still
explains the absence:

> Actor mailbox: a fixed ring. Single-threaded and cooperative, so unlike the
> Nim runtime there is no lock — sends and drains never interleave mid-op.

True before thread-per-actor. Not true since.

### 2. The Odin backend's `send` never notifies

`genSender` (`codegen_odin_decl.nim:757`) emits only the enqueue:

```odin
sendAdd_tuck_Counter :: proc(self: ^tuck_Counter, n: int) {
	_ = rt.enqueue(&self.mailbox, tuck_CounterMsg{tuckTag = .msgAdd, n = n})
}
```

There is no `rt.tuckNotifySend()`. `actorMain` parks on a condvar when its
mailbox comes up empty (`tuck_coro.odin:646`), so a send to a parked Odin
actor is a lost wakeup: the message sits in the ring and nothing ever
arrives to drain it. The D backend emits the notify and is correct in shape.

### 3. `tuckNotifySend` has diverged

The Nim runtime's now takes the actor's slot (2026-09-20) so a send wakes one
actor instead of broadcasting to all of them behind a global lock. Odin and D
still have the no-argument form, and their own codegen matches their own
runtime, so each backend is self-consistent — but porting the Nim mailbox
work means porting this signature too, not just the queue.

### Why nobody noticed

No Odin or D toolchain was installed, so every `odin build` / `dmd`
assertion in the suite reported SKIP rather than running.

### FIXED 2026-09-20, both backends, both defects

Odin was built from source (`dev-2026-09`, LLVM 18) once no release binary
new enough could be reached, so all three backends are now compiled and run
here. Both mailboxes have the spinlock, the two-buffer swap, the padding,
the adaptive spin and the targeted wake; the Odin `send` notifies.

Kept below as written, because the shape is the lesson: a scheduler changed
under two runtimes nobody in that session could execute.

### Status 2026-09-20 (superseded by the entry above)

**D: repaired and verified.** dmd 2.112 installed, `compiler/tuckrt/minicoro.a`
built by hand (gitignored, no in-repo build step — same recipe the
2026-08-11 handoff records). The mailbox now has a spinlock, the two-buffer
swap, padding, an adaptive spin before park and a targeted wake; the D
backend's actor examples build and run here.

**Odin: no release binary is new enough.** `dev-2025-03` is the newest
reachable one and the repo targets something about a year past it — 13
errors from core-library drift before any actor code is reached
(`os.make_directory_all`, `linux.timerfd_create`). The nightly host the
2026-08-11 handoff used is behind a CAPTCHA and the GitHub API is scoped to
this repo. BUILDING IT FROM SOURCE works and is what unblocked this:
`git clone` + `./build_odin.sh release` against `llvm-18-dev`, about eight
minutes. Worth doing before anyone concludes the Odin backend cannot be
tested.

---

## EV-16 — a `match` arm whose body is a `send` emits Nim that does not compile

**FIXED 2026-09-21, Nim only. Found by `benches/apps/world_server.tuck`,**
whose router is a `match` with one arm per shard — the only spelling
available, because an actor is a compile-time singleton with no reference
type, so there is nothing to index and the dispatch cannot be a loop.

### Reproduce

```tuck
actor A [queue: 8]:
  n: int = 0
  on tick({v: int}):
    n += v

fn route({s: int}):
  match s:
    | 0 -> A send tick {v: 1}
    | _ -> A send tick {v: 2}
```

`tuck ch` says `OK`. `tuck b` fails:

```
world_server.nim(339, 3) Error: expression expected, but found 'keyword of'
```

### Cause

A `send` emits TWO lines on Nim — `enqueue` and then `tuckNotifySend`, which
names the actor so the runtime need not signal every actor in the program.
The second line indents itself from `ctx.indent`.

`processMatchArm` bumped `ctx.indent` for an arm body that is a BLOCK, and
not for one that is a bare expression. A `send` is a bare expression that is
nonetheless two lines, so the first line got the arm's indent from the
explicit prefix and the second fell back out to the `of` level:

```nim
  of 0:
    discard enqueue(tuck_Shard0Singleton.mailbox, ...)
  tuckNotifySend(tuck_Shard0Slot)       # <- outside the arm
```

Nothing in the corpus had caught it because every tracked `match` arm is
either a block or a single-line `return`.

### Fix

`compiler/codegen.nim:processMatchArm` bumps the indent for the bare-body
path too. Only the first line is prefixed there; the rest carry their own
indent, which is why the bump is what fixes them. Guarded by
`actor_mode`'s "a send inside a match arm stays inside the arm".

---

## EV-15 — a dead container handed to a threading fn still calls the copying wrapper

**Open. Severity: high on Odin and D, none on Nim.** Found by
`benches/apps/world_server.tuck`: 191 ms on Nim against 2.9 s on Odin and
**54 s on D**, for identical output.

Tuck already computes what is needed here. Every fn in the lighting path
gets `sink` on the Nim side —

```nim
proc tuck_pass*(f: sink tuck_Flood, at: int, to: int, step: int, keep: bool): tuck_Flood
proc tuck_relight*(sl: sink tuck_Slice, c: int, cols: int): tuck_Slice
```

— so liveness has proved the argument dead at the call. Odin and D do not
act on it. Their MOVED twin is reached only through `movedCallInto`, which
recognises `x = f(x, ...)`: the result written back into the same name. The
inner loop has that shape and is compiled well —

```odin
for (((to - tuck_w.i) * step) >= 0) {
    tuck_w = tuck_relaxOne_moved(tuck_w, step, keep)   // no copy
}
```

— but the shape one level up does not:

```tuck
let r = {f: a, at: lo, to: hi, step: 1, keep: false} pass
let b = {f: r, at: hi, to: lo, step: -1, keep: true} pass
```

`a` is dead after the first call and `r` after the second, and each still
goes through the copying wrapper. The missing rule is that a LAST USE at an
argument position is as good as the self-threaded shape — the same fact
`sink` is already emitted from.

---

## EV-14 — the dead intermediates of a threading chain are never freed

**Open. Severity: high on Odin.** `benches/apps/world_server.tuck` peaks at
**4.9 GB** on Odin against 80 MB on Nim and 16 MB on D, for the same
100 000 edits. This is the remainder of EV-12 after the ownership work: that
made a MOVED twin free the parameter it consumes, and made a returned value
safe to keep. Neither covers a local that is simply abandoned.

### Reproduce

`tuck_relight_moved`, emitted from six ordinary lines of Tuck:

```odin
tuck_a := tuck_Flood{...}; tuck_a.height = rt.tuckSeqCopy(...); tuck_a.lum = ...; tuck_a.light = ...
tuck_r := tuck_pass(tuck_a, lo, hi, 1, false); tuck_r.height = rt.tuckSeqCopy(...); ...
tuck_b := tuck_pass(tuck_r, hi, lo, -1, true);  tuck_b.height = rt.tuckSeqCopy(...); ...
return tuck_Slice{height = sl.height, lum = sl.lum, light = tuck_b.light, ...}
```

Twelve arrays are allocated; ONE is returned. `tuck_a` entirely, `tuck_r`
entirely, and `tuck_b`'s `height` and `lum` are dead at the `return` and
nothing frees them — about 24 KB per edit, which is the 4.9 GB.

`relight` is correctly NOT eligible for the twin free: it returns
`sl.height` and `sl.lum` unchanged, so `slotIsFresh` says no and freeing the
parameter would free what the caller is about to bind. That decision is
right and is not what is missing. What is missing is that the analysis has
nothing to say about a local which is neither returned, nor stored, nor
moved into a call — the third case in the escape list has no owner.

D does not leak (its GC collects) and pays in time instead: the same
abandoned copies are EV-15's 54 seconds. The two are one cause with two
prices.

### What it needs

`thoughts/ownership-analysis-plan.md` already has the shape: a local whose
provenance is `oFresh` and whose liveness ends before the scope does is
freeable at its last use. Both halves exist —
`analysis_provenance.slotIsFresh` and `analysis_liveness` — and have not
been joined for this case.

---

## EV-13 — a `Seq` sent to an actor is not copied: the sender keeps writing it

**FIXED 2026-09-21, D and Odin (Nim was never affected). Issue #76.** Found
while checking whether free-insertion would be safe — the answer turned out
to be that the existing code was already unsafe.

The copy now happens in the generated send helper
(`codegen_odin_decl.nim:genSendHelper`, `codegen_d_decl.nim`), which is the
one place every send passes through, and the place a future MOVE would
replace it. The predicate is `copyableContainer`, exported from
`codegen_common` so the send and the `_moved` wrapper cannot drift on what
"owns heap" means — and it correctly excludes `str`, which is immutable in
both backends. Guarded by `value_semantics`' "a Seq sent to an actor is
copied, not shared" (`hostRuns`, three legs); verified to fail without the
fix.

### Reproduce

```tuck
import seq
actor Sink [queue: 8]:
  got: int = 0
  on take({xs: Seq[int]}):
    got = xs[0]

fn main() -> int:
  var payload = [42, 1]
  Sink send take {xs: payload}
  payload[0] = 99              # after the send. The actor must not see this.
  Sink.waitUntil {pred: :ready}
  return Sink.got
```

| | nim | odin | d |
|---|---|---|---|
| `--actors:single` | 42 | **99** | **99** |
| `--actors:thread` | 42 | **99** (8/8 runs) | **99** (8/8 runs) |

### What is emitted

The message struct holds the container by value, and the send site does not
copy it:

```odin
tuck_SinkMsg :: struct { tuckTag: tuck_SinkMsgKind, xs: [dynamic]int }

sendTake_tuck_Sink :: proc(self: ^tuck_Sink, xs: [dynamic]int) {
	_ = rt.enqueue(&self.mailbox, tuck_SinkMsg{tuckTag = .msgTake, xs = xs})
}
```

`xs = xs` copies the header. The buffer is shared, so the sender's later
write lands in the actor's mailbox.

### Why it is worse than the other aliasing bugs

It breaks **two** guarantees at once, and the second is the actor model's
whole point:

1. Value semantics — a `Seq` assignment copies. The send is a binding like
   any other and does not.
2. Actor isolation — "a singleton that owns state nobody else touches"
   (`actor_mode.nim`). Here the sender touches it, from another OS thread,
   with no synchronisation. In `--actors:thread` that is a data race in the
   C11/C++11 sense, not merely a stale read; the 8/8 result above is this
   machine's timing, not a guarantee.

Nim is immune for the usual reason: its `seq` has real value semantics, so
the struct literal copies. A one-backend test reports green.

### Root cause: the same hole as the others

`markSeqCopies` (`lowering_seqcopy.nim:90`) walks `exkAssign` and nothing
else. A send payload is not an assignment, so the site is never marked. The
pass is named for the fact it decides — "which copies must be real" — but it
only ever asks the question at assignments.

This is EV-9's hole (fast paths skip the field handling), the `wrap` hole
(a returned record's fields may alias a parameter), and now this one, all of
the same shape: **a place where a heap value is bound that the copy pass
does not visit.**

### Fix

Two, and both are wanted:

1. **Immediately**: mark the send payload. Every `Seq`/`str`-typed argument
   of a send, and every such field of a record argument, needs the copy the
   pass already knows how to emit. Narrow, and it closes the race.
2. **Properly**: the send is an OWNERSHIP TRANSFER, not a copy — the natural
   thing is to move the buffer into the message and leave the sender without
   it, which is what the user asked for when `[queue: N]` was designed around
   moving batches. That needs the liveness half of the ownership analysis
   (`thoughts/who-frees-concrete-cases.md`), which also has to know that a
   sent value ESCAPES and must not be freed by the sender.

Guard with `hostRuns` on all three backends under both `--actors:single` and
`--actors:thread`; single mode is the deterministic one and is enough to
catch the regression.

---

## EV-12 — the Odin backend never frees a heap value: every copy leaks

**Issue #77.**

**Severity: highest. Odin only, no diagnostic, and the program runs
correctly right up until the OOM killer takes it.** Found 2026-09-20 when
`benches/apps/matching_engine.tuck` was killed with exit 137 on Odin while
Nim and D ran the same program in 20 MB.

### Reproduce — no actors, no threads, no concurrency

```tuck
import seq

fn bump({xs: Seq[int]}) -> Seq[int]:
  var ys = xs          # the copy
  ys[0] = ys[0] + 1
  return ys

fn main() -> int:
  var xs = {levels: 1024} zeroed
  var i = 0
  for i < 100000:
    let ns = {xs: xs} bump
    xs = ns
    i = i + 1
  return xs[0] % 7
```

100 000 copies of a 1024-element `Seq[int]`:

| backend | peak RSS | exit |
|---|---|---|
| nim | 1 MB | 5 |
| d | 6 MB | 5 |
| **odin** | **2 352 MB** | 5 |

All three compute the same answer. Only the memory differs, and it differs
by three orders of magnitude.

### In the application it is fatal

`matching_engine.tuck` copies a price ladder per level walked, which is what
Tuck's value semantics ask for — a parameter is an immutable copy, so a
helper that consumes liquidity returns a new ladder rather than mutating the
caller's:

| orders | nim | d | odin |
|---|---|---|---|
| 50 000 | 21 MB | 11 MB | 3 748 MB |
| 100 000 | 21 MB | — | 7 500 MB |
| 200 000 | 21 MB | 17 MB | **killed, 13.6 GB** |

Odin's growth is linear and steep: **about 75 KB per order**. Nim and D are
flat, because both have a collector behind the copy. Odin does not, and
nothing in the emitted code frees anything.

**After EV-9 was fixed**, the same 200 000 orders complete on Odin in
5 580 MB instead of being killed at 13.6 GB — the workaround EV-9 forced was
tripling the allocation, exactly as the section below predicts. Nim and D are
unchanged (21 MB, 22 MB) and all three still print the same book. Odin still
leaks 5.5 GB, which is this bug proper: `takeLevel` copies the ladder once
per price level walked and that copy is never freed. The amplification is
gone; the leak is not.

### Why this is the worst of today's finds

The other four are compile errors: loud, immediate, and they cost an
afternoon each. This one compiles, runs, produces correct output on every
input small enough to finish, and passes every test in the suite — because
no test allocates in a loop long enough to matter. It fails only at a size
where the failure is a `Killed` with no message.

It also undercuts a documented promise. `--odin` exists for the no-runtime,
no-GC target; a backend that leaks every heap value is the one target where
that matters most. And it interacts with value semantics specifically, which
is the language's central design choice — the more idiomatic the Tuck, the
faster it leaks. `takeLevel` above is written exactly as the language wants
it written.

### The culprit, in two parts

**1. The Odin backend never frees anything.** `tuckSeqCopy` allocates
(`reserve` + `append`, `compiler/tuckrt/tuck_rt.odin:131`) and
`compiler/tuckrt/tuck_rt.odin` contains **no `delete` and no `free` at all**.
The generated code is no better: `codegen_odin*.nim` emits exactly one
`free`, at `codegen_odin.nim:1051`, and it is for a task's argument
environment struct — nothing to do with `Seq`. So every copy and every
`append`-grown `[dynamic]T` in an Odin program is live until the process
exits. D emits the same copies and survives only because D has a GC.

**2. A defensive copy is emitted for call results that cannot alias.**
`markSeqCopies` in `compiler/lowering_seqcopy.nim:95` exempts exactly one
node kind:

```nim
if e.assignVal != nil and e.assignVal.kind != exkList:
  if isSeqValued(res, e.assignVal):
    ensureId(e.assignVal); dupSites.incl(e.assignVal.id)
```

The file states the reasoning — "everything else does, including a call
result, since a call may hand back its own argument" — and for an arbitrary
fn that is true. But a `twinnableFn` already copies its first parameter in
the `f` wrapper before delegating to `f_moved`
(`codegen_odin_decl.nim:398`), so for exactly those fns the caller's copy is
copying a value the callee already made fresh. Both layers fire, and each
one alone would have been sufficient.

### The two interact, and EV-9 is what triggers it

`movedCallInto` recognises `x = f(x)` and calls the twin directly, emitting
no copy at all. The same loop written through a local does not match, so all
three copies come back:

| Tuck | Odin emitted | peak RSS |
|---|---|---|
| `xs = {xs: xs} bump` | `tuck_xs = tuck_bump_moved(tuck_xs)` | **0 MB** |
| `let ns = {xs: xs} bump` / `xs = ns` | 3x `rt.tuckSeqCopy` | **2 352 MB** |

Same program, same answer (exit 5). The difference is only whether the
assignment matches the move pattern.

**And EV-9 forced the losing spelling.** An actor field assigned from a call
that takes it did not compile on D or Odin, so the workaround was precisely
`let t = f(st); st = t` — which defeats `movedCallInto` and reinstates every
copy. The matching engine leaked 75 KB per order *because* of the workaround
it needed to compile: two bugs each merely bad composing into one that was
fatal. Fixing EV-9 removed the amplification and turned the OOM into a
completing run, which is the measurement above.

### Fix

Part 2 looks like a one-liner and is not one. The obvious version — exempt
a call whose callee has a moved twin, reusing `movedFnParam` — is **wrong**,
because the twin only copies the FIRST parameter:

```tuck
fn pick({a: Seq[int], b: Seq[int]}) -> Seq[int]:
  return b
```

`pick` is twinnable (`a` threads back to the return type), so the wrapper
copies `a` and returns `b` untouched. Exempting the call site would let
`x = {a: p, b: q} pick` alias `x` to `q` — reintroducing the exact bug this
pass exists to prevent, in the one place it is hardest to notice. The
exemption has to rest on "this call returns only its copied first parameter
or a fresh value", which is an analysis, not a predicate that already
exists. It would also mean `lowering_seqcopy` reaching into
`codegen_common` for `movedFnParam`, inverting the layering the file's own
header argues for.

So the cheap win here was **fixing EV-9**, which removed the trigger without
touching this pass at all: with `st = f(st)` compiling on D and Odin,
`movedCallInto` matches and no copy is emitted at the call site. Done —
and it was worth 8 GB on the matching engine. What remains below is the
structural half, which that did not touch.

Neither makes Odin correct. Part 1 is structural and has to be paid.

**Does the language already have the answer?** Tuck has three ownership
constructs — `defer` (§7.4), pools with `acquire`/`release` (§7.2-7.3), and
the `resources:` registry (§7.4). Asked and worked through, because reusing
one of them would beat inventing anything:

- **`defer`: the emission, not the decision.** All three backends already
  emit it (`codegen.nim:846` Nim `defer:`, `codegen_odin.nim:1123` Odin
  `defer {}`, `codegen_d.nim:1141` D `scope(exit)`), so no new backend
  primitive is needed. But it answers *how to free*, and the hard half here
  is *what*. A blanket `defer delete` on every `tuckSeqCopy` result is a
  USE-AFTER-FREE, not a fix: `takeLevel` returns its copy and `applyBuy`
  stores its ladders into the returned record. It needs the escape analysis
  that `movedFnParam`/`movedCallInto` gesture at and do not complete.
- **`resources:`: wrong shape, by its own design.** §7.4 opens by rejecting
  scope-based RAII in favour of "a global table of handles (the process fd
  table)". It wants named kinds, declared acquire sites (`[resource: udp]`),
  and a generation counter per entry to close the fd-reuse bug class. A
  ladder copy is anonymous, compiler-generated, has no identity worth a
  generation, and offers no acquire site to annotate. A registry entry per
  `Seq` binding is a lot of machinery aimed at the wrong scarcity.
- **Pools: not writable by a user, but the best machinery.** `Seq[T]` is
  variable-length where a pool is a static array of a fixed type, and the
  copies are invisible so there is no call site for `acquire`/`release`. But
  the runtime already HAS the pool (slot array, occupancy bitmask, O(1)
  release, tenancy — `tuckrt/tuck_rt.odin:312`), and in the matching engine
  every leaked copy is the same size and short-lived, which is a pool's
  sweet spot.

Note also that **no Tuck-level verb frees a `Seq`** — no `free`, `delete` or
`dispose` in `std/` — so all of these are compiler-internal options; none is
something a program could reach for. And "stop relying on backend GC" is not
quite the frame: D relies on its GC and is fine at 22 MB. Only Odin has no
story, so the obligation is backend-local and a language construct would
have to avoid pessimizing the two targets that already work.

So, ranked — and the ranking turns on SAFETY UNDER IMPRECISE ANALYSIS, not
on cost:

1. **Arena or pool per handler.** An actor handler is a natural scope:
   allocate from an arena, reset it when the handler returns, over the pool
   machinery the runtime already has. A wrong guess RETAINS a buffer; it
   never frees one early. Only covers values that do not outlive the
   handler, which is most of them.
2. **`defer delete` for non-escaping temporaries.** Cheap to emit, and the
   construct already exists on all three backends — but correctness rests
   entirely on escape analysis, and the failure mode is a use-after-free
   rather than a retained page. Second for that reason, not for cost.
3. **Run a tracking allocator in debug builds**, so a leak is reported at
   exit rather than discovered by the OOM killer. Worth doing whichever of
   the above lands — it is what would have caught this before an
   application did.

A regression test belongs in the suite either way: allocate in a loop, assert
peak RSS stays bounded. Nothing currently measures memory at all.

### Fixing it also unlocks a 4x that is currently unreachable

`tuckSeqCopy` used to copy with `reserve` plus an `append` per element; it
now does one bulk `copy`. On 200 000 copies of a 1024-element ladder:

| | append | bulk | ratio |
|---|---|---|---|
| copies freed, one block reused | 198 ms | 49 ms | **4.1x** |
| copies never freed (today) | 245 ms | 195 ms | 1.26x |

With nothing freed, every copy is a fresh page-faulting allocation and the
ALLOCATOR dominates — so the better copy is worth about 10% on the matching
engine rather than 4x. The two fixes are multiplicative, and this is the
argument for doing the leak first: until memory is reused, no amount of
making the copy faster shows up.

---

## EV-11 — a feed that outruns its actor silently loses messages, then deadlocks

**Issue #7 (pre-existing; evidence added).**

**Severity: highest of the five found today. All three modes, all three
backends, and the program does not crash — it hangs.** Found 2026-09-20 by
running `benches/apps/matching_engine.tuck`, the first application written
against the actor runtime rather than a benchmark.

### Reproduce

Any actor with a `[queue: N]` and a sender that produces faster than the
actor consumes — which is the normal case, since the sender does no work
per message and the actor does:

```tuck
actor Book [queue: 8192]:
  ...
  on endOfDay({n: int}):
    atClose = true

fn main() -> int:
  {n: 200000} flow          # 200k sends in a plain loop
  Book send endOfDay {n: 0}
  Book.waitUntil {pred: :closed}
  return 0
```

| orders | result |
|---|---|
| 4 000 | exits 0 |
| 8 000 | exits 0 |
| 20 000 | **hangs** |

8 192 is the queue depth. Every mode hangs at 200k:
`--actors:single`, `--actors:thread` and `--actors:batch` alike.

### What actually happens

`enqueue` returns `false` on a full mailbox and the send site discards the
result — drop-on-full, which is deliberate (spec §9.1, and the ruling in
`thoughts/ledgers/`: "mechanism stays simple; backpressure is the sender's
job"). So the overflow orders are silently lost, which for a matching engine
is already the worst possible failure mode.

The hang is the second-order effect. `endOfDay` is **just another message**,
so it is dropped along with the orders. `atClose` is never set, and
`waitUntil` waits forever on a predicate that nothing can make true. The
program burns no CPU while doing it — 2m25s wall on 4.6s of CPU in the run
that first showed this — so it looks like a deadlock in the scheduler and is
not one. The delivery guarantee is the bug; the hang is a symptom.

Single mode reaches it fastest and for an extra reason: the actor is a
coroutine on main's thread and `flow` has no yield point, so the actor does
not run **at all** until main blocks in `waitUntil`. The mailbox is the only
thing absorbing the feed, and past N it stops absorbing.

### Why there is no way to write this correctly today

The ruling puts backpressure on the sender, and the runtime provides exactly
the primitive that would do it:

```nim
proc hasRoom*[T; Cap: static int](mb: var Mailbox[T, Cap]): bool =
  ## Sender's opt-in backpressure check. sendX drops silently on a full
  ## mailbox (fast, non-blocking, spec §9.1) — the sender may check first if
  ## it cares.
```

**No Tuck program can call it.** `hasRoom` appears in the compiler only in
the reserved-identifier lists of `codegen_d.nim` and `codegen_odin.nim`, so
the backends know not to shadow the name — and nothing else. No surface
syntax emits the call, no example uses it, `std/` does not wrap it. The
sender is assigned a job the language gives it no verb for.

Nor is there a way around it: `F14` (a reply address on a message) is
unimplemented, so an actor cannot signal demand back, and with no actor
references there is no supervisor to hold the feed. The only lever a Tuck
program has today is to size `[queue: N]` above the largest burst it will
ever see, which is not backpressure — it is hoping.

### Fixes, cheapest first

1. **Expose the check.** Surface `hasRoom` as a Tuck expression, e.g.
   `Book.hasRoom`, matching `Book.waitUntil`'s spelling. This alone makes
   the documented story true, and is a codegen addition with no semantic
   change. Smallest thing that removes "impossible" from the list.
2. **Make single mode lossless.** With one thread, a full mailbox means the
   actor has not run and provably nobody else can make room, so dropping is
   guaranteed loss where running the actor is guaranteed progress. Either
   grow the buffer (`when TuckActorsSingle`, entirely inside `tuck_rt.nim`)
   or have the send site pump the scheduler and retry. Note this makes
   `[queue: N]` mode-dependent, which is a design call, not a bugfix.
3. **Do not drop control messages silently.** Whatever the policy, a
   dropped send that nothing can observe turns a data-loss bug into a hang
   somewhere else entirely. At minimum a drop counter the program can read;
   `F14` is the real answer.

The first is worth doing regardless of the other two: today's answer to
"how do I not lose messages" is that you cannot ask.

---

## EV-10 — two handlers binding the same local name: the second is undeclared

**Issue #79.**

**Severity: high. Every backend, and `tuck ch` says OK.** Found 2026-09-20,
the third bug in one afternoon of writing an ordinary application.

### Reproduce

```tuck
actor Book [queue: 8]:
  a: int = 0
  b: int = 0

  on buy({n: int}):
    let r = n + 1        # `r` here...
    a = a + r

  on sell({n: int}):
    let r = n + 2        # ...and `r` again here
    b = b + r
```

### What is emitted

Both handlers are arms of ONE `case` in `handleMsg`, and each arm is its own
scope. Codegen tracks which names it has already declared in a set that
spans the whole actor, so the second arm emits an assignment to a name that
was declared in a sibling branch:

```nim
of msgBuy:
  var tuck_r = (n + 1)     # declared
  ...
of msgSell:
  tuck_r = (n + 2)         # NOT declared -> undeclared identifier
```

All three backends reject it, each in its own words.

### Why it matters

Handlers are written independently and short, so they reuse the obvious
names — `r`, `s`, `item`, `result`. Two handlers on one actor is the normal
case, not a corner. The failure is also confusingly located: the error points
at the SECOND handler, which is correct Tuck, while the cause is that the
first one claimed the name.

### Fix

`definedVars` has to be scoped per handler arm, not per actor. The dispatch
builds one `hctx` for the whole actor (`genActorDispatch`), which is where
the set is shared; each arm wants its own copy seeded from the enclosing
scope.

---

## EV-9 — an ACTOR FIELD as assignment target loses its `self.`

**FIXED 2026-09-20, all three backends.** Found writing an application; the
second bug the first non-toy program hit. `tuck ch` said OK throughout.

The fix is one idea in three places: the two FAST PATHS in `genAssign` — the
in-place append and the MOVED twin call — spelled the target as a bare
`e.target.name`, bypassing the field handling the normal path does a few
lines below. Each backend now routes the target through the same
qualification its ordinary expression emitter uses
(`codegen.nim:genSelfAppendAssignment`, `codegen_d.nim:movedAssignTarget`,
`codegen_odin.nim:movedAssignTarget`).

Guarded by `tests/suites/known_bugs.nim`, "an actor field survives an append
and a moved call" — `hostRuns` on all three, because the two paths split the
backends between them and a one-backend assertion would have reported green
on whichever half it missed. Verified to fail without the fix.

### Reproduce

```tuck
import seq

actor Box [queue: 8]:
  xs: Seq[int]
  n: int = 0

  on fill({k: int}):
    xs = {items: xs, value: k} push     # a push BACK INTO a field
    n = n + 1

fn ready() -> bool:
  return Box.n == 1

fn main() -> int:
  Box send fill {k: 5}
  Box.waitUntil {pred: :ready}
  return 0
```

`tuck ch` says `OK`. All three backends then refuse the code they were given:

```
nim  : t.nim(26, 7)   Error: undeclared identifier: 'xs'
d    : t.d(24)        Error: undefined identifier `xs`
odin : t.odin(24:5)   Error: ...ambiguous call for 'append'   [append(&xs, k)]
```

### What is emitted

```nim
xs*: seq[int]        # the field is declared on the object
...
xs.add(k)            # but the write names a local that does not exist
```

The receiver-threading rewrite that turns `x = {items: x, value: v} push`
into an in-place append drops the `self.` qualifier. The SAME handler emits
`self.n = self.n + 1` correctly one line later, and a plain
`self.askQty = <expr>` elsewhere in the same actor is also correct — it is
only the chain rewrite that forgets which namespace it is in.

### Not the optimizer

`-O:none` produces the identical error, so this is codegen's own receiver
threading and not `opChainInPlace`. Worth saying because `-O:none` is the
documented first move when emitted code looks wrong, and here it clears the
suspect without clearing the bug.

### Wider than `push`, and the clean repro is a plain call

Found later the same day, and it is the better statement of the bug. No
chain, no collection, no `seq` — just an actor field passed to a fn and
assigned back:

```tuck
type BookState:
  trades: int

fn applyBuy({b: BookState, px: int, qty: int}) -> BookState:
  return {trades: b.trades + 1} BookState

actor Book [queue: 8]:
  st: BookState

  on buy({px: int, qty: int}):
    st = {b: st, px: px, qty: qty} applyBuy
```

Here **Nim is correct and the other two are wrong** — the mirror of the
`push` case, where all three failed:

```nim
self.st = tuck_applyBuy(self.st, px, qty)          # nim: right
```
```d
st = tuck_applyBuy_moved(self.st, px, qty);        // d:    LHS lost self.
```
```odin
st = tuck_applyBuy_moved(self.st, px, qty)         // odin: LHS lost self.
```

The right-hand side keeps its `self.` in both. Only the assignment target
loses it, and only when the target is also an argument — a plain
`self.st = <unrelated expr>` is emitted correctly. So the trigger is the
move/`_moved` path: recognising `f(self.st)` as move-eligible rewrites the
statement and the LHS is rebuilt from the bare field name.

That makes the real rule **"an actor field assigned from a call that takes
it"**, of which `x = {items: x, ...} push` is one instance. Which backends
break depends only on which of them take the `_moved` route.

Routing the value through a local confirms it — `let t = {b: st, ...} f`
then `st = t` compiles and runs on all three, because the target is no
longer an argument. That is the workaround, and it is also the proof of
where the rewrite goes wrong.

### Why it was not caught

The value-semantics suite has "an actor handler may still mutate its own
fields", but with scalar fields — `total += n`, where there is no call to
be move-eligible. Every existing chain and move test uses a local or a
parameter, where there is no `self.` to lose. An actor field that is
*both* the assignment target and an argument is the intersection nothing
covered — and it is the single most natural way to write a handler that
folds a message into state.

---

## EV-8 — a type and a fn differing only in first-letter case collide on Nim

**Issue #78.**

**Severity: high. It fires on the most ordinary naming in the language, and
only on one backend.** Found 2026-09-20 while writing an application, not a
test — the first non-toy program hit it immediately.

### Reproduce

```tuck
type Sweep:
  x: int

fn sweep({n: int}) -> Sweep:
  return {x: n} Sweep

fn main() -> int:
  let s = {n: 7} sweep
  return s.x
```

`tuck ch` says `OK`. `tuck b --dlang` and `tuck b --odin` both build and exit
7. `tuck b` (Nim) does not compile:

```
t.nim(4, 6) Error: redefinition of 'tuck_sweep';
            previous declaration here: t.nim(7, 6)
```

### Why

Mangling gives the type `tuck_Sweep` and the fn `tuck_sweep`. **Nim identifiers
are style-insensitive**: after the first character, case and underscores are
ignored, so those two ARE the same identifier to Nim. D and Odin are
case-sensitive and take both.

The two names are not a collision in Tuck and are not a collision in two of
the three backends. They are a collision only because the Nim mangler keeps
the user's case after a fixed lowercase prefix, which puts the
distinguishing character in the one position Nim ignores.

### Why this matters more than it looks

`type Sweep` + `fn sweep` is not a contrived pair. Capitalised types and
lowercase functions is the convention this repo's own examples follow, so
`type Order`/`fn order`, `type Book`/`fn book`, `type Reading`/`fn reading`
are all the same bug waiting. It is invisible to `tuck ch`, which is where
most of the test suite stops.

### Confirmed again the same afternoon, on an ACTOR

The paragraph above listed `type Book`/`fn book` as "the same bug waiting".
It was: `actor Book` beside `fn book` in the matching engine failed with
`redefinition of 'tuck_Book'`. So the scope is wider than types and fns —
it is **every pair of Tuck identifiers that differ only in case**, across
all four namespaces (type, fn, actor, task).

Worth stating the mechanism precisely, because the first writeup was too
gentle about it. Nim exempts the FIRST character from style-insensitivity,
which is what normally lets `Book` and `book` coexist in Nim itself. The
`tuck_` prefix spends that exemption: both mangled names begin with `t`, so
the character that distinguishes them lands at index 5, where Nim ignores
it. The mangler does not merely fail to prevent the collision — it
manufactures collisions between names Nim would have accepted unmangled.

### Fix

The mangler must put something Nim cannot ignore between the prefix and the
name, for one of the namespaces — e.g. types as `tuckT_Sweep` against fns as
`tuck_sweep`. Anything that relies on case alone will not survive Nim's
identifier rules. Worth an assertion in the mangle suite over each pair of
namespaces that differs only in case.

---

## EV-6 — a multi-actor D program crashes at exit, about 1 run in 10

**Severity: medium. Intermittent, and it is a CRASH, not a warning.** Found
2026-09-20, the first time a D toolchain was available to run the suite.

A D program with more than one actor sometimes aborts or segfaults during
exit, after producing entirely correct output. It announces itself as

> The futex facility returned an unexpected error code.

and the process leaves with SIGABRT (exit 134) or SIGSEGV.

### Measured

`examples/45-intersection`, 30 consecutive runs, expected exit 3:

| runtime | failures |
|---|---|
| before the 2026-09-20 mailbox port | 3 / 30 |
| after it | 4 / 30 |

PRE-EXISTING, and the port did not meaningfully move it. It is what made
`d run 45-intersection` fail one full-suite run and pass the next.

`tuckStartActor` already sets `t.isDaemon = true`, so this is not druntime
waiting on the actor threads. The likely remainder is druntime tearing down
while a daemon thread sits in `Condition.wait` on a mutex it is about to
destroy — the actors are detached by design and nothing joins them. The Nim
runtime has the same detached-daemon design and does not do this, so the
fix is probably a D-side shutdown handshake rather than anything about the
mailbox.

Not chased here: it is orthogonal to the mailbox work, and a fix wants to
be its own change with this failure rate as its test.

---

## EV-7 — a send can be lost against an actor that is just about to park

**FIXED 2026-09-20, all three backends.** Found by inspection while making
the wake path per-actor; NOT introduced by that change — the same window
existed with the global `gIdleActors` counter it replaced.

Reproduced before fixing, which is what the entry originally asked for. The
window is a few instructions wide in a real build, so `-d:TuckTestParkDelayMs`
(inert at its default of 0) widens it inside `actorMain`, between "this actor
last looked and saw nothing" and "this actor is marked parked". With it at
5ms: **1 send lost in 120 rounds**. With the fix and the same hook still in:
0 lost in 360.

### The interleaving

```
  actor                                sender
  drain() -> empty
                                       enqueue(mailbox, msg)   # visible
                                       load(parked) -> 0       # not yet!
                                       return without signalling
  acquire(slot.lock)
  pending is false -> parked = 1
  wait(cond, lock)                     # asleep, message undelivered
```

Nothing else will wake it: `pending` is only set by a wake, and the next
send only signals if it finds `parked` already set. `tuckDrainActors` then
reads the actor as quiescent (`working` false, `pending` false) and lets the
process exit with the message still in the mailbox; a `waitUntil` whose
predicate needed that message waits forever.

The `parked` store and the sender's load form a store-then-load pair on both
sides, which x86 is permitted to reorder, so this is not merely a
"sufficiently unlucky scheduler" window.

### The fix

Arm-and-recheck, the standard protocol: the actor publishes `parked`, then
drains ONCE MORE before sleeping. That closes the window from the actor's
side alone, leaving the sender's fast path untouched — the re-drain takes
the mailbox spinlock, whose exchange is a full barrier, so the arming store
is globally visible before any send that could follow it. Either the recheck
sees that sender's message, or that sender sees `parked` and signals.

---

## Not bugs, checked and cleared

- **`raisedEventsIn` missing node kinds.** Was real; fixed 2026-08-14 in
  `e42e7e1` by walking `ast.children` instead of a hand-written list of ten.
- **Payload explosion inside tasks.** Looked broken by inspection
  (`lowerModule` never reaches `taskBody`) but works, because codegen does the
  same transform independently. See EV-1's "why nobody noticed".
