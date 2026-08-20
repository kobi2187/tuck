# Toward a Coherent Standard Library: A Comparative Study of Mature Languages and Embedded Toolkits, with a Unified Design Proposal

*Prepared August 2026*

## 0. Framing and Method

The goal of this report is stated plainly by the brief: research the standard libraries (and, for systems/embedded languages, the auxiliary toolkits that stand in for a stdlib) of mature, high-level languages; compare them; and use that comparison to design something better — a single, tiered, internally consistent module set that could plausibly serve everything from a bare-metal interrupt handler to a web server, without becoming either a kitchen sink or an empty shell that pushes everything onto third parties.

Three questions organize the whole exercise, because "standard library" means different things at different altitudes:

1. What does the language ship in the box, with zero external dependencies?
2. Where does the language draw the line between "standard" and "ecosystem," and is that line drawn consistently?
3. What happens when there is no OS underneath you — no heap, sometimes no allocator at all? This is where embedded toolkits (Zephyr, FreeRTOS, CMSIS, embedded-hal, newlib/picolibc, Arduino) take over from language stdlibs, and comparing them matters just as much as comparing `import` statements.

Languages surveyed: Python, Ruby, JavaScript/Node.js, Java, C#/.NET, Kotlin, Swift, Go, Rust, C/C++ (STL + POSIX), Zig, Nim, D, and Ada/SPARK. Embedded/systems toolkits surveyed: Zephyr RTOS, FreeRTOS, CMSIS, Arduino core, embedded-hal/Embassy (Rust), and newlib/picolibc.

---

## Part I — Comparative Survey

### 1.1 Dynamic, "batteries-included" languages

**Python.** The stdlib is organized into 23 documented categories (Text Processing, Binary Data, Data Types, Numeric/Math, Functional Programming, File/Directory Access, Data Persistence, Compression/Archiving, File Formats, Cryptographic Services, Generic OS Services, Concurrent Execution, Networking/IPC, Internet Data Handling, Internet Protocols, Structured Markup, Development Tools, Debugging/Profiling, Runtime Services, Importing, Language Services, GUI-with-Tk, Packaging). This breadth is Python's signature strength: `json`, `sqlite3`, `unittest`, `asyncio`, `dataclasses`, `pathlib`, `venv` are all present with no install step. The cost is inconsistency of taste and pace — `urllib` is widely considered clunky next to third-party `requests`; `datetime` predates `zoneinfo` by decades and both now coexist; `unittest`'s xUnit style sits next to the more idiomatic `pytest` that almost everyone actually uses. Python's stdlib is a museum of eras: elegant recent additions (`pathlib`, `dataclasses`, structural pattern matching support) sit beside modules whose APIs no one would design today. Recent trend: some modules are being "degraded" out of the stdlib entirely (PEP 594 removed a slew of legacy modules in 3.13) — a tacit admission that batteries-included doesn't scale indefinitely.

**Ruby.** Smaller and more elegant in its core (`Enumerable`/`Comparable` mixins are a genuinely superior composability model — implement `<=>` or `each` once and get sorting, min/max, `map`, `select`, `all?` for free), but Ruby has been deliberately shrinking its stdlib ("stdlib gemification") — `net-smtp`, `net-ftp`, and others moved out to gems bundled-but-not-core. This is Ruby admitting the same lesson Python is learning: default-bundled and default-maintained are different promises, and conflating them creates security-patching burden for things few people use.

**JavaScript / Node.js.** The most fragmented case in the survey: there is a language-level stdlib (ECMAScript builtins — `Array`, `Map`, `Set`, `Promise`, `Intl`, `TypedArray`) and then *three different* runtime-level standard libraries that overlap but don't match — Node's core modules (`fs`, `http`, `crypto`, `stream`, `child_process`), the browser's Web APIs (`fetch`, DOM, `WebSocket`, Web Workers), and newer runtimes (Deno, Bun) that ship their own "batteries" (Bun bundles a native SQLite driver and password hashing in its runtime stdlib specifically because Node never did). The lesson from JS is negative but important: without one canonical stdlib, every runtime reinvents the same 20 modules slightly differently, and portability becomes a library problem (`isomorphic-fetch`, polyfills) rather than a language problem.

### 1.2 Managed / VM languages

**Java.** `java.util.concurrent`, the Streams API, and `java.time` (JSR-310) are widely regarded as best-in-class designs — `java.time` in particular (Instant vs. LocalDate vs. ZonedDateTime as genuinely distinct types) is the reference point this report's proposal borrows most directly from. Java's weaknesses are legacy baggage it cannot remove (old `Date`/`Calendar` still ship alongside `java.time`) and until recently a real gap in native interop, closed only in the last few years by the Foreign Function & Memory API (Project Panama) and the incubating Vector API for SIMD.

**C# / .NET.** The Base Class Library is arguably the most *consistent* of the managed stdlibs — naming conventions, exception hierarchies, and async patterns (`Task`/`async`/`await`) are applied uniformly across the entire surface, because Microsoft controls both language and library evolution in lockstep. LINQ is a genuine differentiator: declarative query syntax works uniformly over in-memory collections, XML, and (via providers) databases. `Span<T>`/`Memory<T>` show a managed language successfully retrofitting zero-allocation, systems-style APIs onto a GC'd runtime — a pattern worth stealing.

**Kotlin.** Deliberately thin `kotlin-stdlib` (extension functions over Java's collections, scope functions, null-safety helpers) plus a constellation of official-but-separate `kotlinx.*` libraries: `kotlinx.coroutines`, `kotlinx.serialization`, `kotlinx.datetime`. This is the same "small core + curated extended layer" strategy Rust uses, applied to a managed language — and it lets Kotlin move fast on coroutines/serialization without waiting on JVM or Kotlin-language release cadence.

**Swift.** Historically split awkwardly between a genuinely minimal core standard library (collections, `Optional`, protocols like `Sequence`/`Collection`, string handling) and Foundation (dates, `URL`, JSON, networking primitives, `NSObject`-derived types) which for years was an Objective-C bridge with different behavior per platform. Swift is actively rewriting Foundation in pure Swift (`swift-foundation`) precisely to fix that inconsistency — a live example of a language paying down stdlib-fragmentation debt.

### 1.3 Systems languages

**Go.** The strongest "coherent and elegant" case in this whole survey, and it shows in the design choices below. Small orthogonal interfaces (`io.Reader`/`io.Writer` — two one-method interfaces that compose across files, network sockets, compressors, and buffers with zero special-casing) are Go's biggest single idea. `net/http` ships a production-capable client *and* server in the box, unlike almost every other language here. `context.Context` threads cancellation and deadlines through call graphs uniformly. `testing` includes a benchmark and fuzz runner with no external framework. `errors.Is`/`errors.As` plus `%w` wrapping standardized error-chain inspection late (Go 1.13) but did it well. Weaknesses: generics arrived very late (1.18), so `sort`, `container/list` and friends predate them and feel dated next to the newer `slices`/`maps` packages; the stdlib is also unusually reluctant to add anything (no first-class stdlib GUI, no ORM, deliberately).

**Rust.** The cleanest tiered architecture in the survey and the direct model for the proposal's layering: `core` (no allocator, no OS — usable on bare metal), `alloc` (adds heap-based collections once you provide a global allocator), `std` (adds OS integration — files, threads, networking, time). Crucially, Rust keeps `std` deliberately thin for things that change fast or have legitimately competing designs — no stdlib regex, no stdlib HTTP client, no stdlib serialization, no stdlib `rand`. Those live in a small number of "de facto standard" crates (`regex`, `serde`, `rand`, `tokio`) that are not officially part of std but are treated as such by convention and by rust-lang team overlap. This is the opposite bet from Go: minimize the core, trust a curated ecosystem for the rest. Both bets work; they optimize for different things (Go optimizes for zero-dependency deployability, Rust for being able to fix a design mistake in `serde` without a language release).

**C / C++.** C's stdlib (`libc`) is minimal by 1970s necessity and remains the substrate everything else (including several "systems" languages above) links against. C++'s STL added containers, iterators, and — since C++20 — ranges, concepts, and `<format>`, closing much of the gap with newer languages, but two gaps are structurally important for this report: there has never been a standardized networking API (sockets are still whatever the OS gives you, unlike Go, Rust, Python, or Java), and memory safety is opt-in via disciplined use of smart pointers rather than enforced. POSIX (not part of either language standard, but the de facto contract every Unix systems program relies on) fills the OS-services gap — `unistd.h`, `pthread.h`, `sys/socket.h`, `dirent.h`, `signal.h` — and is worth treating as its own "stdlib" layer in the comparison because Go's `os`/`net`/`sys` packages and Rust's `std::os::unix` are both thin wrappers over exactly this surface.

**Zig.** The most radically explicit stdlib in the survey. Design rule, stated in Zig's own docs: no hidden control flow, no hidden allocations, no preprocessor, no macros. Every function that needs memory takes an `Allocator` parameter explicitly — callers choose a general-purpose allocator, an arena, a fixed buffer, or a page allocator, and the same code works unmodified on a hosted OS or on bare metal, because "needs memory" and "needs an OS" are decoupled. `std.crypto` is unusually complete for a young language (AES, ChaCha20, SHA-2/3, BLAKE2/3, Ed25519, X25519, Argon2) and lives in the language itself rather than being an OpenSSL wrapper. This single-attribute idea — allocator-as-parameter, everywhere, no exceptions — is the most important thing this report borrows for the embedded-facing tiers of the proposal.

**Nim.** Explicitly self-categorizes its stdlib into *pure* (no external binary dependency — `tables`, `strutils`, `algorithm`, `asyncdispatch`, `json`), *impure* (links a system library — `re`/`nre` via PCRE, `db_sqlite`), and *wrappers* (thin bindings to OS or C libraries — POSIX, Windows API, OpenSSL). Publishing that taxonomy in the documentation itself is a small but genuinely good idea: a user can tell at a glance whether a module changes their binary's dependency footprint, something no other surveyed language states this explicitly.

**D (Phobos).** Ranges plus Uniform Function Call Syntax make Phobos read like fluent method chains (`arr.filter!(x => x > 0).map!(x => x * 2).array`) without needing methods actually defined on the type — one of the more elegant composability stories here, similar in spirit to Rust iterators but arguably more ergonomic syntactically. `std.experimental.allocator` offers Zig-style pluggable allocators without making them mandatory. Weak spot: networking and async were never fully solidified in Phobos itself; the community's answer (`vibe.d`) lives outside std, which is the same "should this be in std or not" tension every other language here has resolved differently.

**Ada / SPARK.** The outlier that matters most for a "systems, especially embedded" report: Ada's stdlib (`Ada.Text_IO`, `Ada.Containers` — generic Vectors/Lists/Maps/Sets, `Ada.Strings`, `Ada.Numerics`, `Ada.Calendar`/`Ada.Real_Time`, `Ada.Streams`, `Ada.Synchronous_Task_Control`) is unremarkable on its own, but Ada is designed with tasking (concurrency), real-time scheduling, and formal contracts (preconditions, postconditions, type invariants) as *language* features rather than library add-ons, and the SPARK subset allows whole programs to be formally proven free of runtime errors. No other language surveyed treats verifiability as a stdlib-adjacent concern; this report's proposal borrows the idea (contracts as an opt-in attribute on any function, not just a `assert`-style library call) rather than the syntax.

### 1.4 Embedded and systems toolkits (the "stdlib" when there is no OS)

**Zephyr RTOS.** The most "batteries-included" of the embedded options, closer in philosophy to Go or Python than to bare-metal C. Ships a real kernel (preemptive/cooperative scheduling, EDF option, semaphores, mutexes, message queues), a proper device-driver model driven by Devicetree, a native networking stack with BSD-socket compatibility and LwM2M, a full Bluetooth LE + mesh stack, a virtual filesystem layer over ext2/FatFS/LittleFS, a settings subsystem for persisted key-value config, structured multi-backend logging, and an interactive shell — all as first-party, in-tree subsystems rather than bolted-on libraries. It is the strongest evidence in this whole survey that "batteries included" and "runs on a Cortex-M0 with 64 KB of RAM" are not mutually exclusive if the architecture is designed for it from day one.

**FreeRTOS.** The opposite bet: a genuinely minimal kernel — tasks, queues, semaphores/mutexes, software timers, event groups, stream/message buffers, and a choice of five heap allocation strategies (`heap_1` through `heap_5`, trading determinism for flexibility) — with everything else (TCP/IP via FreeRTOS+TCP, a FAT filesystem, mbedTLS-based security for AWS IoT integrations) as separate, optional add-on libraries you opt into individually. This mirrors the Rust-vs-Go split one layer down the stack: Zephyr is Go, FreeRTOS is Rust's `core`.

**CMSIS (Cortex Microcontroller Software Interface Standard).** ARM's answer to the portability problem one layer *below* the RTOS: CMSIS-Core standardizes register access across every Cortex-M vendor, CMSIS-Driver standardizes peripheral driver APIs so the same driver call works across silicon vendors, CMSIS-RTOS defines an RTOS-agnostic API that FreeRTOS, Zephyr, and other kernels all implement so application code doesn't have to pick a kernel to be portable, and — notably — CMSIS-DSP ships a genuinely mature, hand-optimized signal-processing library (FFTs, FIR/IIR filters, matrix math, statistics) as a *standard*, silicon-vendor-shipped component. No general-purpose language stdlib in this survey ships anything comparable to CMSIS-DSP; it's a strong argument for treating DSP as a first-class optional stdlib category for embedded targets rather than leaving it to fragmented per-vendor libraries.

**embedded-hal / Embassy (Rust).** Not an official part of Rust's std — a community-designed, ecosystem-blessed set of traits (`OutputPin`, `SpiBus`, `I2c`, `Uart`, `Pwm`, `DelayNs`, …) that any microcontroller HAL crate implements, so a driver written against `embedded-hal` (say, for an accelerometer) works unmodified on an STM32, an RP2040, or an ESP32 HAL, provided each implements the trait. Embassy adds an async runtime, executor, and timer/networking primitives that work in `no_std` — genuinely novel, since async I/O without an OS is a hard problem most languages don't attempt. The trait-abstraction-over-hardware pattern here is the single most reusable idea for the "platform" tier of this report's proposal.

**newlib / picolibc.** The embedded C library layer beneath almost everything above that isn't pure Rust or Zig: newlib is the traditional choice, providing a libc subset with a small set of syscall stubs (`_sbrk`, `_write`, `_read`, `_close`, …) a board-support package must implement to make `malloc`, `printf`, and `stdio` work at all. picolibc is its modern successor — smaller footprint, better reentrancy/thread-safety, merged ideas from `avr-libc` — and is displacing newlib as the default in current toolchains (Espressif's ESP-IDF switched its default libc from newlib to picolibc in 2026, the most concrete recent signal that this transition is now mainstream, not experimental). The pattern worth keeping — a small, explicit, must-implement syscall shim contract that lets higher-level I/O degrade gracefully instead of failing to link — is carried into the proposal below as `platform.libc-shim`.

**Arduino core.** Included because it is the most widely used "embedded stdlib" by raw user count, and its weaknesses are instructive. `Serial`, `Wire` (I2C), `SPI`, `Servo`, `EEPROM`, and simple `digitalWrite`/`analogRead` functions are extremely approachable for beginners, but the API is not designed for composability (no shared trait/interface layer akin to `embedded-hal` — most Arduino libraries are mutually incompatible black boxes), concurrency is a bare cooperative `loop()` with no formal task model, and there is no coherent story for allocators, error handling, or portability beyond "recompile for your board and hope." Arduino succeeds on friendliness and library-count, not on elegance or coherence — useful as a lower bound in this comparison.

Sources: [Python 3.14 stdlib index](https://docs.python.org/3/library/index.html) · [Zig standard library overview](https://ziglang.org/learn/overview/) · [Nim standard library](https://nim-lang.org/docs/lib.html) · [Phobos (D) standard library](https://dlang.org/phobos/) · [Zephyr Project introduction](https://docs.zephyrproject.org/latest/introduction/index.html) · [Espressif: ESP-IDF v6.0 switches default libc to picolibc](https://developer.espressif.com/blog/2026/04/esp-idf-6-default-libc-picolibc/) · [picolibc project](https://github.com/picolibc/picolibc) · [Swift Core Libraries](https://www.swift.org/documentation/core-libraries/) · [Future of Foundation — Swift.org](https://www.swift.org/blog/future-of-foundation/) · [Kotlin API references](https://kotlinlang.org/docs/api-references.html) · [Rust library architecture (core/alloc/std) — DeepWiki](https://deepwiki.com/rust-lang/rust/4.1-library-architecture-(core-alloc-std)) · [Ada standard library: containers — AdaCore learn](https://learn.adacore.com/labs/intro-to-ada/chapters/standard_library_containers.html) · [Awesome Ada / SPARK resources](https://github.com/ohenley/awesome-ada) · [Embassy (embedded async Rust)](https://embassy.dev/) · [Embedded Rust Book: no_std](https://docs.rust-embedded.org/book/intro/no-std.html)

---

## Part II — Cross-Cutting Analysis

### 2.1 Category coverage matrix

`✓✓` = in-box, mature, widely used · `✓` = in-box but limited/dated · `~` = works but via ecosystem/curated package, not core · `✗` = no real answer

| Category | Python | Go | Rust | Java | C#/.NET | Swift | C++ | Zig | Nim | D | Ada | Zephyr | FreeRTOS |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Collections/generics | ✓✓ | ✓✓ | ✓✓ | ✓✓ | ✓✓ | ✓✓ | ✓✓ | ✓ | ✓✓ | ✓✓ | ✓✓ | ✓ | ✗ |
| String/Unicode | ✓✓ | ✓✓ | ✓✓ | ✓✓ | ✓✓ | ✓✓ | ✓ | ✓ | ✓✓ | ✓✓ | ✓ | ✗ | ✗ |
| Date/time | ✓ | ✓✓ | ~ | ✓✓ | ✓✓ | ~ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Regex | ✓✓ | ✓✓ | ~ | ✓✓ | ✓✓ | ~ | ✓ | ✗ | ✓ (impure) | ✓ | ✗ | ✗ | ✗ |
| JSON/serialization | ✓✓ | ✓✓ | ~ | ~ | ✓✓ | ✓ | ✗ | ✓ | ✓✓ | ✓ | ✗ | ~ | ✗ |
| HTTP client | ✓✓ | ✓✓ | ~ | ✓✓ | ✓✓ | ~ | ✗ | ~ | ✓ | ~ | ✗ | ~ | ~ (add-on) |
| HTTP server | ~ | ✓✓ | ~ | ~ | ✓✓ | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | ✗ |
| Raw sockets/net | ✓✓ | ✓✓ | ✓✓ | ✓✓ | ✓✓ | ~ | ✗(POSIX) | ✓ | ✓ | ✓ | ~ | ✓✓ | ~ (add-on) |
| Crypto (hash/AEAD) | ✓✓ | ✓✓ | ~ | ✓✓ | ✓✓ | ~ | ✗ | ✓✓ | ✓ | ✓ | ✗ | ~ | ~ (add-on) |
| Concurrency (threads) | ✓ | ✓✓ | ✓✓ | ✓✓ | ✓✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓✓ | ✓✓ | ✓✓ |
| Async/structured concurrency | ✓✓ | ✓✓ (goroutines) | ~ (tokio) | ✓ | ✓✓ | ✓✓ | ~ (coroutines primitive) | ✗ | ✓ | ✗ | ✗ | ✗ | ✗ |
| Testing framework | ✓ | ✓✓ | ✓✓ | ~ | ✓✓ | ✓✓ | ✗ | ✓✓ | ✓ | ✓ | ~ | ✓ | ✗ |
| Filesystem | ✓✓ | ✓✓ | ✓✓ | ✓✓ | ✓✓ | ✓ | ✓ (C++17) | ✓ | ✓✓ | ✓✓ | ✓✓ | ✓✓ (VFS) | ~ (add-on) |
| Allocator control | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | ✓ | ✓✓ | ✓ | ✓ | ✓ | ✓ | ✓✓ (heap_1-5) |
| no_std / freestanding | ✗ | ✗ | ✓✓ | ✗ | ✗ | ✗ | ✓ | ✓✓ | ✓ | ✓ | ✓✓ | n/a | n/a |
| GPIO/peripheral HAL | ✗ | ✗ | ~ (embedded-hal) | ✗ | ✗ | ✗ | ✗ | ~ | ✗ | ✗ | ~ | ✓✓ | ✗ |
| RTOS primitives | ✗ | ✗ | ~ (embassy) | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓✓ (tasking) | ✓✓ | ✓✓ |
| DSP/signal processing | ~ | ✗ | ~ | ~ | ~ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ (CMSIS-DSP instead) |
| Formal verification hooks | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓✓ (SPARK) | ✗ | ✗ |

The matrix makes the gap visible: no single ecosystem covers every row well. Zephyr/FreeRTOS/CMSIS dominate the embedded-specific rows and are nearly blank on the application-level rows; Python/Go/Java/.NET dominate application-level rows and are blank on the embedded rows; Rust and Zig are the only two languages with a real answer to "no_std" *and* a plausible (if thin) answer to application-level concerns. That straddling is exactly why both are used as the primary architectural models below.

### 2.2 Two philosophies, both defensible

Every stdlib in this survey ultimately picks one of two bets:

**Batteries included** (Python, Go, Java, .NET, Zephyr): ship a wide, curated set of modules in the box, version and patch them with the language/runtime, and accept that some modules will age worse than others and that the maintainers' taste becomes a permanent constraint. Optimizes for zero-dependency deployability and a consistent "one obvious way" experience.

**Minimal core + curated periphery** (Rust, Kotlin, Swift, FreeRTOS, embedded-hal): ship a small, slow-changing, extremely stable core, and push fast-moving or contested-design areas (serialization, async runtimes, regex, DSP) to a small number of officially-blessed but independently-versioned packages. Optimizes for being able to fix a bad design without waiting for a language release, at the cost of needing a package manager and a healthy ecosystem to feel "complete."

Neither philosophy is strictly better; the evidence in this survey is that the strongest ecosystems (Rust, Go, Zephyr) pick one deliberately and apply it *consistently*, while the weakest moments in otherwise-good ecosystems (Python's `urllib`, C++'s absent sockets standard, Swift's old Foundation) come from picking inconsistently — bundling some things that should have been left external (or vice versa) and then being stuck with the choice for a decade.

### 2.3 Ideas worth stealing, named explicitly

- Go's `io.Reader`/`io.Writer`: two one-method interfaces that make every stream-like thing in the stdlib composable with every other stream-like thing, with zero adapter code.
- Rust's `core`/`alloc`/`std` layering: the single cleanest solution in the survey to "the same language should run on a server and on a microcontroller."
- Zig's mandatory explicit allocator parameter: makes memory behavior an explicit, auditable part of every function signature instead of a hidden global.
- Java's `java.time` (Instant/LocalDate/ZonedDateTime as genuinely distinct, non-interchangeable types): the best-designed date/time API surveyed, by consensus.
- Go's `context.Context`: cancellation and deadlines as a value threaded explicitly through call graphs, rather than thread-local magic or silent leaks.
- Nim's published pure/impure/wrapper taxonomy: tells a user, from the module name's category alone, whether importing it changes their binary's dependency footprint.
- D's ranges + UFCS: fluent, composable data-pipeline syntax without requiring methods to be defined on the type being operated on.
- Ada/SPARK's contracts as a language-level (not library-level) concept: preconditions, postconditions, and invariants that a compiler or verifier can check, not just runtime `assert`.
- embedded-hal's trait-based hardware abstraction: driver crates that are portable across silicon vendors because they're written against a shared trait set, not a specific chip's headers.
- CMSIS-DSP and CMSIS-RTOS: proof that "standardized" and "vendor-shipped, hand-optimized, RTOS-agnostic" are compatible for numerically-intensive and kernel-adjacent APIs respectively.
- picolibc's syscall-shim contract: a small, explicit, must-implement set of primitives that lets high-level I/O degrade gracefully on freestanding targets instead of failing to link at all.

---

## Part III — Design Principles for the Proposal

Five principles, derived directly from Part II, govern every module decision below:

1. **Layer by dependency, not by topic.** A module belongs in the tier defined by the weakest environment it can run in: no allocator and no OS (`core`), allocator but no OS (`alloc`), full OS (`sys`/`std`), or "needs a curated, independently-versioned package because its design isn't settled" (extended ecosystem). This is Rust's layering generalized and made the organizing principle for the whole tree, not just an implementation detail.
2. **No hidden allocation, ever, below the `std` tier.** Anything in `core` or `alloc` that needs memory takes an allocator explicitly (Zig's rule). This is what makes the *same* module usable on a server and on a Cortex-M0.
3. **Small, composable interfaces beat large, concrete classes.** Model every I/O-like or comparison-like capability as a minimal trait/interface (Go's `io.Reader`, Rust's `Iterator`), so unrelated modules compose without adapter code.
4. **One coherent idiom per cross-cutting concern.** Error handling, cancellation, formatting, and serialization each get exactly one first-class mechanism used uniformly across every module (no module gets to invent its own error convention) — this is the single biggest thing separating "coherent" stdlibs (Go, Rust, .NET) from "archaeological" ones (Python, C++).
5. **Batteries included at the application tier, radically minimal below it.** The top tier should feel like Python or Go — JSON, HTTP, regex, crypto, testing, all present, no install step. The bottom two tiers should feel like Zig or Rust `core` — nothing hidden, nothing assumed, runs on bare metal.

---

## Part IV — The Proposed Unified Standard Library

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Tier 4 — platform   (embedded/systems toolkit; opt-in)       │
│   hal · rtos · interrupt · devicetree · boot · power ·       │
│   dsp · net.lowpower · libc-shim                              │
├─────────────────────────────────────────────────────────────┤
│ Tier 3 — std        (hosted OS + "batteries included")       │
│   async · testing · log · regex · encoding · crypto ·        │
│   compress · archive · net.http · net.tls · chrono · math ·  │
│   random · cli · reflect · serde-derive · i18n               │
├─────────────────────────────────────────────────────────────┤
│ Tier 2 — sys/os      (hosted OS, minimal wrapping)            │
│   io · fs · env · process · thread · sync · time · net ·     │
│   mmap · dynload · ffi · signal                                │
├─────────────────────────────────────────────────────────────┤
│ Tier 1 — alloc       (heap present, no OS required)           │
│   allocator · vec · string · map/set · deque/list ·          │
│   box/rc · fmt                                                 │
├─────────────────────────────────────────────────────────────┤
│ Tier 0 — core        (freestanding: no allocator, no OS)      │
│   types · slice/array · str · iter · cmp · convert · fmt ·   │
│   mem · ptr · atomic · sync.cell · error · simd · hash · num │
└─────────────────────────────────────────────────────────────┘
      ↑ every tier compiles and links independently of the ones above it
```

A program can depend on `core` alone and run with no linker except a memory layout (true bare metal); on `core` + `alloc` with nothing but a bump allocator (an interrupt handler that needs a scratch `Vec`); on everything through `sys` on an RTOS with a syscall shim (Tier 2 over Zephyr/FreeRTOS); or on the full stack on a hosted OS. `platform` is a sibling of `std`, not a child of it — an embedded target uses `core` + `alloc` + `platform`, skipping `sys`/`std` entirely, while a server uses `core` through `std` and never touches `platform`.

### Tier 0 — `core` (freestanding)

| Module | Answers |
|---|---|
| `core.types` | Primitives, `Option`/`Result` sum types, tuples, fixed-size arrays |
| `core.slice` / `core.array` | Bounds-checked views and iteration over contiguous memory |
| `core.str` | UTF-8 string-slice operations (no owned string — that's Tier 1) |
| `core.iter` | Lazy iterator adapters: `map`, `filter`, `fold`, `zip`, `take`, `chain` |
| `core.cmp` | `Eq`/`Ord`/`PartialOrd` — the single comparison mechanism used everywhere (Principle 4) |
| `core.convert` | `From`/`Into`/`TryFrom` — the single conversion mechanism used everywhere |
| `core.fmt` | `Display`/`Debug` traits; writes into any `core.io`-style sink with zero allocation |
| `core.mem` | `size_of`, `align_of`, `swap`, `MaybeUninit`, explicit (de)initialization |
| `core.ptr` | Raw pointer arithmetic and validity primitives, for the modules that need them |
| `core.atomic` | Atomic integers/pointers with explicit memory-ordering parameters |
| `core.sync.cell` | Single-threaded interior mutability (`Cell`/`RefCell`-equivalent) |
| `core.error` | The one error/panic/contract mechanism: `Result`-carried errors plus opt-in precondition/postcondition/invariant attributes (Ada/SPARK-inspired — checked at compile time where provable, at runtime otherwise) |
| `core.simd` | Portable fixed-width SIMD vector types and lane operations |
| `core.hash` | `Hash` trait plus a couple of no-allocation hash algorithms (FNV, SipHash core) |
| `core.num` | Checked/wrapping/saturating arithmetic, endianness conversions |

### Tier 1 — `alloc` (heap, no OS)

| Module | Answers |
|---|---|
| `alloc.allocator` | The `Allocator` interface plus built-in strategies (arena/bump, pool, fixed-buffer, general-purpose) — every module above this line that allocates takes one explicitly (Principle 2) |
| `alloc.vec` | Growable contiguous array |
| `alloc.string` | Owned UTF-8 string and string builder, built on `core.str` |
| `alloc.map` / `alloc.set` | Hash-based and ordered (tree-based) variants, one shared interface |
| `alloc.deque` / `alloc.list` | Ring buffer and linked list for the (rarer) cases arrays don't fit |
| `alloc.box` / `alloc.rc` | Unique and reference-counted (+ weak) heap ownership |
| `alloc.fmt` | Allocating convenience layer over `core.fmt` (format-to-string) |

### Tier 2 — `sys` (hosted OS, thin wrapping — this is where "systems programming" happens in full)

| Module | Answers |
|---|---|
| `sys.io` | `Reader`/`Writer`/`Seeker` — minimal composable interfaces (Go `io`-inspired), buffered wrappers |
| `sys.fs` | Files, directories, paths, permissions, change notification |
| `sys.env` | Args, environment variables, working directory |
| `sys.process` | Spawn/exec, pipes, exit codes, process groups |
| `sys.thread` | Native OS threads, thread-local storage |
| `sys.sync` | Mutex, RwLock, condvar, mpsc/mpmc channels, barrier, once |
| `sys.time` | `Instant` (monotonic) strictly separate from `SystemTime` (wall clock) — conflating them is a recurring real-world bug source this design avoids by construction |
| `sys.net` | Raw TCP/UDP/Unix-domain sockets and DNS resolution (no HTTP here — that's Tier 3) |
| `sys.mmap` | Memory-mapped files and shared memory |
| `sys.dynload` | Dynamic library loading (`dlopen` equivalent) |
| `sys.ffi` | C ABI interop: extern declarations, calling-convention control, header ingestion |
| `sys.signal` | POSIX-style signal handling abstraction |

### Tier 3 — `std` (hosted OS, batteries included)

| Module | Answers |
|---|---|
| `std.async` | Structured concurrency: tasks, a cancellation/deadline-carrying context (Go `context`-inspired), `select`, timeouts |
| `std.testing` | In-box test/benchmark/fuzz runner and assertions — no external framework required (Go/Zig-inspired) |
| `std.log` | Structured, leveled logging facade |
| `std.regex` | Linear-time (RE2-style) engine — no catastrophic backtracking by construction |
| `std.encoding` | One `Codec` interface implemented uniformly by `json`, `toml`, `csv`, `base64/32/16`, and binary struct packing, so any type marshals to any format the same way |
| `std.crypto` | Hashing (SHA-2/3, BLAKE3), MACs, AEAD ciphers, X25519/Ed25519, constant-time comparisons, CSPRNG — implemented in-language (Zig `std.crypto`-inspired), not an OpenSSL wrapper |
| `std.compress` / `std.archive` | gzip/zlib/deflate/zstd; tar/zip |
| `std.net.http` | Production-capable client *and* server, in the box (Go `net/http`-inspired — deliberately not left to a third party) |
| `std.net.tls` | TLS wrapping any `sys.net` socket |
| `std.chrono` | Calendar dates, durations, timezones — modeled directly on `java.time`'s distinct-type design |
| `std.math` | Elementary functions, statistics, arbitrary-precision integers/rationals, and a decimal type for money (Python `decimal`-inspired) |
| `std.random` | Seedable PRNGs kept in a separate namespace from `std.crypto`'s CSPRNG, so the two can never be accidentally interchanged |
| `std.cli` | Argument parsing, terminal color/progress/prompt helpers |
| `std.reflect` | Opt-in, per-type runtime introspection — cost is visible and chosen, not ambient (contrast Java/C#, where reflection metadata cost is paid whether used or not) |
| `std.serde-derive` | Compile-time-generated encoding/reflection code for performance-sensitive paths (Rust `serde`-inspired), as an alternative to `std.reflect` |
| `std.i18n` | Unicode normalization, collation, locale-aware formatting |

`std.gui` is deliberately absent — every mature GUI toolkit surveyed (including Java's own Swing/AWT vs. modern alternatives) shows that UI design contests move faster than any language's release cycle can track; it belongs in the extended ecosystem, not std, and pretending otherwise is exactly the mistake Part II flags in weaker stdlibs.

### Tier 4 — `platform` (embedded/systems toolkit, sibling of `std`)

| Module | Answers |
|---|---|
| `platform.hal` | Trait-based peripheral abstraction — `Gpio`, `Spi`, `I2c`, `Uart`, `Adc`, `Pwm`, `Timer`, `Dma` (embedded-hal-inspired); silicon vendors implement the traits, driver code stays portable |
| `platform.rtos` | RTOS-agnostic task/queue/semaphore/mutex API (CMSIS-RTOS-inspired) implementable by FreeRTOS, Zephyr, or a bare async executor, so application code doesn't have to pick a kernel |
| `platform.interrupt` | Critical-section/interrupt-mask primitives, vector table registration |
| `platform.devicetree` | Declarative hardware description compiled into driver wiring (Zephyr-inspired) |
| `platform.boot` | Linker-script conventions, memory-region descriptors (flash/RAM/MMIO), reset handlers |
| `platform.power` | Sleep modes, clock-tree configuration, power domains |
| `platform.dsp` | FFT, FIR/IIR filters, matrix math (CMSIS-DSP-inspired) — standardized so it isn't reinvented per vendor, but optional since not every embedded target needs it |
| `platform.net.lowpower` | Optional hooks for 6LoWPAN/Thread/BLE mesh stacks (Zephyr-inspired) |
| `platform.libc-shim` | The small, explicit set of syscalls (`_sbrk`-equivalent write/read/clock stubs) a board-support package implements so `sys.io`/`sys.fs` degrade to "unsupported" gracefully instead of failing to link (newlib/picolibc-inspired) |

### Deliberately outside the standard library

GUI toolkits, ORMs and database drivers beyond the `sys`-level connection primitives, HTTP frameworks beyond the basic `std.net.http` server, ML/tensor libraries, and protocol-buffer/gRPC code generation are left to a curated (not core) extended ecosystem, versioned independently and recommended by the language's own documentation — the same resolution Rust reaches with crates.io and Go reaches with its `golang.org/x` packages. Per Principle 5 and the Part II analysis, these are exactly the categories where design taste is genuinely unsettled and release-cycle coupling to the language would ossify a bad decision for years.

---

## Part V — What This Gets Right (and Where It Would Actually Break)

**What it gets right, relative to every individual survey entry:** it is the only design in the comparison that has a real answer to *all* of section 2.1's rows simultaneously — no other single stdlib in the survey scores well on both `no_std`/allocator-control and HTTP-server/crypto/testing. It resolves the batteries-included-vs-minimal-core tension by making it a *tier boundary* rather than a single ecosystem-wide policy choice, so both bets are honored where they're each strongest (minimal at the bottom, generous at the top).

**Where it would actually strain in practice:** tier boundaries this clean are easy to draw on paper and hard to keep clean under real pressure — Swift's Foundation split and Zephyr's own layering show that "OS-optional" and "OS-required" code has a way of leaking into each other over a decade of contributions unless enforced by tooling, not just convention. `std.reflect` as opt-in-cost is a good idea that Java and C# also intended and then partially lost to ecosystem pressure (frameworks that assume reflection is always available). And the hardest real trade-off — how much of `platform.hal` a *language* stdlib should own versus leaving entirely to hardware vendors, the way embedded-hal does today as a community crate rather than part of Rust's own std — is a judgment call this report resolves one way (standardize the traits) that reasonable people, including Rust's own maintainers, have resolved the other way (leave it external) for defensible reasons: hardware evolves faster than language release cycles, and freezing a HAL trait set into an official stdlib risks the exact ossification Part II criticizes elsewhere.

---

## Conclusion

No stdlib surveyed here does everything well, but the reasons are legible once laid side by side: Python and Zephyr optimize for breadth-with-zero-install and pay for it in inconsistency across eras; Rust and FreeRTOS optimize for a small, stable, verifiable core and pay for it in needing a healthy external ecosystem to feel complete; Go earns its reputation for coherence specifically by picking the batteries-included bet and then applying it with unusual discipline (small interfaces, one error convention, one HTTP stack); Zig and embedded-hal show that "elegant" and "runs on bare metal" are compatible if allocation and hardware access are made explicit rather than assumed; and Ada/SPARK is the one entry that treats correctness itself, not just convenience, as a stdlib-adjacent concern. The proposal above is not a new idea so much as an argument that these are not actually in tension — that the batteries-included/minimal-core split which every language in this survey resolves once, globally, for its entire stdlib is better resolved *per tier*, so that the same coherent design serves an interrupt handler and a web server without either one compromising the other.
