# Stackless concurrency (#216)

Status: **design, with a measured spike** (`research/stackless/`). Phase 1,
the colouring, is built: `tuck frames f.tuck` prints it
(`compiler/frames.nim`, pinned by `tests/suites/frames.nim`). Nothing is
rewritten yet.

## The owner's rulings (2026-11-09)

1. **The semantics stay exactly as they are; only the implementation
   changes.** Tasks, actors, `on select`, sends, awaiting by binding, and
   `main` lending its thread (A94) all behave as today. A compiler flag picks
   the implementation: `--concurrency:stackful` (minicoro, today) or
   `--concurrency:stackless`.
2. **The `[io]` effect makes the async points**, bare `[io]` or any kind
   (`[io: net]` and the rest), just as today. There is no new marker or
   effect, and no `await`.
3. **Tasks and actors are converted together.** The new pass reuses the
   existing analysis: the semantic layer's `asyncCalls`, call edges, SSA
   liveness and the ownership rules.
4. **Frames go on the heap by default.** When a frame's count and size are
   known at compile time, it goes in a slab or on the stack instead, for
   devices with little memory or no heap.
5. **Stage representation and function values follow stagelane**
   (`Ghazalialshafi/stagelane`): stage fns plus a `Hop` trampoline. A
   suspending fn cannot be stored in a `fnsig` slot.

This supersedes the 2026-08-05 runtime ruling (ROADMAP.md, "User rulings"),
which chose stackful only because two hand-written transforms, one per
backend, would drift apart. That risk is avoided here by doing the splitting
**once, on the checked Tuck AST**. Each backend only prints the result.

## Why: the spike

`research/stackless/README.md` has the full table and the caveats. Code
lowered by hand into the form below, against `tuck b --release` today:

| | stackful | stackless |
|---|---|---|
| spawn + await, 2 `[io]` calls | ~4.8 µs | ~10–20 ns |
| task switch | 230 ns | 3 ns |
| spawn | 3.7 µs | 30 ns |
| memory per live task | 256 KB reserved stack | the frame (48 bytes for the example) |

It also needs no `mmap` and no stack switching, so spec Part 9's
"stackless bare-metal path" stops being separate future work. It removes
the Odin gap where a task with arguments cannot be spawned as a coroutine:
a frame is an explicit struct, and nothing has to capture.

## The shape of the output

A **suspending fn** becomes:

* **a frame**: a record whose first field is the header
  `{stage, caller, next}`. It holds the parameters, a `dest` pointer for the
  result (or, for a task root, the result slot) and the locals that cross a
  pause. Locals that do not cross a pause stay ordinary locals of one stage.
* **stages**: plain fns `(env) -> Hop`, one per stretch of code between
  pause points. `Hop = {fn, env}` is returned in two registers;
  `drive` is `while hop.fn != nil: hop = hop.fn(hop.env)`.

What each construct turns into:

* **Pause:** store the frame where it waits (the ready list, a slot, the
  reactor's fd table, the timer wheel or a mailbox), set `stage` to the
  continuation, and return `noStep`. The C stack unwinds to `drive`.
* **Call of a suspending fn:** allocate the callee frame, set its
  `caller`/`dest`/arguments, set our own `stage` to the continuation, then
  **enter the callee's first stage directly** (`return calleeS0(c)`).
* **Return:** write through `dest`, free the frame, and return the caller's
  continuation hop.
* **Loop back edge:** a direct call into the loop head stage. A loop's step
  stage is placed after its body so the jumps into it are direct calls.

`bench_stackless.nim` is a worked example of every one of these.

## The pass

### Where it runs

There is one new lowering pass, `lowering_stackless.nim`. It runs on each
backend's deep copy after typecheck, semantics and the ownership rules, and
only under `--concurrency:stackless`. It emits **new AST node kinds** for
frame declarations, stage fns, hop returns and pause operations, following
the rule that each construct gets its own node kind. Each backend's codegen
prints these, which is a few dozen lines per backend. Splitting, liveness and
the frame layout are decided once, in the shared pass, so the backends cannot
disagree on them. Under the stackful flag the pass does not run, and today's
output is byte-identical.

### 1. Colouring: which fns become frames

* **Pause sites already known:**
  * every call site in `semLayer.asyncCalls`, which is every call to an
    `[io]` callee, bare or kind;
  * `exkSelect`;
  * `exkSend` into an actor whose `on_full` is `wait`;
  * a binding that awaits a task;
  * `waitUntil`;
  * the runtime's parking externs (fd I/O, sleep, the offloaded blocking
    calls).

  The set `semantics.mayDoIoUnseen` already recognises is the starting point.
* **Roots:** task bodies, actor `on` handlers and `on select` arms.
* **Frame fns:** every `[io]` fn reachable from a root through
  `ast_query.calleeDecl` edges. This is a fixpoint over the call graph; no
  callee name is re-derived. Because a fn that reaches an `[io]` call must
  declare `[io]`, "suspends implies `[io]`" holds without a new check.
* **Pause semantics are today's:**
  * In a **task body**, an `[io]` call site yields first and then calls.
    This is today's `(tuckYield(); call)` split at the semicolon.
  * In any other frame fn, an `[io]` call is a frame call that pauses only
    if the callee parks, the way today a park deep inside a call suspends
    the coroutine.
* **A frame fn called from a non-frame fn** (from `main`, or from a native
  fn) gets a native stub. The stub allocates the root frame (from the heap
  for now; on the stack once #219 lands) and runs the scheduler until the frame finishes: today's
  A94 rule, unchanged.
* **Later refinement, after measuring:** stagelane's purity. An `[io]` fn
  whose `[io]` calls reach no parking extern (a fn that only prints) stays
  native. This needs the runtime's externs tagged as park or no-park.
  Semantics do not change, because the task-body yield before the call
  stays.

### 2. Splitting the body into stages

The splitting works on the structured AST, statement by statement, in the
style of stagelane's `lower*`:

* **Expressions:** a pause inside an expression is hoisted into a `let` first,
  keeping evaluation order. TK-PA13, which forbids calls inside payloads,
  already does most of this.
* **`if` and `match`:** a branch that pauses ends in a jump to the join
  stage. A branch that does not pause stays inline.
* **`for` with a pause in its body:** head, body and step stages. `break` and
  `continue` become jumps; the back edge is a direct call.
* **`return`:** write `dest`, run the pending `defer`s, free the frame, hop
  to the caller.
* **`defer` across a pause:** a per-frame pending-action selector, as
  stagelane does for `finally`. Tuck has no `try`, and errors are `!T`
  values, so stagelane's exception routing (its hardest part) has nothing to
  do here.
* **Small fns:** the complexity ceiling keeps fns small, so stage counts
  stay small.

### 3. Frame layout

* **Which locals become fields:** those live across a stage boundary,
  computed with the existing SSA liveness (`analysis_liveness`,
  `ssa_build`). This is stagelane's `demoteFields`, with no new analysis.
* **Ownership:** the frame owns its fields. The ownership rules' moves,
  copies and drops (`tuckMove`/`tuckDrop`, rule D) apply to field accesses
  as they do to locals today. Freeing a frame drops only what the rules
  left owned. Tuck has no references and passes parameters by value, so
  nothing in a frame can borrow from a frame that might move.

### 4. Memory

**Heap first** (ruled 2026-11-09): every frame comes from the heap and is
reused through a per-type freelist (~30 ns per spawn, measured). Other
strategies wait until the heap version reaches parity, and are tracked in
**#219**:
* **Stack:** the root frame of a native stub.
* **Static slab:** an actor's handler chain, which is non-recursive and so
  has a size known at compile time.
* **Bounded task slabs:** tasks with a declared bound.
* **An embedded flag:** refuses any frame type that would fall back to the
  heap.

### 5. Function values

A frame fn cannot be stored in a `fnsig` slot (stagelane has the same
limit). This gets a new diagnostic, numbered at the end of its category in
`compiler/diagnostics.nim`, with `tuck explain` text that suggests wrapping
the call in a task or an actor message.

## Runtime

Each backend's `tuck_rt` gains a stackless runtime of roughly 300–500 lines:

* `FrameHdr`/`Hop`/`drive`, the ready FIFO and per-type freelists (the
  spike's `sl_rt.nim`);
* a timer structure (a hashed wheel like stagelane's, or a heap);
* the existing epoll/kqueue reactor and offload completion pipe, re-pointed
  to park frames instead of coroutines.

**Actors:** one root frame per actor drives its mailbox loop. A handler that
never pauses is a plain native call from that loop, which covers most
handlers. The three `--actors:` modes map directly:
* `single`: every actor's root on main's scheduler.
* `thread`: one scheduler per actor thread.
* `batch`: unchanged staging.

Frames carry no stack, so a later M:N pool mode becomes possible. It is not
in scope here.

## Phases and exit criteria

| phase | work | done when |
|---|---|---|
| 0 | spike | **done**: `research/stackless/` |
| 1 | colouring pass and a dump (`tuck frames`: frame fns and pause sites; frame fields move to phase 2, where liveness is computed for the split) | **done**: `tests/suites/frames.nim` pins examples 14/28/29/30/42/26/27 and one program per rule in `tests/frames/` |
| 2 | flag, splitting of straight-line code, `if`/`match`, the call protocol; tasks; Nim backend | examples 14 and 28 run identically under both flags |
| 3 | loops, `break`/`continue`, `defer`; Odin and D emitters, checking the `Hop` two-register return on their ABIs | the same, on all three backends |
| 4 | runtime parity: reactor, timers, `on select`, offload, waiting sends, `waitUntil` | examples 29, 30, 42 and the net suites pass under both flags |
| 5 | actors in all three `--actors:` modes, urgent mailboxes, `alive`/`pingUs` | `mailbox_full`, `actor_heartbeat`, Savina and the actor examples pass under both flags |
| 6 | (#219) static slabs for actor chains, stack root frames, embedded flag; measurements | numbers in `benches/SCORES.md`; a no-heap actor-only program builds |
| 7 | differential run: every concurrency suite under both flags in CI | equal results; the owner decides whether to change the default |

**Tests:** the concurrency suites run in both modes as parameters, in the
same way `--actors:` modes are covered. Until the default changes, every
emitted file under `examples/` is the stackful output and does not change.

## Risks

* **Debugging:** a stage fn's stack trace ends at `drive`, with no caller
  chain. A frame's `caller` links can be walked to print one on a panic,
  as stagelane's internals suggest.
* **Code size and compile time:** each stage is a fn. This is bounded by
  the complexity ceiling and measured per phase.
* **Ownership at frame boundaries:** a value moved into a frame field and
  dropped at frame free is new ground for the rules. Phase 2 pins it with
  run-gated leak checks.
* **Order:** spawn keeps enqueueing rather than running the task inline, so
  the interleavings stay today's. stagelane's `goInline` is faster, but it
  changes ordering, so it is out.
