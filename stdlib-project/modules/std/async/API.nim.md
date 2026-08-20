# std.async — Nim API

## Purpose
Run many things at once without any of them escaping. A `Scope` is the one thing you pass down a call chain: it carries "should I stop yet?", "how long do I have?", and any request-scoped values — and it refuses to return until every task started under it has finished.

## Protocols implemented
`Scope` is `Lifecycle` (`stop`/`isRunning`), `Waitable` (`wait`), `Gettable` and `Settable` (its named values). `Task[T]` is `Waitable` and `Lifecycle`, per PROTOCOLS' assignment table. Four of the nine protocols land on one type with no new verbs — cancellation *is* `stop`, and "has it finished?" *is* `wait`.

## The API

```nim
type
  Scope* = ref object
    ## Cancellation + deadline + named values + the join boundary, in one noun.
    ## The Rust design's `Context` and `Scope` are merged: they always travelled
    ## together (`scope(&ctx, ..)`, `spawn(|ctx| ..)`), so one word is honest.
  Task*[T] = object       ## a handle on work running under some Scope
  TaskLock*[T] = object   ## a lock that suspends the *task*, never the worker thread
  Stopped* = enum Cancelled, DeadlineMissed

template withScope*(parent: Scope = rootScope(), deadline = none(Duration),
                    body: untyped)
  ## The structured-concurrency block. `body` gets a fresh child `Scope` named `it`.
  ## Cannot return until every task spawned inside has finished or been stopped —
  ## normal exit, `return`, and a raised `Failure` all join first.

proc rootScope*(): Scope                         ## the program's outermost scope
proc spawn*[T](s: Scope; work: proc (s: Scope): T): Task[T]
proc stop*(s: Scope): bool {.discardable.}       ## Lifecycle: cancel this scope and everything under it
proc isRunning*(s: Scope): bool
proc wait*(s: Scope; timeout = foreverDuration): bool  ## Waitable: has it wound down?
proc why*(s: Scope): Option[Stopped]             ## none while still running
proc get*[T](s: Scope; key: static string): Option[T]   ## Gettable — static key, so typos don't compile
proc set*[T](s: Scope; key: static string; value: T)    ## Settable

proc wait*[T](t: Task[T]; timeout = foreverDuration): bool
proc stop*[T](t: Task[T]): bool {.discardable.}
proc outcome*[T](t: Task[T]): T
  ## Blocks, then hands back the value — or re-raises whatever the task raised.
proc tryOutcome*[T](t: Task[T]): Option[T]       ## none if it failed or was stopped

proc waitAny*(cases: openArray[Waitable]; timeout = foreverDuration): Option[Index]
  ## Nim has no `select` keyword and std.async is a library, so this is a plain
  ## proc over a case list: the index of whichever became ready first.

proc newTaskLock*[T](value: sink T): TaskLock[T]
template use*[T](lock: TaskLock[T]; s: Scope; body: untyped)
  ## `body` gets the guarded value as `it`. Same word `alloc.string`'s `Secret[T]`
  ## uses, and the same guarantee: the thing never escapes the block.
proc workerCount*(): Count   ## OS threads backing every task; defaults to core count
```

**Executor.** `spawn` runs on a **bounded M:N work-stealing pool** — `workerCount()` OS threads, arbitrarily many lightweight tasks — decided by `load-tester`'s `-c 200` and not revisited here. The corollary is a hard rule: **any lock held across a suspension point, or contended under load, must be a `TaskLock`.** A plain `sys.sync.Lock` parks a whole worker and stalls every unrelated task queued on it.

**Nim's own async.** A spawned body may be an ordinary `{.async.}` proc and may `await` inside; `Task[T]` wraps a `Future[T]`. What this module adds over `std/asyncdispatch` is the multi-threaded work-stealing pool (Nim's default dispatcher is one thread), scope ownership so nothing outlives its block, and `TaskLock`. `Scope` is threaded explicitly rather than kept in a thread-local, because a work-stealing task does not stay on one thread.

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `Context` + `Scope` | `Scope` | Two nouns that never travelled apart. One word, and it picks up four protocols for free. |
| `with_cancel` / `CancelFn` | `stop(scope)` | Cancellation is a lifecycle event, and `stop` is already the word for one. No closure to hold onto. |
| `ctx.done()` / `ctx.err()` | `wait(scope)` / `why(scope)` | `Waitable` covers "tell me when"; `why` covers "and what happened". |
| `TaskHandle::join` | `outcome(task)` | "Join" is thread jargon. `outcome` says what you get, and the `try` sibling says what happens if it went wrong. |
| `select(cases)` | `waitAny(cases)` | Built from the vocabulary's own `wait`, so its return (an index) is guessable. |
| `AsyncMutex` / `MutexGuard` | `TaskLock` / `use` | Names *who* gets suspended — the task, not the thread — which is the entire reason it exists. The guard type vanishes into a block. |
| `Executor::worker_count` | `workerCount()` | One free proc; there was never an executor object worth handing out. |

## In use

```nim
# load-tester: 200 in-flight request tasks, one graceful stop, pooled connections
withScope(deadline = some(runFor)):
  for worker in 1 .. concurrency:
    it.spawn proc (s: Scope): Latencies =
      while s.isRunning():
        pool.use(s):                       # TaskLock — a plain lock would park a worker
          it.borrow(host)
        result.add(client.fetch(target, scope = s).elapsed)
  it.spawn(reportEvery(1.seconds))          # low-frequency, off the per-request path
onCtrlC: rootScope().stop()                 # sys.signal trips it; every task drains
```

## Vocabulary exceptions
`spawn`, `use`, `why`, and `outcome` are domain verbs; the structural table has nothing to say about starting concurrent work. `withScope` is a template rather than a proc because the join-before-return guarantee has to be tied to a block, which Nim expresses with `template`, not a callback parameter.

**Broadcast, checked (PROTOCOLS "Honest gaps").** `Messenger` genuinely does not cover one-to-many delivery — that part of the prediction holds. But neither cited example needs it. A scope's cancellation reaching every task at once is **`Waitable`**, not messaging: many tasks `wait`, one `stop` releases them all, and a task that arrives late still sees a stopped scope. `load-tester`'s connection pool is not messaging either — it is `open`/`close` on a `Resource` (see `std.net-http`). No `std` module demands `publish`/`subscribe`, so per PROTOCOLS rule 6 no `Broadcaster` protocol is added here.
