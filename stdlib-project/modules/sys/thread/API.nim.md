# sys.thread — Nim API

## Purpose
Start a real OS thread, get its answer back when it finishes, and find out how many cores you actually have. Everything about *sharing* state between those threads lives next door in `sys.sync`.

## Protocols implemented
`Worker[R]` is `Waitable` (`wait(w, timeout)`). Not `Lifecycle`: a thread can be started and joined, but "stop it" is not something any OS can safely offer, and pretending otherwise would be the worst kind of friendly.

## The API

```nim
type Worker*[R] = object
  ## A running thread plus the value its body will return. Must be waited on or
  ## explicitly `letGo`; a `Worker` that falls out of scope unwaited is reported by
  ## `core.error`'s contract checks in debug builds, not silently detached.

proc run*[A, R](body: proc (arg: A): R {.thread, nimcall.}; arg: sink A;
                name = ""; stack = 0): Worker[R]
  ## Start it. `name` shows up in a debugger and in `ps`; `stack = 0` means the OS default,
  ## and a fixed size is worth setting for a thread that must not grow at a bad moment.
proc tryRun*[A, R](body: proc (arg: A): R {.thread, nimcall.}; arg: sink A;
                   name = ""; stack = 0): Option[Worker[R]]

proc wait*[R](w: var Worker[R]; timeout = Forever): bool
  ## Waitable. True if the thread finished inside the deadline.
proc result*[R](w: var Worker[R]): R
  ## The body's return value. Waits first if it has to. Re-raises, on this thread, whatever
  ## the body raised — a failure on another stack is still an ordinary `Failure` here.
proc tryResult*[R](w: var Worker[R]): Option[R]
proc isDone*[R](w: Worker[R]): bool
proc letGo*[R](w: sink Worker[R])          ## deliberately never join. One word, easy to grep for

proc cpuCount*(): Option[int]
  ## Absent rather than a plausible-looking 1: a container CPU quota can make this genuinely
  ## unknowable, and a worker pool sized from a wrong guess is worse than one you sized yourself.
proc sleep*(d: Duration)                   ## takes a Duration, so `sleep(500)` cannot mean two things
proc yieldNow*()                           ## hand the rest of this slice to somebody else
proc currentName*(): TextView
```

**Nim notes, and they matter.**
Build with `--threads:on` (the default in Nim 2). A thread body is `{.thread, nimcall.}`, which means **it cannot be a closure and cannot capture local variables** — everything it needs arrives in `arg`. That is a real constraint, not a style rule, and it turns out to be a gift: the only way to share mutable state is to pass a `sys.sync` handle in `arg`, so the discipline the design wanted is enforced by the compiler rather than by review. The same pragma makes the body `{.gcsafe.}`-checked: touching a global `seq`/`string`/`ref` from a thread is a compile error unless it is guarded. Under `--mm:arc` there is no stop-the-world collector at all, which is what lets `mp3-player`'s audio thread exist; under `--mm:orc` the cycle collector is per-thread, so one thread's cleanup never pauses another's. Thread-local storage needs no type from this module — Nim spells it `var counter {.threadvar.}: int`.

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `spawn(f)` / `Builder::spawn` | `run(body, arg, name =, stack =)` | one call. The builder existed only to name the thread and size its stack |
| `JoinHandle<T>` | `Worker[R]` | names the thing doing the work, not the operation you'll eventually perform on it |
| `join()` → `Result<T, ThreadPanic>` | `wait` + `result` | `wait` is `Waitable`'s verb and answers "in time?"; `result` answers "what did it say?" and re-raises |
| `is_finished` | `isDone` | shorter, same word shape as `isOpen`/`isRunning` |
| `detach()` | `letGo()` | plain English, and stands out at a call site the way an abandoned thread should |
| `available_parallelism() -> Result` | `cpuCount(): Option[int]` | it isn't a failure, it's genuinely unknown — that's what `Option` is for |
| `yield_now` | `yieldNow` | camelCase, otherwise unchanged |
| `LocalKey<T>` / `thread_local!` | *(gone)* — `{.threadvar.}` | Nim has it in the language; a library type would be pure ceremony |
| `Duration` in `sleep` | unchanged | the one idiom for "how long", from `sys.time` |

## In use

```nim
# log-grep: fork out over the chunks, join, add up. The classic shape, and the typed
# return value means no shared, locked results structure at all.
var workers = newList[Worker[int]](capacity = jobs)
for chunk in file.chunks(jobs):
  workers.add(run(scanChunk, chunk, name = "grep"))     # chunk is passed, never captured

var hits = 0
for w in workers.list():
  discard w.wait()
  hits += w.result()                                     # re-raises here if the chunk blew up

# mp3-player: one thread that must not be surprised by anything
let audio = run(playbackLoop, fromUi, name = "audio", stack = 256 * KiB)
```

## Vocabulary exceptions
- **`run` is a domain verb.** `start` belongs to `Lifecycle`, which promises a matching `stop`; a thread has no honest `stop`, so borrowing `start` would advertise something the OS cannot deliver. `run` says "go, once."
- **`result` is a noun used as an accessor**, matching Nim's own use of the word, rather than `get(w)` — there is no locator, and `get` without a key would be the odd one out across the library.
- **`letGo` has no `try` sibling** because it cannot fail; it just declines to wait.
