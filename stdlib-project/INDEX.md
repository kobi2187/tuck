# Index: Module API Designs, Validated Against Application Scenarios

This directory is the follow-up to `REPORT.md`'s comparative stdlib study and unified proposal. Per the proposal's five tiers, every module named in Part IV now has its own folder under `modules/<tier>/<module>/API.md` containing a concrete API sketch (types and signatures, not just prose), the real-world API(s) it's modeled on, and a "validated by applications" section that traces specific design decisions back to a specific application's concrete requirement. Eleven medium-complexity application ideas live under `apps/<name>/APP.md` and were used as the validation harness — analysis only, nothing here was implemented or run.

72 modules (including three submodules — `std.crypto::x509`, `std.encoding::ics`, `std.db::sqlite` — and eight new top-level modules — `sys.ble` (round 2) and `sys.window`, `sys.audio`, `std.db`, `core.geom`, `platform.watchdog`, `std.perf`, `std.queue` (round 4) — added across four extension rounds), 26 applications, ~100,000 words of design analysis. See "Extension round 1/2/3/4" below the coverage matrix for what was added after the initial pass and why.

## The applications

| App | One-line scope | Primary tiers exercised |
|---|---|---|
| `web-downloader` | Resumable, parallel, wget-like CLI downloader | std (net-http, async, crypto), sys (net, fs, signal) |
| `mp3-player` | Local audio player with real-time playback thread | sys (thread, sync, mmap), alloc (allocator) |
| `cli-hangman` | Terminal word-guessing game | std (random, cli, testing) — deliberately the smallest, a control case |
| `todo-cli` | Taskwarrior-like local task manager with a filter query language | std (chrono, encoding, regex), alloc (map) |
| `podcast-subscriber` | RSS/Atom feed poller and episode downloader | std (encoding, net-http, async, chrono) |
| `archive-cli` | Zip/tar.gz CLI archiver, winzip-like, with encryption | std (archive, compress, crypto), sys (fs, io) |
| `doc-convert-tester` | Round-trip document/data-format conversion harness | std (encoding, i18n, testing, reflect) |
| `secrets-vault` | Encrypted local password manager | std (crypto), alloc (allocator, string) |
| `chat-server` | Multi-client TCP chat server | sys (net, sync, thread, signal) |
| `embedded-sensor-node` | Bare-metal firmware design: I2C sensor, BLE advertise, sleep | platform (all 9 modules), core, alloc |
| `log-grep` | ripgrep-lite parallel file search | std (regex, i18n), sys (mmap, fs) |
| `process-supervisor` | systemd-lite process supervisor with crash restart | sys (process, signal, fs), std (log, chrono) |
| `math-toolkit-cli` | unit/currency conversion, CSV stats, exact decimal money math | std (math, encoding, testing) |
| `image-thumbnailer` | batch image resize/thumbnail CLI | sys (ffi, process), std (async, crypto) — validates the deliberate absence of an image codec module |
| `kv-store-server` | redis-lite in-memory KV store with WAL durability | sys (net, sync, fs), std (async, testing) |
| `embedded-display-node` | second embedded device: SPI display, encoder interrupts, persistent RTC | platform (all 9, especially hal/power/boot) |
| `git-lite` | mini content-addressed version control | std (crypto, compress, encoding), core (hash), alloc (map) |
| `diff-patch` | unified-diff generator/applier (Myers/LCS) | core (iter, cmp), alloc (vec, string), std (testing) |
| `spellchecker` | Unicode-aware text linter with suggestions | std (i18n, regex), alloc (set) |
| `config-schema-validator` | validates config files against a schema | std (reflect, encoding), core (error) |
| `ble-scanner` | hosted-OS BLE central, companion to embedded-sensor-node | sys (ble — new module), std (encoding, chrono) |
| `backup-sync` | rsync-lite directory sync with block-level delta transfer | sys (fs), core (hash — rolling checksum), std (crypto, regex) |
| `load-tester` | ab/wrk-lite HTTP load generator | std (async, net-http, math), sys (time, signal) |
| `ics-calendar-tool` | iCalendar parser/generator with RRULE recurrence | std (chrono, encoding) |
| `sudoku-solver` | constraint-propagation solver + puzzle generator | core (num, array, iter), alloc (vec) — core+alloc-only control case |
| `tls-cert-inspector` | TLS handshake/certificate-chain diagnostic tool | std (crypto, net-tls), sys (net) |

## Full module list by tier

**core** (freestanding — no allocator, no OS): `types`, `slice`, `array`, `str`, `iter`, `cmp`, `convert`, `fmt`, `mem`, `ptr`, `atomic`, `sync-cell`, `error`, `simd`, `hash`, `num`, `geom` *(added in Extension round 4 — vectors/matrix/AABB, no allocator needed)*

**alloc** (heap, no OS): `allocator`, `vec`, `string`, `map`, `set`, `deque`, `list`, `box`, `rc`, `fmt`

**sys** (hosted OS, thin wrapping): `io`, `fs`, `env`, `process`, `thread`, `sync`, `time`, `net`, `mmap`, `dynload`, `ffi`, `signal`, `ble` *(round 2 — hosted-OS BLE central, sibling to `platform.net-lowpower`'s embedded BLE peripheral)*, `window` *(round 4 — window/surface/input primitive, shared consumer across desktop/game/mobile)*, `audio` *(round 4 — thin PCM device I/O, bundled rung B1)*

**std** (hosted OS, batteries included): `async`, `testing`, `log`, `regex`, `encoding`, `crypto`, `compress`, `archive`, `net-http`, `net-tls`, `chrono`, `math`, `random`, `cli`, `reflect`, `serde-derive`, `i18n`, `db` *(round 4 — query/row-mapping interface, `database/sql`-shaped, with the bundled `sqlite` submodule as rung B1's reference driver)*, `perf` *(round 4 — Stopwatch/Counter/Histogram, measurement only; heavier profiling stays external per `GOVERNANCE.md`)*, `queue` *(round 4 — `DurableQueue[T]`, crash-safe push/pending/ack, generalizing the mobile-sync write-queue finding)*

**platform** (embedded/systems toolkit, sibling of std): `hal`, `rtos`, `interrupt`, `devicetree`, `boot`, `power`, `dsp`, `net-lowpower`, `libc-shim`, `watchdog` *(round 4 — arm/feed/timeout, vendor-boundary-friendly)*

## Coverage matrix — which apps drove which modules' design decisions

`●` = primary validation app (a real design decision traces to this app) · `○` = secondary/incidental exercise · blank = not exercised

| Module | web-dl | mp3 | hangman | todo | podcast | archive | doc-conv | vault | chat | embedded | grep |
|---|---|---|---|---|---|---|---|---|---|---|---|
| core.error | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ● | ○ |
| core.fmt | | | | | | | | ● | | | |
| core.hash | | | | ○ | ○ | | | | ● | | |
| core.array/slice | | | | | | | | ● | | | |
| core.mem | | | | | | | | ● | | | |
| core.atomic/simd/ptr | | ● | | | | | | | | ● | |
| alloc.allocator | | ● | | | | | | ○ | | ● | |
| alloc.string/vec | | | ○ | ○ | | | | ● | | | |
| alloc.map/set | | | ○ | ● | ● | | | | ● | | |
| alloc.list | | (rejected) | | (rejected) | | | | | (rejected) | | |
| sys.io | | ● | | | | ● | | | | | ● |
| sys.fs | ● | ● | ○ | ● | ● | ● | ● | ● | | | ● |
| sys.mmap | | ● | | | | | | | | | ● |
| sys.thread/sync | | ● | | | | | | | ● | | |
| sys.net | | | | | | | | | ● | | |
| sys.signal | ● | | | | | | | | ● | | |
| sys.process/dynload/ffi | | ○ | | | | | | | | | |
| std.net-http/tls | ● | | | | ● | | | | | | |
| std.async | ● | | | | ○ | | | | ● | | ○ |
| std.crypto | ● | | | | | ● | | ● | | | |
| std.encoding | | ○ | | ● | ● | | ● | ● | | | ○ |
| std.chrono | | | | ● | ● | | | | ○ | | |
| std.random | | | ● | | | | | | | | |
| std.regex | | | | ● | | | | | | | ● |
| std.compress/archive | | | | | | ● | | | | | |
| std.testing | | | ● | ● | | | ● | | | | |
| std.cli | ● | ● | ● | ● | | ● | | ● | | | ● |
| std.i18n | | | | | | | ● | | | | ● |
| std.reflect/serde-derive | | | | | | | ● | | | | |
| std.log | ● | ○ | | | ● | | | | ● | | |
| platform.* (all 9) | | | | | | | | | | ● | |

The blank cells are as informative as the filled ones. `sys.process` is exercised by no app in this set — a real, recorded gap (noted in that module's own file) rather than a filled-in guess. `alloc.list` is the one module three different apps (mp3-player, todo-cli, chat-server) initially looked like plausible customers for, and all three resolved to `vec`/`deque`/`map` instead on inspection — which validates *removing* it from the "obvious choice" path more than it validates the module itself, echoing Rust's own docs, which steer users elsewhere. `core.atomic`/`core.simd`/`core.ptr`/`alloc.allocator` are validated almost entirely as substrate — no app calls them directly as a "top-level" API, but `mp3-player`'s real-time audio thread and `embedded-sensor-node`'s bare-metal constraints are the concrete forcing functions underneath higher-level calls.

## Findings that changed the Part IV design, not just decorated it

These are the places where working through an application forced a real revision, not just an illustration of an already-settled design:

1. **`std.encoding` gained an XML/RSS/Atom codec it didn't have.** Part IV's module list covered json/toml/csv/base64/binary and stopped there. `podcast-subscriber` needs to parse RSS/Atom feeds, which are XML — and XML carries the XXE (external entity injection) vulnerability class that JSON/TOML don't. The resolution, in `modules/std/encoding/API.md`: a streaming-only `XmlReader` with DTD/external-entity processing structurally absent — not an off-by-default flag, but no flag at all — so the unsafe path cannot exist even if a caller tries. `FeedReader` (RSS/Atom) is a thin layer on top, not a second parser.

2. **`alloc.allocator` and `std.crypto` had to take an explicit position on secret memory.** `secrets-vault` raises a question the original Part IV proposal left implicit: can `alloc.string`/`alloc.vec` request zero-on-drop, non-swappable memory for passwords and keys, or is that entirely `std.crypto`'s problem? The resolution: a `SecureAllocator` + `Secret<T>` wrapper lives in `alloc.allocator` itself, and `alloc.string`/`alloc.vec` get secret variants "for free" through composition (`Secret<String>`) rather than forking parallel types — and `core.fmt`'s `Display`/`Debug` split does real work here too, since a `Secret<T>` can implement a redacting `Debug` while never implementing `Display`, making accidental secret-logging a compile error rather than a runtime leak.

3. **`sys.signal` cannot be a handler-callback API.** `web-downloader`'s requirement — Ctrl-C must leave a resumable partial file, never a corrupt one — rules out calling into `sys.fs` from actual OS signal-handler context (unsafe by construction on every real OS). The module resolved to a receive/poll model (modeled on Go's `os/signal` and the `signal-hook` crate) instead of a naive `on_signal(callback)` design.

4. **`sys.sync` needed a lock-free type beyond `Mutex`/`Condvar`, not just those two.** `mp3-player`'s real-time audio callback cannot tolerate blocking on a contended lock — a glitch is audible. A "just offer `Mutex<T>`" design, which would have looked complete against every other app in the set, fails this one specifically, forcing a dedicated `SpscRing` (single-producer/single-consumer lock-free ring) into the module.

5. **`std.chrono` needed first-class recurrence math, not just duration arithmetic.** `todo-cli`'s "remind me every Monday" requirement is a common, well-known gap in date/time libraries (most only do calendar math and duration deltas). `Recurrence::next_after(date)` was added as a first-class value type, kept separate from the string-parsing convenience layer.

6. **`std.async` had to justify one design serving two different shapes.** `web-downloader` is "N tasks, one join point, then exit"; `chat-server` is "thousands of long-lived connections, indefinitely." Rather than assuming one `Context`/`Scope` design trivially covers both, the module doc works through why it does: one root scope for a bounded batch (downloader) versus one child scope per connection derived from a long-lived root (chat-server) — same primitives, different composition, which is a real answer rather than a hand-wave.

7. **`platform.hal`'s `I2c` trait gained a mandatory `timeout` and a categorized error type.** Upstream `embedded-hal` (the design's direct model) leaves bus-operation timeout policy to the implementer. `embedded-sensor-node`'s "read with timeout, retry on bus error, don't hang the device" requirement is inexpressible against that upstream shape without reaching past the trait into vendor registers — exactly the portability erosion Part V of the report warned about. The fix: `timeout: Duration` as a required parameter and `I2cError` categorization (NoAck/BusError/ArbitrationLoss/Timeout) as part of the trait contract, not an escape hatch.

8. **`core.hash` needed two algorithms with an explicit default, not one.** Contrasting `chat-server` (hash-map keys can be attacker-influenced — nickname/room strings from untrusted clients — so a DoS-resistant hash matters) against `todo-cli`/`podcast-subscriber` (trusted local keys, raw speed matters more) forced SipHash as `alloc.map`'s default with FNV available as an explicit opt-out, rather than picking one algorithm and calling it done.

9. **`doc-convert-tester` forced CSV into a deliberately different calling convention than the other `std.encoding` formats.** CSV has no native type system to decode against, so automatic type inference (is `"007"` a string or the number 7?) is a real, silent-corruption risk the round-trip harness would catch immediately. The resolution: CSV decode requires the caller's target type to drive parsing — no untyped "guess the column types" path exists — a documented, narrow exception to Design Principle 4's "one idiom" rule, justified in the module file rather than left implicit.

## Honest gaps this exercise surfaced (not resolved, just named)

- **`sys.process` has zero validating apps in this set.** None of the eleven applications spawn a subprocess. Its API design in `modules/sys/process/API.md` is grounded in the report's survey (`Command` builder pattern) rather than in any app-specific pressure-testing — worth flagging if this project continues, since an untested design is exactly where surprises hide.
- **`platform.dsp`'s FFT and matrix-math surface is unvalidated.** `embedded-sensor-node` only exercises a trivial moving-average filter, deliberately (per that app's own design note, to check the module isn't over-built for the simple case) — but that means the harder, more failure-prone parts of a CMSIS-DSP-style API were never actually stress-tested here.
- **`platform.net-lowpower`'s `LowpanStack`/6LoWPAN surface is speculative** for the same reason — the one embedded app only advertises over BLE, it never joins a mesh network.
- **The vendor-escape-hatch tension from Part V is real, not resolved.** `platform.hal` and `platform.interrupt` hold up cleanly against the one device this project analyzed; `platform.devicetree`, `platform.boot`, `platform.power`, and `platform.net-lowpower` all name specific, bounded escape hatches (overlays, a `PreInit` hook, a speculative `SleepDepth::Custom`, keeping GATT out of the advertise-only path) rather than claiming full vendor neutrality. A second real device with different quirks is the natural next stress test.

## Extension round 1 — 5 more apps, closing named gaps

Five more applications were added specifically to attack the "honest gaps" section above and push into under-validated territory, at the request to keep going until stdlib coverage is deep enough that "a weekend dev can finish a 2-day project without writing fundamentals."

| App | One-line scope | Target gap |
|---|---|---|
| `process-supervisor` | systemd-lite: supervises child processes, restarts on crash, rotates logs | `sys.process` had **zero** validating apps before this |
| `math-toolkit-cli` | unit/currency conversion, CSV statistics, exact decimal money math | `std.math` was only validated incidentally before this |
| `image-thumbnailer` | batch image resize/thumbnail CLI | tests the deliberate absence of any image-codec module |
| `kv-store-server` | redis-lite: in-memory KV store, WAL durability, sustained concurrent load | a third `std.async`/`sys.sync` load shape (busy, throughput-bound) vs. web-downloader's bounded batch and chat-server's idle long-lived connections |
| `embedded-display-node` | second embedded device: SPI display, rotary encoder interrupts, persistent RTC | stresses `platform.*` on axes embedded-sensor-node never touched (SPI, edge-interrupt wake sources, state that survives reset) |

No new top-level modules were created this round — every requirement was resolved as a concrete addition to an existing module's API, or explicitly deferred as a named, unresolved risk. The module count stays at 64; the app count is now 16.

### What actually changed (not just got a new citation)

- **`sys.process`'s `ExitStatus` became a closed `enum { Exited(i32), Signaled(Signal) }`**, forcing exhaustive handling instead of an opaque struct with independently-nullable `code()`/`signal()` accessors — resolves the classic POSIX `wait()` footgun that a supervisor cannot safely paper over. `Child::signal(sig)` was added for graceful termination, reusing `sys.signal`'s `Signal` type rather than inventing a parallel one.
- **`sys.fs` gained `File::sync_data()`** (content-only fsync) alongside the existing `sync_all()` (content+metadata) — `kv-store-server`'s write-ahead log needs cheap per-append durability, and forcing a full metadata fsync on every single WAL record would have made its stated durability policy impractically slow.
- **`alloc.map` gained `retain(&mut self, f: impl FnMut(&K, &mut V) -> bool)`** — a previously-deferred open question, resolved because `kv-store-server`'s active TTL-expiration sweep needs single-pass, allocation-free bulk conditional eviction under lock contention; remove-per-key would double-traverse and allocate on a hot path.
- **`std.math`'s `Decimal` gained an explicit `div(&self, other, scale, mode)`** — division is the one operation that can be non-terminating, and it needed the same explicit `(scale, mode)` shape the design already used elsewhere. The statistics functions were reshaped around a single-pass `stats::describe()` (Welford's algorithm, one pass over one `core.iter` iterator for mean+variance+stddev+count together), because the original per-function design (`mean()`, then `variance()`, then `stddev()`) each consumed the iterator separately — a real bug for a streaming, non-cloneable data source.
- **`std.testing` gained a `fault` module** (`fault::kill_subprocess`, an `Injector` for write/read corruption) — there was no prior support for crash/fault-injection testing, and `kv-store-server`'s core correctness claim ("no lost or corrupted acknowledged writes after a crash") is untestable without it.
- **`platform.hal`'s `SpiBus` gained a write-only `write()` plus an opt-in `SpiBusDma` extension**, and `InputPin` gained an `InterruptPin` extension (`enable_interrupt(edge) -> Result<IrqVector, Error>`) — the original trait set was full-duplex-SPI-only and polled-GPIO-only, neither ever exercised by embedded-sensor-node.
- **`platform.power`'s `WakeReason` was defined as a concrete type for the first time** (it had been referenced in prose but never actually specified), as an enum that can disambiguate *which* GPIO fired (`Gpio(PinId)`), because embedded-display-node's "wake on encoder OR button OR RTC alarm, and know which" cannot be served by a design that only reports *that* something woke the device.
- **`platform.boot` gained `RegionKind::PersistentRam`** plus a `PersistentRegion` trait (`is_initialized()`/`mark_initialized()`) — a real correctness gap: the prior boot model implicitly zeroed all RAM on reset, which would silently destroy the RTC's "have I already set the clock" flag on every reset, even though the RTC hardware itself survives.

### Honest new risk surfaced, not resolved

`std.async`'s Open Questions now names something the first eleven apps never would have found: the design never specified whether `spawn`'s executor is thread-per-task or a bounded M:N pool, and that choice determines whether holding a `sys.sync::Mutex` across contention inside a task can starve the scheduler under `kv-store-server`'s throughput-bound load. A proposed `AsyncMutex`/`AsyncMutexGuard` was added as a mitigation candidate, but the underlying executor-model question is flagged as genuinely open and load-bearing — this project's analysis-only scope can't close it without picking an implementation and measuring it.

## Extension round 2 — 5 more apps, first new module added

| App | One-line scope | Target gap |
|---|---|---|
| `git-lite` | mini content-addressed version control | contrasts `core.hash` (in-memory) against `std.crypto` (content identity) — two hash modules, one clean boundary |
| `diff-patch` | unified-diff generator/applier (Myers/LCS algorithm) | purest `core`/`alloc`-only algorithmic app; best property-testing case yet |
| `spellchecker` | Unicode-aware text linter with suggestions | `std.i18n`'s first real word-segmentation test beyond case-folding |
| `config-schema-validator` | validates TOML/JSON config against a schema | forces the YAML-inclusion decision and a "what and where" error-location mechanism |
| `ble-scanner` | hosted-OS BLE central, companion to embedded-sensor-node | surfaces a genuine tier-placement question: peripheral vs. central Bluetooth roles |

Module count: **65** (one new module added — see below). App count: **21**.

### The first new top-level module: `sys.ble`

`ble-scanner`'s validation note made a real architectural argument the project hadn't confronted: `platform.net-lowpower` was correctly scoped to the freestanding/embedded BLE *peripheral* role (advertise-only, no_std-safe), but a hosted-OS BLE *central* (scan/connect, wraps BlueZ/CoreBluetooth, allocates freely) is a different concern that doesn't belong under the `platform` tier's freestanding umbrella at all. `modules/sys/ble/API.md` is new: `Scanner`/`ScanFilter`/`AdvEvent` for filtered scanning with raw undecoded payload bytes (decoding is `std.encoding`'s job, not this module's), a separate `Dedup` pipeline stage, and an optional `GattClient` kept decoupled so scan-only callers never link connection-state machinery. `platform.net-lowpower`'s own file now cross-references it, so a reader lands on either file and understands the split: same wire protocol, two tiers, because one side is freestanding and the other is hosted-OS. This is the clearest confirmation yet that "layer by dependency, not topic" (Design Principle 1) sometimes means splitting what looks like one feature (Bluetooth) across two tiers rather than picking one.

### What actually changed

- **`core.error` gained a `location()` mechanism** — `Error::location() -> Option<&dyn Location>` plus a minimal, allocation-free `Location` trait — resolving a "what and where" precision gap that had been recurring since `doc-convert-tester` (round 0) and `kv-store-server` (round 1) without ever being addressed at the root. Concrete rich location types (field paths, line/column) are left to `alloc`/`std` to implement against this trait, keeping `core.error` itself allocation-free.
- **`alloc.vec` gained `Grid<T>`**, a flat-`Vec`-backed row-major 2D table — `diff-patch`'s Myers-diff dynamic-programming table is inherently 2D-indexed, and neither `core.iter` nor a `Vec<Vec<T>>` gave a satisfying answer; `core.iter` itself needed no new adapter, since hunk-context grouping was already served by existing `windows`/`chunks` once the edit script is materialized.
- **`std.encoding` adopted a stated inclusion policy** instead of deciding format-by-format ad hoc: a format belongs in `std` only if it's (1) a general-purpose interchange/storage format for arbitrary data, not the fixed output of one specific tool, and (2) has a small, unambiguous, *securely separable* grammar. Applied explicitly: unified-diff fails test 1 (it's `diff-patch`'s own output format, not a general serialization target) and stays out; **YAML formally fails test 2 and is excluded**, on the record, the same way `std.gui` is excluded in `REPORT.md` — YAML's ambiguity (the "Norway problem," unquoted `no`/`yes` becoming booleans; historically unsafe arbitrary-object-construction tags in other ecosystems' parsers) is load-bearing to the format itself, unlike XML's DTD/entity danger, which could be structurally removed while keeping the useful part.
- **`std.reflect` gained a fully dynamic `DynValue` tree type**, decoupled from any compile-time-known `T: Reflect`. This closes a real gap: `config-schema-validator` loads both the config *and* the schema at runtime, so the existing compile-time-derive-oriented reflection story (validated positively by `doc-convert-tester`, validated negatively — i.e., deliberately not used — by `secrets-vault`) had no answer for "walk a value against a schema neither side knew about at compile time." Schema validation becomes a generic recursive walk over two `DynValue` trees; JSON-Schema's specific vocabulary is explicitly kept out of stdlib scope.
- **`std.i18n` gained `edit_distance`** (Damerau-Levenshtein), with the placement decision made explicitly rather than left implicit — spellchecker's suggestion-ranking needs it, and it doesn't cleanly fit `std.math` (not numeric in the sense that module was designed for) or `core.str` (needs `alloc.vec` for the DP table). The module's Open Questions section records the strongest counter-argument for placing it elsewhere instead of asserting the decision is obviously correct.
- **`std.regex` gained `Regex::from_glob`** (gitignore-style glob → regex translation) but explicitly declined to solve gitignore's full ordered/negated list-matching semantics, flagging that as a different, unresolved problem more likely to belong in `sys.fs` than in `regex` itself.

### Honest new risk surfaced, not resolved

`std.i18n::edit_distance`'s placement is recorded as a genuine judgment call, not a settled fact — the module file documents the strongest case for putting it elsewhere and leaves it open. Similarly, `.gitignore`'s list-semantics (ordering, negation, directory-vs-file anchoring) is named as unresolved rather than quietly folded into `Regex::from_glob`'s scope, which only handles the mechanical glob-to-regex translation, not the matching-list semantics around it.

## Extension round 3 — 5 more apps, the executor model gets decided

| App | One-line scope | Target gap |
|---|---|---|
| `backup-sync` | rsync-lite: tree diffing, atomic copy, block-level delta transfer | forces a rolling-checksum primitive distinct from every hash used so far |
| `load-tester` | ab/wrk-lite HTTP load generator with latency percentiles | the fourth `std.async` load shape — client-side sustained high concurrency — and the one that finally forces the executor-model decision |
| `ics-calendar-tool` | iCalendar parser/generator with RRULE recurrence expansion | pushes `std.chrono`'s recurrence support from "every Monday" to the real RFC 5545 grammar |
| `sudoku-solver` | constraint-propagation solver + puzzle generator | the project's `core`+`alloc`-only control case; bitset and fixed-size-2D-grid ergonomics |
| `tls-cert-inspector` | TLS handshake/certificate-chain diagnostic tool | forces X.509 parsing and chain-inspection into the open for the first time |

Module count: **65** (two new *submodules* — `std.crypto::x509` and `std.encoding::ics` — added inside existing modules; no new top-level module this round, unlike round 2's `sys.ble`). App count: **26**.

### The big one: `std.async`'s executor model is now decided, not just flagged

Since Extension round 1, `std.async` carried an unresolved, load-bearing open question: is `spawn`'s executor thread-per-task or a bounded pool, and is it safe to hold a `sys.sync::Mutex` across contention inside a task? `load-tester` — hundreds of concurrent in-flight requests sustained over a fixed duration — is exactly the scenario that makes the answer matter rather than academic. The resolution, now written into `modules/std/async/API.md` as a real design decision: **a bounded M:N work-stealing thread pool**, N OS worker threads roughly matching core count, M lightweight tasks scheduled cooperatively across them — the only model that avoids exhausting OS threads at `load-tester`'s concurrency level, which thread-per-task would hit as a hard scalability wall, not a style preference. The corollary is now a firm rule rather than a suggestion: `AsyncMutex` (first proposed as a tentative mitigation in round 1) is **mandatory** for any lock held across a suspension point or under real contention inside async code, because a blocked plain `Mutex` parks an entire worker thread and stalls every other task scheduled on it. Plain `sys.sync::Mutex` remains fine only for short, uncontended critical sections. This decision also resolved a smaller standing question in `sys.signal`: Ctrl-C detection stays `sys.signal`'s job (cheap, task-count-independent), while "stop accepting new work, drain in-flight work with a bound, print a partial report" is confirmed as entirely `std.async`'s `Context`/`Scope` responsibility — the same split `chat-server` established, now confirmed at an order of magnitude higher concurrency.

### What else actually changed

- **`core.hash` gained a `RollingChecksum` type** (`roll_in`/`roll_out`/`digest`, O(1) per byte as a window slides) — a genuinely different API shape from every hash in the project so far, all of which are fixed-input, compute-once operations. Deliberately kept out of the `Hasher` trait family and explicitly documented as non-collision-resistant: a rolling-checksum match is only a *candidate*, confirmed by a strong hash, mirroring rsync's real two-tier design.
- **`core.num` gained bitset operations** (`trailing_zeros`, `is_bit_set`, `set_bit`, `clear_bit`, `toggle_bit`, `ones()` as an O(popcount) iterator over set-bit positions) — under-specified before `sudoku-solver`, and noted as a cross-tier consistency fix, since the identical gap would otherwise resurface in `platform.hal` register manipulation.
- **`core.array` deliberately did NOT gain a `Grid2D<T, const R, const C>` type**, despite the surface parallel to `alloc.vec::Grid<T>` (added in round 2). The reasoning, recorded rather than assumed: `Grid<T>` exists to solve problems — manual stride arithmetic over a flat buffer, per-row allocation cost of `Vec<Vec<T>>` — that don't exist for a compile-time-sized nested array, which already gives free, allocation-free `grid[r][c]` indexing. Consistency between the two is kept at the convention level (`(row, col)` ordering matches on both sides) rather than by forcing a shared type where one isn't needed — a deliberate rejection of a superficially-tempting unification.
- **`sys.fs`'s `DirEntry` got real methods** (`path`, `file_name`, `file_type`, `metadata`) — previously undefined. The resolution is platform-honest rather than over-promising: Windows' directory enumeration returns size/mtime for free, POSIX's does not, so `DirEntry::metadata()` still costs one `fstatat()` per entry on POSIX (cheaper than a fresh path-resolving `fs::metadata()` call, but not free) — a `read_dir_with_metadata` name was deliberately rejected as misleading on POSIX.
- **`std.chrono`'s `Recurrence` was restructured** from a flat pattern enum into a composite type (rule + bound + timezone + exceptions/additions), resolving the real RFC 5545 gaps `ics-calendar-tool` exposed: signed ordinal weekdays ("third Thursday"), month-day lists, UNTIL/COUNT bounds, and EXDATE/RDATE exceptions — the last of which had been an open question since `todo-cli` first motivated the module. Occurrence expansion now returns zoned timestamps with the offset recomputed per-occurrence, making DST transitions correct rather than assumed away.
- **`std.crypto` gained an `x509` submodule** and **`std.net-tls` gained handshake-only connections and a closed `ChainError` enum** (`Expired`/`HostnameMismatch`/`UntrustedRoot`/`IncompleteChain`) — the certificate type is defined exactly once, in `std.crypto`, and re-exported by `std.net-tls`, continuing the "one parser, not two" rule `std.encoding.xml`'s `FeedReader` established back in round 0.
- **`std.encoding` gained `ics`**, the second format added under the Extension-round-2 inclusion policy (after that policy rejected unified-diff and YAML) — RRULE text is carried raw and handed to `std.chrono::Recurrence::from_rrule` rather than re-parsed inside the encoding layer.
- **`std.math` gained `stats::TDigest`**, an online quantile estimator, as a genuinely different API from the batch `percentiles()` added for `math-toolkit-cli` — batch computation requires retaining and re-sorting every sample, which would distort `load-tester`'s own measurements at high request rates; `TDigest::merge` allows per-worker-thread local digests to combine periodically instead of contending on a shared structure.

### Honest new risk surfaced, not resolved

`sys.time::Instant::now()`'s actual cost on the hot path `load-tester` needs (thousands of calls per second) is flagged, not resolved — the API shape is judged right (opaque, allocation-free) but its performance characteristics depend on the underlying OS mechanism (vDSO on Linux/macOS, `QueryPerformanceCounter` on Windows) in a way this project's analysis-only scope can name but not verify.

## Extension round 4 — the domain-persona pass, seven new modules plus two glue additions

Where rounds 1–3 validated by *application*, this round (`DOMAINS.md`) validated by *developer domain* — web backend, game, desktop, CLI, mobile, embedded — asking what a specific kind of developer needs every day, not what one app happens to exercise. It also corrected its own working definition of "offline" mid-pass: not the shipped app's runtime network reachability, but the *developer's* package-registry access — which changed which gaps counted as blocking (see `GOVERNANCE.md`'s rung B1/B2 split, added the same round). Module count: **72** (7 new top-level modules; the one submodule is `std.db::sqlite`, itself new this round). App count unchanged at 26 — this round validated by persona, not by adding apps.

Seven real gaps, each confirmed absent by grep across the existing 65 before being written up, per this project's standing discipline:

- **`sys.window`** — window/surface creation, input-event polling, framebuffer/GPU-handle access. The highest-leverage single finding: desktop, game, and mobile all independently hit this same absence. Deliberately one altitude below a GUI toolkit (`std.gui` stays excluded, unchanged) — the SDL2/GLFW/raylib shape, not Qt's.
- **`std.db`** — a query/row-mapping interface, Go `database/sql`-shaped, plus a bundled `sqlite` submodule as the reference driver. Resolves the ORM question raised mid-project: not an ORM (an anticipated heavy abstraction this project's own taste rejects), not silence either (Rust's async-runtime fragmentation is the named cautionary case) — an interface at rung A, with the one driver both web-backend and mobile's most common app shape depends on promoted to rung **B1** (bundled in the offline installer, not fetched from a registry).
- **`sys.audio`** — thin PCM device I/O for the game domain, also rung B1 for the same offline-blocking reason as sqlite. Explicitly not a mixer or effects chain; those stay external, built on this baseline.
- **`core.geom`** — `Vec2`/`Vec3`/`Mat3`/`Aabb2` and the intersection tests a real-time loop needs every frame. Small, decades-settled, `core`-tier because none of it needs a heap — same character as `COMPARISON.md`'s priority-queue finding.
- **`platform.watchdog`** — arm/feed/timeout, the most universal fault-recovery primitive in firmware engineering, oddly absent from the original `platform.*` survey despite being more vendor-boundary-friendly than several already-covered concerns.
- **`std.perf`** — `Stopwatch`/`Counter`/`Histogram`, resolving `COMPARISON.md`'s profiling gap on the measurement half only; sampling profilers and flamegraphs stay external per `GOVERNANCE.md`'s split, the same "measurement in std, presentation not" line Go draws between `runtime/pprof` and `go tool pprof`.
- **`std.queue`** — `DurableQueue[T]`: crash-safe `push`/`pending`/`ack`, resolving `DOMAINS.md`'s Finding C. Started as "just compose `alloc.deque` and `sys.fs`," per that finding's own original text — writing the actual composition surfaced real design questions (crash-safe framing, replay ordering, at-least-once accounting) a one-line recommendation hadn't answered, which is why it became a module rather than only an "In use" example.

Two smaller items resolved as glue additions to *existing* modules, per `DOMAINS.md`'s own characterization of them as one-proc-or-one-type gaps rather than new subsystems:

- **`sys.fs` gained `Lock`/`tryLock`/`close`** — an advisory whole-file lock (`flock`/`LockFileEx`-shaped), closing the desktop single-instance-enforcement gap.
- **`std.net-http` gained a `Cookie` type** (`cookies(req)`/`setCookie(reply, c)`) — the type itself was a genuine gap; session state stays a documented composition against `std.crypto`'s existing `hmacSha256`/`sameSecret`, not a new `Session` type, per `DOMAINS.md`'s original "primitives exist, needs an example" call.

**A documentation gap this round leaves open, on purpose.** The Nim-pilot convention below states `core`/`alloc`-tier modules get both an `API.md` (Rust-flavored design reasoning) and an `API.nim.md` (the intended Nim shape). `core.geom` was written `API.nim.md`-only, matching every other module from this round — design-only signatures, no implementation, and (per the request that produced it) no separate Rust-flavored write-up. It's the one module in `core`/`alloc` without that pair; noted here rather than silently inconsistent with the rest of the pilot's own stated rule.

**A translation gap this round leaves open, deliberately, and larger than the one above.** Every `API.nim.md` in this project — including all seven new modules and both glue additions — is written as freeform static functions (`proc`/`func` taking their subject as the first argument), because it was brainstormed by someone who hadn't seen Tuck yet and was scoped to *functionality*, not to Tuck's own idioms. Per direct guidance: most real Tuck code is expected to be built from manager objects and interfaces, with mixins doing the composition work these `API.nim.md` files currently do by convention (the closed verb vocabulary, the `Resource`/`Lifecycle`/`Messenger` protocol assignments) rather than by a language mechanism. That translation — freeform procs into Tuck's actual object/interface/mixin shape — is a distinct future pass, the same way the Nim pilot below was itself a distinct pass after the original Rust-flavored `API.md` reasoning. Nothing in this round attempts it, and nothing here should be read as a claim about what the Tuck-native surface will actually look like.

### Honest gaps this round did not resolve, named rather than guessed at

Per `DOMAINS.md`'s own ranked table: schema migrations (a natural extension of `std.db`'s interface, not written yet), a TTY/piping predicate on `std.cli` (internal logic already exists, needs a public accessor), connection pooling for `std.db` (deliberately deferred the same way `std.async`'s executor model was, until a concrete high-concurrency app forces the real answer rather than a guess), and OTA/DFU firmware updates (rung B2 — vendor-varies, and an offline-safe fallback via physical debugger flashing already exists, unlike the cases that forced `std.db`/`sys.audio` to rung B1).

## The Nim pilot — protocol vocabulary, and a friendlier surface

The Rust-flavored pseudocode in every `API.md` was a lingua franca for *design reasoning*, not a target language. This pass begins expressing the library in **idiomatic, approachable Nim** — the actual intended shape — governed by a new spec, `PROTOCOLS.md`, which supersedes the report's Design Principle 3 and deepens Principle 4.

### What `PROTOCOLS.md` decides

The path there is worth recording, because two attractive ideas were tried and rejected on the way:

- **Zippers** (a cursor that can walk hierarchies and carries its own edit history, giving undo for free via structural sharing) were prototyped and dropped. They are a clever answer to a question a casual coder is not asking, and the wrapper type envelops the value rather than simplifying it. Plain mutation plus an explicit snapshot answers the same practical need with zero new vocabulary.
- **Capabilities** (unforgeable tokens proving the right to act) were prototyped and downgraded. Real capability security needs linear/affine types enforced by the compiler — a language feature, not a library pattern. What survives is the honest weaker version: **opaque handles with private constructors**, documented as a convention rather than advertised as a proof.
- **Concatenative composition** (Forth) was studied and its *joy* kept while its *mechanism* was dropped. The joy is four separable things: no naming fatigue for intermediates, left-to-right reading order, small single-purpose words, and immediacy. The stack is merely how Forth obtains them, and is the one part that taxes the reader. Nim's UFCS delivers all four with the stack depth pinned at exactly one — `text.trim().split(",").map(parseInt).sum()` needs no `dup` or `swap` because only one value is ever in play.

What replaces them is smaller and more useful: a **closed vocabulary of ~20 structural verbs** (`get`, `set`, `adjust`, `add`, `remove`, `has`, `find`, `list`, `open`, `close`, `read`, `write`, `start`, `stop`, `send`, `receive`, `wait`, `count`, `clear`, `copy`) with three unbreakable conventions — fixed argument order (target, locator, value, options last), absence returns `Option` while failure raises, and every raising verb has a `try`-prefixed sibling — plus **nine flat protocols** (`Gettable`, `Settable`, `Collection`, `Resource`, `Streamable`, `Lifecycle`, `Adjustable`, `Messenger`, `Waitable`) expressed as Nim `concept`s.

**This is primarily a maintainability mechanism, not an ergonomic one.** It caps how much new surface each battery can introduce, and it supplies an inclusion test with teeth: a module that needs fifteen novel verbs to describe itself is telling you it belongs in the extended ecosystem, not the standard library. It also removes real duplication — implementing `list` alone confers `isEmpty`/`first`/`contains`/`toSeq`/`each` written once for the whole library, and generic algorithms like `retry(resource, attempts, delay)` are written once instead of being reinvented per module (`embedded-sensor-node`'s I2C bus-error retry and `process-supervisor`'s restart backoff were independently hand-rolled in earlier rounds).

### Pilot scope and results

26 of 65 modules are translated — the full `core` and `alloc` tiers — each as a sibling `API.nim.md` beside the original `API.md` (the Rust version stays as the record of the design reasoning). The remaining 39 modules across `sys`, `std`, and `platform` are not yet translated.

Renames that carried the most weight:

| Rust | Nim | Why |
|---|---|---|
| `MaybeUninit<T>` | `Unfilled[T]` | the "prove you initialized it" ceremony becomes the library's ordinary absence idiom |
| `trailing_zeros` | `lowestSetBit: Option[Index]` | the old name described the implementation and returned bit-width as a "none" sentinel |
| `FnvHasher` / `SipHasher13` | `FastHash` / `SafeHash` | the type name now answers the only question a caller has |
| `read_volatile` / `write_volatile` | `readDevice` / `writeDevice` | "volatile" says nothing about why; "device" says exactly when |
| `Display` / `Debug` | `Showable` / `Inspectable` (`show`/`inspect`) | Ruby's words; still keeps `secrets-vault`'s property that a missing `show` makes `echo password` a compile error |
| `Vec<T>` / `HashMap` / `VecDeque` / `LinkedList` | `List[T]` / `Table` / `Ring[T]` / `Chain[T]` | Nim's own familiar vocabulary; zero new words for a Nim reader |
| `Rc<T>` / `Weak<T>` | `Shared[T]` / `Watcher[T]` | names the property, not the implementation |
| `entry(k).or_insert(v)` | `getOrSet(t, k, v)` | Rust's `Entry` type dance collapses into one vocabulary compound |
| `checked_add` / `saturating_add` / `wrapping_add` | `tryAdd` / `addClamped` / `addWrapped` | the `try` prefix now carries the failure-mode signal library-wide |

Three findings that changed the design rather than just its spelling:

1. **`Result<T, E>` disappears entirely.** Nim raises, so PROTOCOLS' "failure raises, `try`-prefix opts out" rule absorbs the whole second carrier. `core.error` gains a `Failure` type plus an `attempt` template that generates every `tryX` sibling in one line. This rippled through all 26 modules — and it resolved, rather than dodged, the Rust design's own open complaint that fallible `push` was ceremony at every call site.
2. **The allocator question resolved cleanly by splitting it in two.** Nim's ARC/ORC decides *when* memory is released; the `Memory` handle decides *where it came from*. They never conflict because they answer different questions. Every collection carries its `Memory` in a field with `=destroy`/`=sink` hooks returning bytes to that same allocator — so you get ordinary scope-based cleanup over any allocator, with no `defer` and no manual frees. The easy case (`newList[int]()`) is invisible; the explicit case (`newList[int](memory = pool)`) is one trailing named argument; and on freestanding targets `defaultMemory()` is a **compile error**, so `embedded-sensor-node` literally cannot compile a call that would touch an unmapped heap.
3. **Nim's closure iterators allocate**, which `core` forbids — so `core.iter`'s adapters became *inline* iterators that fuse into the surrounding `for` loop. Same machine code as Rust's adapter structs, but an adapter chain cannot be stored in a variable or returned from a proc. That is the single biggest structural divergence from the Rust original, and it is a real constraint, not a stylistic choice.

### Completion: all 65 modules translated

The pilot was extended to the full library. Every module now has an `API.nim.md` beside its `API.md`. The two predictions recorded before the `sys`/`std`/`platform` pass were checked rather than rationalized, and both produced more useful answers than a simple pass/fail:

**Prediction 1 — `Messenger` may not cover broadcast: right about the protocol, wrong about the examples, and therefore nothing was added.** `Messenger` genuinely cannot express one-to-many delivery. But neither motivating case needed it: a scope's cancellation reaching every task at once turned out to be `Waitable` (many tasks `wait`, one `stop` releases them all), and `load-tester`'s connection pool is `open`/`close` on a `Resource`. No module in the library demanded `publish`/`subscribe`, so per the contract's rule 6, no `Broadcaster` protocol exists. Identifying a real limit whose examples then dissolve is the best available outcome — the gap is documented, and speculative surface was still avoided.

**Prediction 2 — `std.crypto` strains hardest: confirmed, worse than predicted, and the guessed remedy was wrong.** The module introduced **fifteen domain verbs**, which is exactly the count the maintainability contract names as evidence a module belongs in the extended ecosystem. It stays in `std` on the stated escape clause (each is one universally understood word obeying the argument-order rule, so shape stays guessable even when meaning needs docs). But the predicted "thin `Resource` shell" never materialized — nothing in crypto opens or closes. What appeared instead was `Streamable` on `Digest` and `Collection` on `CertStore`, both incidental, neither on the key types. **`Key` is the deliberate hole**: no `get`, no `show`, no `$`, so `echo key` does not compile. The vocabulary being refused where obeying it would be dangerous is the system working, not failing.

**Post-completion note (Extension round 4).** The five modules added after this "all 65 translated" milestone (`sys.window`, `sys.audio`, `std.db`, `core.geom`, `platform.watchdog`) are `API.nim.md`-only, no `API.md` — matching how every `sys`/`std`/`platform` module here already works, but a first for `core`/`alloc`, where `core.geom` is the one module without the Rust-flavored design-reasoning half its tier-mates all have. Named in the round-4 section above rather than left as a silent inconsistency.

**A third translation, `API.tuck.md` — real, compiler-verified Tuck.** Seven modules (`core.geom`, `std.perf`, `sys.window`, `sys.audio`, `platform.watchdog`, `std.db`, `std.queue`) now have a third sibling file, each with real Tuck code checked against `./tuck ch` in the scratchpad before being written down — see `TUCK-TRANSLATION.md` for the shared findings (the `pending` mechanism, no operator overloading, value semantics forcing return-not-mutate) and each module's own file for what's specific to it. Two shapes were used, per direct guidance: freeform `pending:` functions for stateless modules (`core.geom`, `std.perf`), and `actor` singletons for genuinely stateful, OS-resource-owning services (the other five) — with the actor reply-synchronicity question left explicitly open rather than resolved unilaterally, since it needs its own design session. `std.db` and `std.queue` surfaced the sharpest structural tension: an actor is one instance per declared *type*, which doesn't fit either module's real need for multiple independent instances (several connections, several queues) — flagged prominently in both files rather than folded into the general open-questions list.

### What the full translation found

- **`sys.io`'s `Streamable` framing replaced Go's Reader/Writer cleanly.** Files, sockets, child-process pipes and `alloc.string`'s `Text` all plug in identically with no adapter code — the same claim the original report made for `io.Reader`, now carried by a protocol shared with the rest of the library rather than a bespoke pair of interfaces.
- **The `try` convention earned its keep in an unexpected place.** Nim ISRs must be declared `{.raises: [].}`, so inside `platform.interrupt`'s `onInterrupt` handlers *no raising verb is callable at all* — the `try`-prefixed siblings become the only usable half of the library, enforced by the compiler rather than by review. That is the strongest justification the convention has earned anywhere in the project.
- **Closures allocate, so every bare-metal callback is `{.nimcall.}`** — `platform.rtos` task bodies and interrupt hooks are function pointers that cannot capture. State reaches a task only through a `Queue`, a `Mutex[T]`, or a module-level `var`, and the compiler says so instead of the documentation.
- **Compile-time devicetree turned out freer than expected.** The `.dts` parser runs in Nim's compiler VM via `staticRead`, so it may use `seq`, `string` and recursion — the no-`seq` rule constrains *emitted* code, not the code that emits it. A failed claim on a devicetree-declared pin becomes a **compile** error rather than a runtime `none`.
- **`std.serde-derive` is the one place the Nim version is plainly better than the Rust original** rather than merely equivalent: Nim macros read the typed AST in the same file, so there is no build script, no separate derive crate, and no procedural-macro compilation step.
- **15 of 65 modules (23%) declare "none of the nine" protocols.** That ratio is worth stating plainly — the vocabulary covers containers and resources well and has nothing useful to say about arithmetic, cryptography, signal processing, or code generation. A design claiming 100% coverage would be forcing it.

Two further vocabulary gaps surfaced and were documented rather than patched: `Collection` splits cleanly into read-only and mutable halves (fixed-size views implement only `list`/`count`), and `Gettable`/`Settable` are used *without a locator* by the several types that hold exactly one value. Both are recorded per-module as honest partial implementations, on the principle that a `ReadOnlyCollection` sibling adds more to learn than it removes until a third of the library actually needs it enforced.

## How to read this project

Start with `REPORT.md` for the philosophy and the tiered architecture, then `PROTOCOLS.md` for the verb vocabulary and protocol set that governs the API surface (it supersedes the report's Design Principle 3). Modules in the `core` and `alloc` tiers have both an `API.md` (Rust-flavored, the design-reasoning record) and an `API.nim.md` (idiomatic Nim, the intended shape) — read the Nim one for what the library actually looks like to use. Then either browse by module (`modules/<tier>/<name>/API.md` — each is self-contained) or by application (`apps/<name>/APP.md`, which lists every module it exercises and why). The "Findings" section above is the fastest path to what's actually new here versus what was already decided in the report: eight concrete design changes and one deliberate removal (`alloc.list`), each traceable to one line of one application's stated requirement.
