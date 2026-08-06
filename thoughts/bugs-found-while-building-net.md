# Bugs and rough edges found while building std/net

Recorded as they were hit, per standing instruction: finding these is the
point of building real features on the framework.

Status key: **OPEN** = still reproduces, **FIXED** = fixed in this work,
**UPSTREAM** = not ours.

---

## 1. FIXED — `scheduler::stop` did not exist

`EventLoop.run()` exits only when `waiters.len == 0`. One coroutine parked on
an fd that never becomes readable keeps the process alive forever, spinning
`epoll_wait` on an empty set. A server's accept loop is exactly that shape.

`EventLoop.stop()` existed (`tuck_coro.nim:904`) but `tuck_async` never
re-exported it, so no Tuck program could reach it. The Odin backend had
`tuckStop` all along — a silent backend asymmetry.

Fixed: `tuckStop` in `tuck_async`, `stop` extern in `std/scheduler.tuck`, and
both run loops now check `stopped` AFTER draining the ready queue so the exit
is immediate rather than up to 100ms later. Regression test in
`end_to_end.sh` — note a regression there HANGS the suite rather than failing
it.

## 2. FIXED — `EventLoop.run` parked before draining

`run()` called `runOnce(100)` before draining the ready queue, so a coroutine
that was already runnable waited out the epoll timeout. Measured as a constant
~100ms on top of *every* blocking call regardless of how many were queued
(401/701/1302ms for 1/2/4 offloads; 301/601/1201ms after).

The Odin `tuckRun` always had the correct order — another silent asymmetry
where one backend was right and the other was not.

## 3. FIXED (2026-08-05) — a `void` task cannot be fire-and-forget

```tuck
task serve({lfd: int}) -> void [io]:
  ...
fn main() -> int [io]:
  {lfd: 3} serve      # not bound => fire-and-forget
```

emits `discard tuck_serve(...)` for a proc returning `void`:

```
Error: expression 'tuck_serve(l.value.fd)' has no type (or is ambiguous)
```

Fixed: the spawn wrapper emits `discard` only when there is something to
discard (`ctx.taskRetType(callee) != "void"`). 42-net-echo dropped the
`{n: int}` return it never wanted. Regression test in known_bugs.

## 4. OPEN (design, worth documenting) — binding a task result awaits it

Not a bug, but it cost a debugging cycle and will cost users one. In:

```tuck
let sv = {lfd: l.value.fd} serve     # server task
let cl = {port: 34591} client        # client task
```

the first line schedules AND awaits, so the client never starts and the program
deadlocks: the server is parked on `accept` waiting for a client that cannot
run. `strace` showed `listen` then `epoll_wait` forever with no `connect`.

This is spec §9.2 working as designed ("binding its result awaits completion"),
but the failure mode is a silent hang. Two things would help: a note in the
task docs, and — if it can be detected — a checker warning when a task result
is bound and never read before another task that could satisfy it.

## 5. PARTLY FIXED — the Odin backend never spawned tasks at all

`tuckSpawn` appeared **only** in `codegen.nim`. Odin emitted a task call as a
direct call, so the body ran on the main context and the first `tuckAwaitRead`
inside it hit:

```
tuck_coro.odin(282:3) panic: tuck: cannot await outside a coroutine
```

Nim emits `tuckSpawn(proc() = discard tuck_serve(...))` for the same source.

It went unnoticed because `28-async-task` — the only Odin task example — never
awaits an fd, only `tuckYield`, which is legal outside a coroutine. Real I/O in
a task is what exposed it.

Fixed for NULLARY tasks (`isTaskName` + `rt.tuckSpawn`). **Still open for tasks
with arguments**: Odin proc literals cannot capture — verified with a two-line
program, `Error: Undeclared name: x` for a literal referencing an outer local —
so the arguments must be marshalled through a heap context the thunk owns and
frees. That is a design task, not a one-liner, so a task with arguments still
emits a direct call and is wrong the moment it awaits.

## 6. UPSTREAM (Odin dev-2026-07) — `linux.getsockopt` group does not instantiate

`core/sys/linux/sys.odin:751`, inside `getsockopt_sock`:

```odin
return getsockopt_base(sock, cast(int) level, cast(int) opt, val)
```

but `getsockopt_base` (`:735`) declares `opt: Socket_Option`. So:

```
Error: Cannot assign value 'opt' of type 'int' to 'Socket_Option'
```

The error surfaces inside Odin's own stdlib, not in calling code, which makes
it confusing. Worked around by calling `getsockopt_base` directly. Revisit when
Odin updates.

## 7. NOTED — `--threads:on` widens `system`'s namespace

`system.running(Thread)` beats `tuck_coro.running()` in overload resolution,
producing a type error far from the cause. Added `inCoroutine()` so no caller
writes the ambiguous form. Expect more of these as the runtime grows: the flag
flip changes what `system` exports.

## 8. NOTED — `Mailbox.lock` was dead, now is not

`tuck_rt.nim:170` carries a `Lock` with the comment "sends come from other
threads". Under the old `--threads:off` it compiled to nothing. Now that
programs build with `--threads:on` it is real, uncontended cost on every
message. Sends still only happen on the scheduler thread, so it protects
nothing — decide whether to keep it (for a future real pool) or delete it.

---

## Test-gate gaps found (same class, worth naming)

- `27-actor-select` was absent from `odin_backend.sh`, which is why an Odin
  actor emitting undefined send procs survived. Now compile- AND run-gated.
- `24-stdlib` was compile-only, so the fs offload never actually executed on
  Odin. Now run-gated.
- `readLine` had **zero** call sites anywhere, which is why its blocking
  behaviour went unnoticed until the offload work.

The pattern: a gate list enumerates what is checked, so everything off the list
is unchecked. Adding a feature means adding it to the list.
