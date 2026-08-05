# Async endgame: what the measurements say

Spikes run 2026-08-05, against the Phase 1/2 offload seam. Numbers from
`benches/bench_offload.nim` plus two throwaway spikes (pool comparison, arena
comparison). Machine: this dev box, clang, `--threads:on`, `--opt:none` except
the arena row which is `-d:release`.

## 1. A thread pool does NOT escape linear. It buys a constant.

100ms of blocking work per task, N tasks concurrently:

| n | 1 worker | pool(4) | pool(8) | reactor-only |
|---|---|---|---|---|
| 1 | 100ms | 100ms | 100ms | 100ms |
| 2 | 201ms | 101ms | 101ms | 101ms |
| 4 | 401ms | 101ms | 101ms | 101ms |
| 8 | 802ms | 201ms | 101ms | 101ms |
| 16 | 1605ms | 402ms | 201ms | **118ms** |

A pool of K caps at exactly K× and then goes linear again. pool(4) is 4× at
n=16; pool(8) is 8×. **The ceiling is always the thread count** — a pool never
becomes asynchronous, it just moves the slope.

The reactor column is a different asymptotic class: 16 concurrent operations in
118ms, on ONE thread, no pool. That is what "real async" means here.

**Conclusion:** the pool is a fallback for operations that genuinely cannot be
awaited, not the destination. Building a large pool would be buying a constant
factor at the cost of threads, a queue, and (when the runtime is ported to
Tuck) atomics plus a memory model.

## 2. Which operations can actually reach the reactor?

This is the real fork, and it is not "files vs sockets" — it is finer:

| operation | awaitable? | why |
|---|---|---|
| socket recv/send/accept | **yes** | epoll/kqueue readiness is exactly this |
| pipe, tty, stdin | **yes** | character devices have readiness |
| timers | **yes** | timerfd; already done (`tuckSleep`) |
| regular file read/write | **no** | always reports "ready"; readiness is meaningless |
| open/stat/unlink (metadata) | **no** | no fd exists yet to await |
| DNS resolution | **no** | getaddrinfo blocks in libc |

So the pool's permanent job is: **regular files, path metadata, and DNS.**
Everything else should reach the reactor and should never touch a thread.

Note `readLine` on stdin is in the awaitable column — it is currently on the
worker (Phase 1) because that removed the hang immediately, but stdin has real
readiness and should move to `tuckAwaitRead` + a non-blocking read. That is a
strictly better implementation of the same extern.

## 3. The malloc in the read path is irrelevant. Do NOT arena it.

2000 allocations per row, `-d:release`:

| size | malloc+free | arena bump | copy to Nim string |
|---|---|---|---|
| 4KB | 0.06us | 0.00us | 0.29us |
| 64KB | 0.06us | 0.00us | 3.26us |
| 1MB | 0.03us | 0.00us | 32.37us |

For scale: **one 100ms blocking read is 100,000us.**

The malloc is 0.00006% of the operation it accompanies. An arena would remove
0.06us and add a lifetime discipline (when to reset, what happens when a
request outlives the reset, how two concurrent requests share the region).

More importantly: **the copy costs 50-1000x the malloc**, and an arena does not
remove the copy — the result still has to become a GC'd Nim string on the
scheduler thread. Arena-ing the allocation optimises the wrong term.

**If the copy ever matters** (it does not yet: 32us against 100,000us), the fix
is to have the worker read directly into a caller-provided buffer that is
already the final string's memory, not to change the allocator. That is a
bigger change and needs a reason.

## 4. The user-facing gap

The only awaitable source a Tuck program can name today is `openSource`
(`examples/29-task-timeout.tuck:9`, `30-async-read.tuck:9`) — a DEMO pipe that
writes one byte after N ms. There is no socket type, no `connect`, no `recv`.

So `on select | read fd | timeout` works, and works correctly, against a
fixture. The mechanism is real and proven; there is nothing real to point it
at. That is the actual blocker for the async story, and it is a std-library
gap, not a runtime gap.

## Recommended order (revised by these numbers)

1. **A socket extern in std** — `listen`/`accept`/`recv`/`send` returning fds,
   awaited through the existing `tuckAwaitRead`. This is where the flat line in
   the table above comes from, and it needs no new runtime machinery.
2. **Move `readLine` to the reactor** — stdin has readiness; the worker was the
   expedient fix, not the right one.
3. **Keep the single worker** for files/metadata/DNS. At n=4 concurrent file
   reads it costs 300ms over ideal; a pool would need a benchmark showing a
   real program does that, and none does today.
4. **A pool only if measured**, and sized to cores, understanding it buys K.
5. **Never an arena for the read buffer.** The numbers are above.
