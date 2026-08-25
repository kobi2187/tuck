# alloc.allocator — Tuck translation

## This module is a language feature, not a library.

The Nim design's centrepiece was a `Memory` handle passed to everything
that allocates, with four strategies behind it (arena, pool, heap, secure),
plus `=destroy`/`=sink` hooks returning bytes to the right allocator. The
Nim pass called it one of its three best findings.

**Tuck declares memory regions in the language.** Both are run-verified
(`examples/13-arena-mem.tuck`, `examples/25-pools.tuck`; the `pool`
acquire/release cycle typechecks clean — verified this pass):

```tuck
pool Sessions = Session [count: 64]          # fixed count, decided at link time
pool RxBuffers = Array[512, u8] [count: 4]

arena ScratchSpace [size: 2048]:
  let buf = ScratchSpace.alloc Array[128, u8]
  ScratchSpace.reset                          # whole arena gone in one instruction
```

So there is no `Memory` value to thread through signatures — the region is
named at its declaration and used by name. That removes the Nim design's
"one trailing named argument" ceremony (`newList[int](memory = pool)`)
entirely, and it removes the question of what happens when a collection
outlives its allocator: a pool slot is *borrowed*, and `release` goes
through the pool because **the pool is the owner**.

## Two properties worth keeping from the Nim design's reasoning

- **Exhaustion is absence, not failure.** `Sessions.acquire` returns `?T`,
  and `examples/25`'s own comment makes the argument the Nim design also
  reached: refusing the 65th client is *backpressure*, correct behaviour,
  not an error path. `?T` carries that exactly.
- **The count is a real-world fact.** DMA channels, `worker_connections`,
  ISR event slots. The example is emphatic that this is what separates a
  pool from "a cache with extra steps" — worth preserving in whatever
  guidance replaces this module's docs.

## What does *not* survive, and one real gap

- **`SecureAllocator` / `Secret[T]`** — no counterpart. This is the same
  gap `core.mem::Scrubbed[T]` names: zero-on-drop needs a destructor hook
  and an optimizer barrier, and Tuck has neither. `secrets-vault` drove
  this requirement and `INDEX.md` records it as a design-changing finding,
  so it should not be quietly dropped. **The single most substantial thing
  the `alloc` tier loses in translation.**
- **Per-collection allocator choice** — a Tuck `Seq` doesn't take a region
  argument. Whether the language should grow one (`Seq` in an arena) or
  whether pools/arenas cover the real cases is an open question this file
  doesn't settle; `examples/25`'s three motivating cases (DMA buffers,
  connection slots, ISR records) are all fixed-count, which suggests pools
  may be sufficient in practice.

## Recommendation
Drop `alloc.allocator` as a module; fold its *reasoning* (exhaustion as
backpressure, counts as facts) into documentation for the language's own
`pool`/`arena`. Track the secret-scrubbing gap with `core.mem`'s — one
decision resolves both.
