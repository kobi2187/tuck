# Savina ports

Real actor workloads, not invented ones. [Savina](https://github.com/shamsimam/savina)
is the actor benchmark suite from Imam & Sarkar (AGERE! 2014) — 32 benchmarks
across micro, concurrency and parallelism categories, used to compare Akka,
Scalaz, Habanero, Jetlang and others. Each port here names the file it came
from so it can be checked against the original rather than trusted.

Build one with any mode or backend:

```sh
./tuck b benches/savina/pingpong.tuck --actors:single --release -o:/tmp/pp
```

## What is ported

| Savina | file | what it stresses |
|---|---|---|
| PP (ping-pong) | `pingpong.tuck` | request/response latency, one message in flight |
| THR (thread ring) | `threadring.tuck` | actor-to-actor handoff down a chain |

## What the ports found

**The modes are not a tuning knob, they are the whole result.** Same program,
same machine, `--release`:

| | PP (40k round trips) | THR (ring of 6, 60k hops) |
|---|---|---|
| `--actors:single` | **11 ms** | **10 ms** |
| `--actors:thread` | 49–87 ms | 796–823 ms |
| `--actors:batch` | 1050 ms | 2450 ms |

`single` is **80x** faster than `thread` on the ring. Both benchmarks are
chains of one-message-at-a-time handoffs, so every hop in `thread` mode is a
cross-thread wake — a futex round trip, microseconds — where `single` mode
switches a coroutine in nanoseconds. This is the case `--actors:` was added
for, now measured on somebody else's benchmark instead of ours.

`batch` is worst, and predictably: with one message in flight a batch never
fills, so every message waits for a flush point. The mode is for throughput
under load and these two benchmarks are the opposite of that. Worth keeping
as the honest lower bound on what batching costs.

## What Tuck could not express

`threadring.tuck` is **not a faithful port and cannot be**. Savina builds its
ring with `Array.tabulate(N)`, where N is a runtime argument (default 100) and
each element is an actor created on the spot, handed its neighbour's address
in a message. Tuck has neither half: an actor is a declared compile-time
singleton, and there is no actor reference type, so there is no array to build
and no address to send. Generic actors do not help — `Ring[T]` expands to one
singleton per instantiation, so a ring of 100 needs 100 distinct type
arguments.

So the ring is fixed at 6 and written out by hand. The hop is still a real
cross-actor send, which is what the benchmark is for; what is lost is scaling
N, which is the axis Savina actually varies.

This is worth stating plainly because it rules out a whole class of the suite.
Anything that creates actors dynamically — `big`, `fjcreate`, `fjthrput`,
`sieve`, `banking`, `chameneos`, `philosopher` at its real N — is out of reach
in the same way. The Tuck answer is to use **tasks** for the parallel fan-out
and keep actors as singleton services in narrow roles, which is a different
program, not a port.

## Not ported yet

Ordered by what they would newly exercise:

- **bndbuffer** — producer/consumer over a bounded buffer. Directly tests
  `[queue: N]` and the drop-on-full policy (spec §9.1), which nothing here
  covers.
- **philosopher**, **barber**, **cigsmok** — classical coordination, and the
  best fit for singleton actors in narrow roles.
- **count** — counting actor; the closest thing in the suite to our own
  throughput bench, useful as a cross-check.
- **trapezoid**, **fib**, **recmatmul** — parallelism benchmarks, which in
  Tuck are task programs rather than actor programs.
