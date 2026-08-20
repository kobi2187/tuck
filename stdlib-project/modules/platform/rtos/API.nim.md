# platform.rtos — Nim API

## Purpose
Tasks, queues, locks and repeating timers, spelled the same way whether a real kernel is underneath or the build is a bare-metal loop with no scheduler at all.

## Protocols implemented
`Task`: `Lifecycle` (`start`/`stop`/`isRunning`) + `Waitable` (`wait`). `Queue[T, N]`: `Messenger` (`send`/`receive`). `Ticker`: `Lifecycle`. `Semaphore` is `Waitable`.

## The API

```nim
type
  Priority* = enum Background, Normal, Urgent   ## three, not 56 — portable across kernels
  TaskBody* = proc (ctx: var TaskContext) {.nimcall, raises: [].}
    ## `nimcall`, so it is a plain function pointer: no closure, no capture, no heap.
    ## `raises: []` because there is nobody above a task to catch anything.

  Task* = object                                ## opaque; the kernel owns the innards
proc `=copy`*(dst: var Task, src: Task) {.error: "a task handle is unique — move it".}

proc newTask*(body: TaskBody, stack: var openArray[byte],
              priority = Normal, name: static string = ""): Task
  ## The stack is a caller-owned array sized at compile time. Nothing grows.
proc start*(t: var Task): bool
proc stop*(t: var Task): bool
proc isRunning*(t: Task): bool
proc wait*(t: Task, timeout: Duration): bool    ## true if it finished in time

proc sleepFor*(ctx: var TaskContext, d: Duration)
  ## Puts *this task* to sleep. platform.power's `enterSleep` puts the *whole chip*
  ## to sleep — the names differ because the things do.
proc yieldTurn*(ctx: var TaskContext)

type Queue*[T; N: static int] = object          ## fixed capacity, no allocator, ever
proc send*[T, N](q: var Queue[T, N], msg: T, timeout: Duration)
  ## Raises if still full when the timeout expires.
proc trySend*[T, N](q: var Queue[T, N], msg: T, timeout: Duration): bool
proc receive*[T, N](q: var Queue[T, N], timeout: Duration): Option[T]
  ## `none` on timeout — "nothing arrived" is an ordinary outcome.
proc count*[T, N](q: Queue[T, N]): int

type Semaphore* = object
proc wait*(s: var Semaphore, timeout: Duration): bool   ## take a permit; false = timed out
proc signal*(s: var Semaphore)                          ## hand one back

type Mutex*[T] = object                          ## priority-inheriting, no opt-out
template use*[T](m: var Mutex[T], timeout: Duration, name, body: untyped)
  ## `settings.use(50.ms, cfg): cfg.interval = 30.seconds` — the only way in, so
  ## "forgot to unlock" is not expressible. Raises on timeout; `tryUse` returns bool.

type Ticker* = object
proc every*(period: Duration, action: TaskBody): Ticker
  ## Repeating work with no task, no stack and no scheduler required — a bare-metal
  ## build implements this straight on a hardware timer.
proc stop*(t: var Ticker): bool

proc runOnIdle*(hook: proc (): WakeReason {.nimcall.})
  ## Registers what the kernel's idle task does instead of busy-waiting. The hook is
  ## expected to call platform.power's `enterSleep` itself and return what it got
  ## back; routing that `WakeReason` onto a `Queue` is the hook's business, not this
  ## module's. A bare-metal build never calls this and sleeps from its main loop.
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `spawn_task(cfg, entry)` | `newTask(...)` + `start(t)` | Splits construction from running, which is what makes `Task` an ordinary `Lifecycle` value like `sys.process`'s `Child`. |
| `TaskConfig { stack_size, priority, name }` | trailing named args | The config struct existed only to carry three options; PROTOCOLS already says options go last. |
| `task_sleep(ctx, d)` | `sleepFor(ctx, d)` | Keeps a visible gap between task sleep and chip sleep. |
| `task_yield` | `yieldTurn` | `yield` is a Nim keyword, and "turn" says what is being given up. |
| `Semaphore::acquire/release` | `wait` / `signal` | `wait(target, timeout): bool` is already in the table with exactly this shape — a semaphore is just something you wait on. |
| `Mutex::lock -> MutexGuard` | `use(m, timeout, v): ...` | Same shape as `alloc.allocator`'s `Secret.use`: nothing borrowed escapes the block, and there is no guard object to drop on the floor. |
| `PeriodicTimer::every` | `Ticker` + `every` | Names the object after the noise it makes; `every(30.seconds, sample)` reads as the sentence it is. |
| `run_on_idle` | `runOnIdle` | Kept — it is precisely descriptive and the boundary it marks is load-bearing. |

## In use — embedded-sensor-node / display-node

```nim
var samples: Queue[Reading, 8]
var uiStack {.align(8).}: array[1024, byte]

let ticker = every(30.seconds, proc (ctx: var TaskContext) {.nimcall.} =
  sensor.sample().ifSome(r): discard samples.trySend(r, timeout = 0.ms))

runOnIdle(proc (): WakeReason {.nimcall.} =
  power.enterSleep(Deep, [wakeOn(sampleTimer), wakeOn(encoderPin)]))

samples.receive(timeout = Forever).ifSome(r): display.show(r)   # event-driven half
```

## Vocabulary exceptions
`sleepFor`, `yieldTurn`, `signal`, `every` and `runOnIdle` are domain verbs — scheduling has no structural analogue, and forcing `every` into `start` would lose the period. `use` is borrowed deliberately from `alloc.allocator` rather than invented: one word for "reach inside this thing, but only in here."

## Honest limits
`PeriodicTimer` living in `rtos` rather than `power` or `interrupt` is a placement judgment, and `runOnIdle` sharpens the question — nearly its whole body is a `power` call. It stays here because posting the result onto a `Queue` is an `rtos` idea that `power` has no reason to know. Untested against a third app where several tasks each care about a different subset of wake sources; `runOnIdle`'s one-hook-one-`WakeReason` shape would strain there.

**Nim-specific:** every callback is `{.nimcall.}` — a bare function pointer. Nim's default `proc` type is a closure with a heap-allocated environment, which this tier forbids outright, so a task body genuinely cannot capture surrounding variables. State reaches a task through a `Queue`, a `Mutex[T]`, or a module-level `var`; there is no third option, and the annotation makes the compiler say so rather than the documentation.
