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

## 5. Verified against real TCP

The socket spike (throwaway, `scratchpad/spike/sock.nim`) built
listen/accept/connect/recv/send on raw non-blocking posix sockets, awaited
purely through the EXISTING `tuckAwaitRead`/`tuckAwaitWrite`. No runtime
changes were needed at all.

Echo server, 100ms of simulated work per request, one thread:

| clients | wall | serial would be | replies |
|---|---|---|---|
| 1 | 101ms | 100ms | 1/1 correct |
| 2 | 101ms | 200ms | 2/2 correct |
| 4 | 102ms | 400ms | 4/4 correct |
| 8 | 103ms | 800ms | 8/8 correct |
| 16 | 105ms | 1600ms | 16/16 correct |
| 32 | 108ms | 3200ms | 32/32 correct |

Flat to 32 connections. This is the prediction in §1 confirmed on real sockets
rather than on `openSource`: the reactor path is asymptotically better, and a
socket module needs no new machinery — only externs.

### Two things the spike exposed

**A leaked waiter hangs the program, silently.** `run()` exits on
`waiters.len == 0`. One coroutine parked on an fd that will never become
readable keeps the process alive forever, spinning `epoll_wait` on an empty
set. A server's accept loop is exactly this shape, so a real server needs a
shutdown path.

`EventLoop.stop()` exists (`tuck_coro.nim:904`) but is NOT re-exported by
`tuck_async`, so nothing in Tuck can reach it. The Odin side already has
`tuckStop` (`tuck_coro.odin`). Closing that asymmetry is a prerequisite for a
socket module, not an optional extra.

**Debugging note.** The hang was diagnosed by `strace -e epoll_ctl,epoll_wait`
plus a temporary trace in `runOnce`, after three wrong hypotheses from reading
code (double registration, accept-loop overrun, coroutine-id reuse via a
recycled heap address). The trace showed `sendto(8, ...) = -1 EBADF` and a
`waiters=@[5]` that never cleared, which named the real cause — a closure
capturing the loop's `let` by reference, so every handler saw the last accepted
fd. Instrument before theorising.

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
