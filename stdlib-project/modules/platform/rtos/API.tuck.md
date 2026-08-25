# platform.rtos — Tuck translation

## Largely absorbed: Tuck *is* the scheduler.

`platform.rtos` exists to spell "tasks, queues, locks and repeating timers
the same way whether a real kernel is underneath or the build is a bare
metal loop." Tuck supplies the first three directly:

| Nim design | Tuck |
|---|---|
| task | `task` — a coroutine; `[io]` calls are yield points |
| queue | an `actor`'s `[queue: N]` mailbox |
| lock | not needed — cooperative scheduling, no preemption between yields |
| repeating timer | `on select | timer.1s -> {}:` (spec §9.1's own example) |

`examples/16-actor-tasks-unified-syntax.tuck` shows the timer arm inside an
actor's `on select`, which is exactly the "repeating timer" this module
would otherwise provide.

## What remains genuinely RTOS-specific

```tuck
pending:
  fn taskPriority({id: int}) -> u8
  fn setTaskPriority({id: int, priority: u8}) -> void
  fn stackHighWater({id: int}) -> int
  fn kernelTicks() -> u64
```

Priorities and stack-watermarking are real RTOS concerns Tuck's cooperative
scheduler has no equivalent for — and **priority is the interesting one**:
a cooperative scheduler cannot preempt a long-running task for a
higher-priority one, which is precisely what a hard-real-time system needs.

## The honest limitation
`LANGUAGE-OVERVIEW.md` §0 already says it: *"Concurrency targets
microcontrollers — **hosted OS today**, stackful minicoro coroutines over
`mmap`, epoll/kqueue reactor. Tier 3, not Tier 1."*

So this module currently describes a target the runtime does not serve. The
`platform` tier's other modules (`hal`, `register`, `pool`, `boot`) are
freestanding-ready; the *concurrency* story is not. That gap is the single
biggest thing standing between this corpus and a real embedded target, and
it is a runtime question rather than a stdlib one.
