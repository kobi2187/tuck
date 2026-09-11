# Project Map: Tuck stdlib (stdlib-project/modules)

Ground truth as of 2026-09-11: `ls modules/*/*/*.tuck` for done, `ROADMAP-GRAPH.md`
§3.3/§6 for the layer split and build order, `git log` for what's landed since
that document was written (recursive sum types shipped — `57a7e77`/`68674e8` —
superseding the "stream fork blocked" framing for tree-shaped data).

## Component tree

### core — freestanding, no heap, no OS
- [x] core.cmp        (status: done)
- [x] core.num        (status: done)
- [x] core.hash       (status: done)
- [x] core.convert    (status: done)
- [x] core.str        (status: done — runes main position, char for ASCII)
- [x] core.iter       (status: done — plain :fnRef adapters, sum/sort scoped to int pending a constraint ruling)
- [x] core.array      (status: done — atFixed/setAtFixed/countOf/chunk; needed real Array[N,T] primitives, see DISCOVERIES)
- [ ] core.slice      (status: unscoped — needs an Indexable-shaped interface per user ruling, "via simple for loop and indices")
- [ ] core.types      (status: unscoped — no compiler blocker)
- [ ] core.error      (status: unscoped — no compiler blocker)
- [ ] core.fmt        (status: unscoped — depends on core.convert, done)
- [ ] core.mem        (status: blocked — needs resource registry, spec §7.4)
- [ ] core.ptr        (status: blocked — needs resource registry)
- [ ] core.atomic     (status: blocked — needs [nocopy]/F25, non-copyable values)
- [ ] core.sync-cell  (status: blocked — needs core.atomic)
- [ ] core.geom       (status: out-of-scope-v1 — no consumer yet)
- [ ] core.simd       (status: out-of-scope-v1 — platform-specific, no backend story)

### alloc — heap, no OS
- [x] alloc.vec       (status: done)
- [x] alloc.map       (status: done)
- [x] alloc.set       (status: done)
- [x] alloc.string    (status: done — Builder, from the bench)
- [x] alloc.deque     (status: done — Ring[T])
- [x] alloc.list      (status: done — integer-index linked structure)
- [ ] alloc.fmt       (status: unscoped — depends on core.fmt)
- [ ] alloc.box       (status: blocked — needs resource registry)
- [ ] alloc.rc        (status: blocked — needs resource registry)
- [ ] alloc.allocator (status: blocked — needs resource registry)

### std — hosted, hand-written today as flat modules (pre-dates this pass)
- [x] std/console, std/fs, std/net, std/sys, std/time  (status: done, OLD generation — not yet re-cut into modules/std/*)
- [x] std/hash, std/math, std/random, std/bits, std/str, std/seq  (status: done, OLD generation)
- [ ] std/log, std/testing, std/cli, std/queue, std/perf  (status: unscoped)
- [ ] std/regex, std/serde-derive, std/reflect, std/i18n  (status: out-of-scope-v1 — each is months per ROADMAP-GRAPH §0)
- [ ] std/crypto, std/compress, std/archive, std/db       (status: out-of-scope-v1)
- [ ] std/net-http, std/net-tls, std/async, std/chrono, std/encoding  (status: out-of-scope-v1 for now — net-http/tls gated on F4 stream fork)

### sys — OS surface
- [ ] sys/fs, sys/env, sys/process, sys/time, sys/signal  (status: unscoped — small deltas to existing std/fs, std/sys)
- [ ] sys/thread, sys/sync                                  (status: blocked — needs core.atomic)
- [ ] sys/io, sys/net                                       (status: blocked — F4 stream fork per ROADMAP-GRAPH §3.4)
- [ ] sys/ffi, sys/dynload, sys/mmap                         (status: out-of-scope-v1)
- [ ] sys/audio, sys/ble, sys/window                         (status: out-of-scope-v1 — no target consumer)

### platform — embedded/bare-metal
- [ ] everything under platform/*  (status: out-of-scope-v1 — Lens B/C work, gated on F5/F6/F24 rulings per ROADMAP-GRAPH §4, not started)

## Explicitly out of scope (v1)
- core.geom, core.simd — no consumer, no backend story yet
- std/regex, serde-derive, reflect, i18n, crypto, compress, archive, db — each months of work per the two-day-jam scoping rule (ROADMAP-GRAPH §0)
- all of platform/* — bare-metal positioning is a later milestone, gated on F5/F6/F24
- sys/ffi, dynload, mmap, audio, ble, window — no near-term consumer

## Definition of 100% (for THIS pass, not all of Tuck 1.0)
Every `core` and `alloc` module either ships with a real `.tuck` implementation
that runs 0 on all three backends, or is marked blocked with the specific
compiler gap it needs (resource registry, [nocopy]/F25). The "weekend kit"
(ROADMAP-GRAPH §10.1: Map/Set/sort/str/fmt/json/rand/time) is reachable
end-to-end from `stdlib-project/modules`, not the old flat `std/` generation.
