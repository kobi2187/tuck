# Benchmark scores

Speed ledger for spotting major regressions. Not a pass/fail gate. Re-run with
`bash benches/run.sh`; compare against the baseline below. Numbers are
machine-specific (Linux, this box) — what matters is the ratio to baseline, not
the absolute figure. A >2x slowdown on any line is worth investigating.

## Baseline — 2026-07-24 (commit c67ffe1 + arsenal 353546d)

| Bench | Metric | Score |
|---|---|---|
| async runtime scale | coroutine spawn | 0.25 M coros/sec |
| async runtime scale | context switch | 1.67 M switches/sec |
| actor throughput | messages drained | ~21 M msgs/sec |
| compiler front-end | lex+parse+check | ~23k lines/sec |

## D runtime joins — 2026-08-29

Third backend on the same vendored minicoro. Same bench, same N=10000 K=100,
`-O -release -inline`. The spawn figure is the one that matters for the
portability claim: it is dominated by minicoro's stack allocation, so all
three agreeing at ~0.18–0.19 M/sec is evidence the shared engine really is
doing the work rather than each backend having its own.

| Bench | Metric | Nim | Odin | D |
|---|---|---|---|---|
| async scale | coroutine spawn | 0.18 M/sec | 0.18 M/sec | 0.19 M/sec |
| async scale | context switch | 1.27–1.33 M/sec | 1.94–2.09 M/sec | 3.48–3.55 M/sec |

The switch figure is HIGHER than both, and it is not claimed as a win: the
Nim and Odin rows were measured 2026-07-28 on a different machine state, so
only the D row is same-session. What it does establish is the absence of a
large gap in the wrong direction, which is what a porting bug would look
like. Re-run all three interleaved before treating the ordering as real.

### 2026-09-01 — re-run interleaved, same session: the D switch lead is real

Built and ran all three fresh, back to back, same box, same N=10000 K=100:

| Bench | Metric | Nim | Odin | D |
|---|---|---|---|---|
| async scale | coroutine spawn | 0.19–0.22 M/sec | 0.23–0.24 M/sec | 0.16–0.24 M/sec |
| async scale | context switch | 2.41–2.43 M/sec | 2.87–2.97 M/sec | 3.30–3.54 M/sec |

Spawn agrees within noise (shared minicoro stack alloc, same C on all three —
the portability check this bench exists for). Switch does not: D beats Odin
by ~20%, Nim by ~45%, consistently across three runs each. Found by reading
each scheduler's hot path, not guessing:

- **Nim pays ARC refcounts.** The readyQueue is `Deque[Coroutine]` with
  `Coroutine = ref CoroutineObj` — every `addLast`/`popFirst` bumps a
  refcount. Already identified 2026-07-28 below ("1.55x the cost of a
  pointer deque"); this just reconfirms it under a fresh build.
- **Odin pays a map lookup this workload never needs.** `runNext`'s
  post-resume line is `if !isFinished(coro) && !coro_parked(coro) { queue.push_back(...) }`,
  and `coro_parked` does `gLoop.inited && (rawptr(c) in gLoop.parked)` — a
  hash-map probe on EVERY switch. `tuckAsyncInit` calls `initLoop()`
  unconditionally, so `gLoop.inited` is always true and a pure-`tuckYield`
  program (no I/O, no timers, no `on select`) pays a lookup into a
  permanently empty map on every single context switch. This is real,
  general overhead, not specific to select/await use — every Odin program
  pays it.
- **D pays neither.** The ready queue is a raw malloc'd `Coroutine*` ring
  (no GC, so no refcounting — same reason the ready queue can't be GC
  memory at all: a coroutine's own stack isn't scanned). `tuckYield`
  explicitly re-schedules itself before suspending, so nothing needs to ask
  "was this one parked?" after a resume — unlike Odin's generic `runNext`,
  which has to serve both the plain-yield path and the reactor-parked path
  through one function and uses the map check to tell them apart.

Not a bug on Odin's side — its design trades a small per-switch cost for a
single, uniform requeue path that also handles I/O parking. D's ring buffer
is faster here only because plain yielding and I/O parking are two separate
call sites that each already know which case they're in, so nothing needs
checking after the fact.

**This bench earned its keep immediately.** At the default N=10000 the first
D run SEGFAULTED where Nim and Odin are fine. gdb put it in the GC:
appending to the GC-allocated run queue from inside a coroutine triggered a
collection, and D's conservative GC then scanned a minicoro stack it had
never been told about (0xdeaddeaddeaddead frame). The queue is now
hand-managed malloc memory. The smaller tests — two coroutines interleaving
— never allocated enough to trip it.

## Nim vs Odin runtime — 2026-07-28

Both backends drive the SAME vendored minicoro, so this is not a language
shootout: it checks that the Odin port carries the engine's characteristics
across. Interleaved runs, same machine state, `-d:release` / `-o:speed`.

| Bench | Metric | Nim | Odin |
|---|---|---|---|
| async scale | coroutine spawn | 0.18 M/sec | 0.18 M/sec |
| async scale | context switch | 1.27–1.33 M/sec | **1.94–2.09 M/sec** |
| actor throughput | messages drained | ~24.7 M/sec | **~64–106 M/sec** |
| build (23-units) | compile time | 783 ms | **145 ms** |
| build (23-units) | binary size | 64.4 KB | **45.7 KB** |

**Spawn matching to two decimals is the validation.** It is dominated by
minicoro's stack allocation — shared C on both sides — so identical numbers
say the port is faithful. Every other line is where the languages differ.

Context switch is ~55% faster on Odin, consistently across interleaved runs.
The plausible cause is what the port removed rather than anything it added:
no GC write barriers, no ARC, and no stack-walker constraint (tuck_async.nim
must build `--stackTrace:off --lineTrace:off` or Nim's walker corrupts the
switched stack; Odin has no analogue). Not profiled, so treat the *cause* as
a hypothesis and the *number* as measured.

Actor throughput is 3–4x, with one caveat worth stating: the first draft of
the Odin bench notified once per ring-full BATCH while the Nim bench notifies
per message, which reported a flattering 347 M/sec. Matching the workload
(one `tuckNotifySend` per send) brought it to ~64–106 M/sec. The remaining
shape difference is real and unavoidable: Nim's bench mailbox is a growable
`seq[int]`, Odin's is the runtime's fixed-capacity ring — which is what
codegen actually emits for an actor, so the Odin figure reflects the emitted
path while the Nim one reflects a hand-written stand-in.

Odin benches live in `benches/odin_async_scale/` and
`benches/odin_actor_throughput/`; build with `odin build <dir> -o:speed`.

### 2026-07-28 — Nim coroutine wrapper: 13.1 → 23.5 M switches/sec

Reading the GENERATED C found it, after six wrong guesses (ORC vs ARC,
try/finally, exceptions, a 72-byte by-value copy, refcounted deques — each
measured, each worth ~1%). `coroYield`'s five lines compiled to a call to
`eqcopy` plus an `nimErrorFlag()` fetch and a branch after every statement,
twice per switch:

    eqcopy___...(&c_1, activeCoroutine, NIM_FALSE);
    if (NIM_UNLIKELY((*nimErr_))) { goto LA1_; }

Two fixes, isolated by measuring one at a time:

| change | raw switch |
|---|---|
| baseline | 13.1 M/sec |
| `{.raises: [].}` + trap instead of raise | 18.9 M/sec |
| `activeCoroutine` as `ptr` instead of `ref` | **23.5 M/sec** |

The second is what removed the `eqcopy` call — the C is now a plain load.
It is safe because activeCoroutine is a VIEW, never an owner: a running
coroutine is kept alive by `resume`'s own ref parameter and by the
scheduler's readyQueue. Verified under ASan (`--mm:orc -d:useMalloc
-fsanitize=address`): no use-after-free, no leaks.

Full-path async scale moved only 1.32 → 1.49 M/sec, because the scheduler
dominates there — `Deque[Coroutine]` refcounts on every push/pop, measured
at 1.55x the cost of a pointer deque. Actor throughput was unchanged
(~23 M msgs/sec), same reason. Odin still leads on the full path (2.10),
which is consistent with it emitting LLVM IR directly rather than going
through C.

### 2026-07-24 — coroutine stack 256KB → 128KB

First cut: halved the per-coroutine stack 256KB→128KB. 128KB is malloc's mmap
threshold: stacks ≥128KB are mmap'd + lazily faulted, so spawn stays at full
speed AND resident memory drops sharply. Dropping to 64KB was a TRAP — arena
malloc instead of mmap, 4x slower spawn (0.06M/sec) and *higher* committed RSS.

### 2026-07-24 — VMEM allocator + 1MB nominal stacks (superseded 128KB)

arsenal now builds minicoro with `MCO_USE_VMEM_ALLOCATOR` (raw mmap). Stacks
are virtual reservations — only touched pages fault in — so `TuckStackSize`
went to **1MB** at the SAME physical cost as 128KB and the same speed:

- 40k coroutines: **~329MB** peak RSS (1MB nominal each = 40GB *virtual*, ~329MB
  *resident*), spawn 0.24M/sec, switch 1.70M/sec — all unchanged from 128KB.
- Removes the fixed-depth cap: deep user recursion just faults more pages
  instead of overflowing a small stack.

Honest caveat: on Linux, glibc `calloc` of ≥1MB is *already* lazy (mmap + CoW
zero-page), so 1MB was cheap even without the define — measured 165MB at 20k.
The `MCO_USE_VMEM_ALLOCATOR` define makes the lazy behaviour explicit and robust
across libc/sizes/platforms rather than relying on calloc's large-alloc path.

## Notes on what each measures

- **async scale** (`bench_async_scale.nim`): N live coroutines each yielding K
  times, all on one cooperative thread. Spawn is dominated by the 256KB
  minicoro stack alloc per coroutine (~90µs each) — NOT scheduler enqueue (a
  Deque, O(1)). So N live coroutines reserve N*256KB; 10k default ≈ 2.5GB peak.
  Switch throughput is the headline number. CEILING: fat stacks cap how many
  coroutines fit in RAM; a smaller/segmented stack would lift spawn+density.
- **actor throughput** (`bench_actor_throughput.nim`): one actor, N messages
  enqueued + drained through the exact primitives codegen emits
  (mailbox seq, drain proc, tuckStartActor, tuckNotifySend, waitUntil).
  Single-thread, no locks — the fast path.
- **compiler front-end** (`bench_compiler.sh`): N independent type+fn pairs,
  `tuck ch` timed (2nd run, warm msgpack cache). Linear ~23k lines/sec up to
  12k fns tested — no superlinear cliff observed. Codegen not included.

## History

<!-- append a dated row here each time a run shifts the numbers materially -->

## Value semantics vs reference semantics — 2026-08-11

**The question this answers:** Tuck's central bet is that every record is a
VALUE (spec §7.1 Tier 1 — copied, no `ref`, no heap). Does that cost
performance? `benches/bench_value_vs_ref.nim` holds everything constant —
same Nim, same allocator, same flags, same workload — and changes only
`object` to `ref object`.

`-d:release --opt:speed --mm:arc`. Ratio > 1.00 means VALUE semantics is
faster.

| record | shape | value µs | ref µs | ratio | winner |
|---|---|---|---|---|---|
| 16 B | S1 read-param | 38968 | 48258 | 1.24x | value |
| 16 B | S2 build-return | 4251 | 43277 | **10.18x** | value |
| 16 B | S3 iterate | 21979 | 22277 | 1.01x | tie |
| 16 B | S4 copy-assign | 1636 | 14306 | **8.74x** | value |
| 256 B | S1 read-param | 41441 | 47789 | 1.15x | value |
| 256 B | S2 build-return | 20500 | 124048 | **6.05x** | value |
| 256 B | S3 iterate, 1 field of 32 | 101250 | 68420 | **0.68x** | ref |
| 256 B | S3 iterate, all fields | 285686 | 690791 | **2.42x** | value |
| 256 B | S4 copy-assign | 1615 | 14086 | **8.72x** | value |

**Value semantics wins 8 of 9 shapes, and the losses are not where the
folklore says.** The three things worth carrying:

1. **Passing is already free, at any size.** Nim compiles a large non-`var`
   object parameter to a POINTER — verified in the emitted C: `byVal(Big)`
   and `byVar(var Big)` produce byte-identical signatures. Value semantics
   never copies to pass. S1's margin is `ref` paying refcount traffic that
   value semantics does not have.
2. **The copy value semantics is accused of mostly does not happen.** S4 is
   `var b = a` on a 256-byte record and value is 8.7x FASTER — the copy is
   dead and the optimizer deletes it, while `ref` cannot delete an increment
   and a decrement. Construction (S2) is the same story one level up: `ref`
   must call the allocator, value semantics must not.
3. **The one loss is a LAYOUT problem, not a semantics problem.** Reading 1
   field out of 32 across 200k records strides a cache line per element;
   the array-of-pointers happens to pack denser. Neither `ref` nor value
   fixes that — splitting the record or an SoA layout does. It is the
   classic AoS access pattern, and it would cost the same in C.

**Consequence for the language:** value semantics needs no defending on
performance grounds, and needs no copy-elimination machinery to be
competitive. The copy-elision work that motivated this bench
(`-O:chain-inplace`) addresses the builder pattern specifically — a real
528-byte-stack-frame case — but the bench shows that pattern is not where the
cost of value semantics lives, because for the common shapes there is no cost
to remove.

Caveat on target: measured on x86-64 with a large cache. On a Cortex-M with
no cache and no allocator the case is *stronger*, not weaker — `ref` needs a
heap that Tier 1 deliberately does not have.
