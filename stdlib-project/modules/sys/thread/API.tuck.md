# sys.thread — Tuck translation

## This module does not translate, and that is the finding.

`sys.thread` is *"start a real OS thread, get its answer back when it
finishes, and find out how many cores you actually have."* Tuck's
concurrency model has no user-facing OS threads at all:

> **stackful coroutines on one cooperative scheduler, plus an epoll/kqueue
> reactor.** No preemption, **no OS threads in the scheduler.**

There is exactly **one** other thread in a Tuck program, and it isn't
yours: a *single offload worker* that runs blocking externs (`readFile`,
`readLine` — files can't be epolled, since a regular file is always
"ready") and parks the calling coroutine on a completion pipe the reactor
already watches. It is runtime machinery, not an API.

So "start a thread" has no spelling, and shouldn't get one: the whole
Tier-1 safety argument (no `ref`, messages copied across actor boundaries,
"a data race needs two references to one mutable location; the sentence
cannot be formed") depends on there being no second thread touching your
values.

## What replaces it

| want | Tuck |
|---|---|
| concurrent work | `task` — spawned on the scheduler, `[io]` calls are yield points |
| long-lived isolated state | `actor` — a singleton with a mailbox |
| don't block the loop on a file | already automatic: blocking externs offload |
| structured "start N, join all" | `std.async`'s `Scope` |

Measured, from the same section: 300ms of blocking work beside a 10ms
ticker gives 1 tick on-thread and 30 offloaded; 32 concurrent socket
connections complete in 108ms where serial would be 3200ms.

## What is genuinely lost, and worth naming

**CPU parallelism.** One cooperative scheduler on one thread means a
compute-bound workload cannot use more than one core. `std.async`'s Tuck
translation will hit this too — the Nim design settled on "a bounded M:N
work-stealing pool, N OS worker threads roughly matching core count"
(round-3's decision, forced by `load-tester`), and that model does not
exist here.

That is a real difference in what the library can promise, not a
translation detail:
- I/O-bound concurrency: **fully served** (reactor + offload).
- CPU-bound parallelism: **not served**, and no module in this corpus can
  paper over it.

`cpuCount()` therefore has no useful meaning either — nothing in the
language can spend more than one core.

## Recommendation
Drop `sys.thread` as a module. Carry the CPU-parallelism limitation into
`std.async`'s translation, where round-3's executor decision has to be
revisited against a single-threaded scheduler.
