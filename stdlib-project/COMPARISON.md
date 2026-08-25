# Comparison: functionality coverage against mature stdlibs

Before massaging the 65 modules onto Tuck's actual syntax and idioms, this checks
the *functionality* against libraries that have been battle-tested for decades.
Purpose: catch a missing capability now, while adding a module is cheap, rather
than after the idiom pass makes everything feel finished.

## Method

Primary baseline: **Python's stdlib** — the closest philosophical match to
"batteries included," and the widest single collection of what a general-purpose
hosted-OS language ships by default. Cross-checked against **Java's JDK**,
**.NET's BCL**, and **Nim's stdlib** (the transpile target, and a systems-leaning
peer) specifically where Python's own stdlib is thin or silent, so a capability
Python itself doesn't ship isn't wrongly flagged as a gap.

Every finding below is grounded by reading the actual `API.nim.md` files, not
inferred from the module names in `INDEX.md` — several suspected gaps (progress
bars, thread channels, subprocess pipes, weighted random choice, gzip/zstd,
Unicode normalization, anonymous shared memory) turned out to already be present
on inspection and are listed under "already covered" so they don't get
re-raised later.

## Tier-by-tier verdict

**core** (types, slice, array, str, iter, cmp, convert, fmt, mem, ptr, atomic,
sync-cell, error, simd, hash, num) — matches the primitive/generic vocabulary of
Python's builtins + `itertools`/`functools`/`struct`, Java's `java.lang`, and
.NET's `System`. No structural gap found: iterator combinators, atomics, bit
operations, and two-tier hashing (fast/DoS-resistant) are all present and are
exactly the set a mature runtime ships at this layer.

**alloc** (allocator, vec, string, map, set, deque, list→rejected, box, rc, fmt)
— matches Python's `list`/`dict`/`set`/`collections`, Java's `ArrayList`/
`HashMap`/`HashSet`/`ArrayDeque`, .NET's `List<T>`/`Dictionary`/`HashSet<T>`/
`Queue<T>`. Two real absences below (heap, sorted map).

**sys** (io, fs, env, process, thread, sync, time, net, mmap, dynload, ffi,
signal, ble) — matches Java's `java.nio`/`java.util.concurrent`/`ProcessBuilder`
and .NET's `System.Diagnostics.Process`/`System.Threading`. Thread channels,
subprocess pipes with categorized exit status, and anonymous+shared mmap are
all already specified. No gap found at this tier.

**std** (async, testing, log, regex, encoding, crypto, compress, archive,
net-http, net-tls, chrono, math, random, cli, reflect, serde-derive, i18n) —
the widest tier and where every real gap below lives. Individually strong:
compression covers gzip/zlib/deflate/zstd; encoding covers JSON/TOML/CSV/
base64/binary/streaming-XML/RSS-Atom/iCalendar with a documented, principled
exclusion of YAML; testing has fuzzing-with-shrinking and crash injection,
which most mature stdlibs *don't* ship (Python's `unittest` has none of this;
Rust's `libtest` doesn't either — this is ahead of the baseline, not behind
it); i18n has NFC/NFD normalization and locale collation.

**platform** (hal, rtos, interrupt, devicetree, boot, power, dsp, net-lowpower,
libc-shim) — no hosted mature stdlib is a fair comparison here (Python/Java/.NET
don't target bare metal). Cross-checked instead against `embedded-hal`/RTIC in
the original report; that comparison already happened and isn't repeated here.

## Confirmed gaps

Ranked by how load-bearing the absence is for the stated goal ("a weekend dev
finishes a 2-day project without writing fundamentals").

1. **No binary heap / priority queue.** Python `heapq`, Java `PriorityQueue`,
   .NET `PriorityQueue<T,P>`, Nim `std/heapqueue` all ship one — it's closer to
   universal across baselines than almost anything else on this list. Load-bearing
   for Dijkstra/A*, k-way merge, and event/task scheduling by priority — exactly
   the kind of "fundamental" the project's own stated goal says shouldn't need
   hand-rolling. Not present under `alloc` or anywhere else in the 65 modules.

2. **No embedded/relational data store.** Nothing named `sqlite`, `database`, or
   `sql` anywhere in the tree. Java ships JDBC, .NET ships `System.Data`, Python
   ships `sqlite3` in the stdlib proper — this is one of the few places all
   three mature baselines agree, and it's a real load-bearing hole for exactly
   the class of app this project keeps generating (`kv-store-server` hand-rolled
   its own WAL from scratch rather than reaching for anything). Doesn't have to
   be a full relational engine — even an embedded key-sorted store (LMDB/leveldb
   shape) would close most of the gap `alloc.map` can't.
   **Specified in `DOMAINS.md`'s Extension round 4** —
   `modules/std/db/API.nim.md`, a `database/sql`-shaped query interface with
   a bundled `sqlite` submodule, resolved through `GOVERNANCE.md`'s rung
   model rather than picked ad hoc.

3. **No profiling/tracing/metrics module.** No `profile`, `trace`, or metrics
   surface anywhere. Python ships `cProfile`/`trace`/`timeit`; Java ships JFR
   and `java.lang.management`; .NET ships `System.Diagnostics.Stopwatch` and
   `EventSource`. `std.log` covers structured logging but nothing here answers
   "where did the time go" or "how many of X happened" — a real absence for a
   systems-facing stdlib specifically, more than for a scripting one.
   **Specified in `DOMAINS.md`'s Extension round 4** —
   `modules/std/perf/API.nim.md` (`Stopwatch`/`Counter`/`Histogram`),
   measurement only; sampling profilers and flamegraphs stay external per
   `GOVERNANCE.md`'s split.

4. **No sorted/ordered associative container.** Java `TreeMap`, .NET
   `SortedDictionary`, Rust `BTreeMap`, Nim `CritBitTree` all ship one — but
   Python's own stdlib does **not** (`sortedcontainers` is third-party there),
   so this is a softer gap than #1: three of four baselines have it, the
   philosophically closest one doesn't. Worth a deliberate yes/no, not an
   automatic add.

5. **No arbitrary-precision integer.** Java `BigInteger`, .NET
   `System.Numerics.BigInteger`, Python's own `int` (language-level, not
   stdlib, but present) — nothing named `bigint` anywhere in `core.num` or
   `std.math`. `std.math::Decimal` covers exact fixed-point money math but not
   unbounded integers. Matters for `git-lite`-style content hashing math and
   anything doing exact large-number arithmetic; doesn't matter for the
   embedded-facing tiers, which correctly wouldn't want one anyway.

6. **`std.random` has no non-uniform distributions.** `roll`, `chance`, `pick`,
   `pickWeighted`, `shuffle`, `sample` are all present and cover the common
   case well — but Python's `random` module also ships `gauss`, `expovariate`,
   `gammavariate`, `betavariate` and friends, and `load-tester`-style latency
   modeling or any Monte Carlo use case wants at least a normal and an
   exponential distribution. Smallest gap on this list — plausibly one function
   (`gaussian(mean, stddev)`) rather than a subsystem.

7. **No general-purpose recurring timer.** `sys.time` has `sleep` and duration
   math; `std.async` correctly explains *why* it doesn't build one in (the
   `reportEvery(1.seconds)` example is user-written, a plain loop around
   `sleep`). Java's `ScheduledExecutorService`, .NET's `System.Threading.Timer`,
   and Python's `sched` module all provide the convenience wrapper anyway.
   Smallest, most skippable gap here — the primitive it would be built from
   already exists, so this is closer to "a nice one-liner to add" than "a
   missing fundamental."

8. **No email/MIME parsing.** Python ships `email`; Java ships JavaMail outside
   the core JDK (so it's actually a third-party addition even there); .NET has
   no first-party MIME parser either. Weakest gap on the list — only one of
   three baselines actually ships it in the base library, and no application
   in this project's own validation set (26 apps) needed it. Listed for
   completeness, not recommended.

## Already covered (checked, not gaps)

Confirmed present on inspection, so these don't need re-raising in a later pass:
thread channels (`sys.sync::Channel[T]`, MPMC, with `trySend`/backpressure),
subprocess I/O (`sys.process::Pipe`, `Streamable`, categorized `ExitStatus`),
progress bars and aligned terminal tables (`std.cli::Progress`/`ProgressGroup`/
`Table`), weighted random choice (`pickWeighted`), full compression method set
(gzip/zlib/deflate/zstd with dictionary support), Unicode normalization and
locale-aware collation (`std.i18n`), fuzzing with shrinking and crash injection
(`std.testing::fault`), anonymous *and* shared (fork-surviving) memory mapping
(`sys.mmap::scratch(shared = true)`), bitset operations on plain integers
(`core.num`).

## Deliberately excluded already (from the report/INDEX, not re-litigated here)

GUI (`std.gui`), YAML (`std.encoding`'s stated inclusion policy), a generic
image codec (validated by `image-thumbnailer`'s deliberate absence), and
`alloc.list` (a linked list — three candidate apps each resolved to
`vec`/`deque`/`map` instead). These were reasoned through already; not gaps.

## For the next step

Items 1–3 look like real "batteries included" holes worth a design pass before
the Tuck-idiom translation — a priority queue is nearly free (it's `alloc.vec`
plus a sift function), the data-store question is the biggest single design
decision on this list and deserves its own scoping discussion rather than a
bullet point, and a metrics/profiling module is the one place a *systems*
language's stdlib should arguably go further than Python's, not just match it.
Items 4–8 are smaller, more clearly optional calls — recorded so they're a
conscious yes/no rather than a silent omission.
