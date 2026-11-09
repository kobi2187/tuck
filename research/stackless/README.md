# Stackless spike (#216)

Before building the transform, this spike checks whether the stackless form is
worth it, using code shaped exactly like the transform's output. It is not
wired into the compiler. The design it feeds is
[`docs/stackless-concurrency.md`](../../docs/stackless-concurrency.md).

| file | what |
|---|---|
| `sl_rt.nim` | a minimal stackless runtime: `FrameHdr`, `Hop`, `drive`, a ready FIFO, a per-type frame freelist, yield, result slots and awaiting from `main` |
| `bench_stackless.nim` | `b_await.tuck`, `b_chain.tuck` and `benches/bench_async_scale.nim`, lowered **by hand** into frames and stages, one section per program with the Tuck source above it |
| `b_await.tuck`, `b_chain.tuck` | the same programs as real Tuck, built with today's compiler (minicoro) as the baseline |
| `run.sh` | builds both sides with the release flags `tuck b --release` uses and prints them |

## Results (2026-11-09, 4-core cloud VM, clang, `--mm:none`, LTO; medians of 3)

| workload | stackful today | stackless (hand-lowered) | ratio |
|---|---|---|---|
| spawn + await a task with 2 `[io]` calls (`b_await`, 1M) | 4.8 s (~4.8 µs/task) | 10–20 ms (~10–20 ns/task) | ~300x |
| `[io]` call through a fn between task and leaf, with a yield (`b_chain`, 10M) | 530 ms (53 ns/iter) | 43–70 ms (4–7 ns/iter) | ~10x |
| spawn (10k tasks) | 3.7 µs/task | 30 ns/task | ~120x |
| task switch (10k tasks x 100 yields) | 230 ns | 3 ns | ~70x |
| memory per live task | 256 KB of reserved stack | `sizeof(frame)`: 48 bytes for `compute` | — |

### Read these numbers honestly

* **The spike's runtime is smaller than the real one.** It has no reactor, no
  timers and no offload pipe. Today's runtime also spends little time there
  in these workloads, since none of them touches an fd, but a real stackless
  runtime adds a reactor poll whenever the ready queue runs dry. Expect the
  ratios to shrink. Even a 10x loss would leave stackless ahead on every row.
* **Code is lowered by hand.** It follows the rules listed at the top of
  `bench_stackless.nim` faithfully, but a compiler pass may emit somewhat
  worse code: extra frame fields, fewer direct stage entries.
* **The ordering is the same as today.** Spawning enqueues the task and does
  not run it inline, so every yield point is where today's
  `(tuckYield(); call)` puts it. Running the task inline up to its first
  pause (stagelane's `goInline`) would be faster still, but it changes
  ordering, so it was left out.

## What the spike settled

1. **The `Hop` trampoline costs nothing measurable.** A stage returns
   `(fn, env)` in two registers, and `drive` is a three-instruction loop.
2. **Entering a callee directly** (`return midS0(c)`), and taking a loop's
   back edge as a direct call (`chainHead(env)`), keeps the common path out
   of the driver. Only a real pause or a return goes through `drive`.
3. **A per-type freelist makes spawn about 30 ns**, with or without reuse.
   The allocator is not the cost.
4. **Everything is plain structs, `nimcall` fn pointers and casts.** There
   are no closures and no GC, so Odin and D can express the same code line
   for line. Phase 3 of the design verifies that on their toolchains.
