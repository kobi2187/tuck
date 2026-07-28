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
