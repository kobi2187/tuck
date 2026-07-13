# Tuck Stdlib: Essential Building Blocks (bottom layer)

Status: planning report, 2026-07-12. Companion to ROADMAP.md ("Stdlib v1
scope") and spec §4.8/§7. This is the lowest layer — the set later layers
(formatting, json, http, drivers, supervisors) build on. Domain lists only;
no Tuck signatures are proposed here (those come per-module, following the
std/fs.tuck pattern).

## Method

Union of the bottom layers of metal-capable and systems languages — C
(libc + freestanding), C++ (STL core), Rust (`core`/no_std and `std`), Zig
(intrinsics naming), Nim, Go — plus Erlang/Elixir (BEAM) for the
message-passing/binary side, and C# where it adds something unique. Tuck has
no reflection and no macros, so anything those languages build reflectively
is out; the embedded catalogue (atomics, barriers, MMIO, interrupts, fixed
buffers) is in.

Everything is filtered through Tuck's standing rules:

- fallible ⇒ `[io]` + declared error enum (`[error: FsError]`) + TuckResult;
  exceptions never escape the runtime (tuck_rt catches → `terr`).
- pure core is total — string/math/bit ops that cannot fail carry no wrapper.
- OS handles (files, sockets, processes) get resource kinds (spec §7.4).
- embedded set rides the effect markers: `no_alloc`, `irq_safe`, `unsafe`.

### Classification key (the point of this report)

| Class | Meaning |
|---|---|
| **extern (direct)** | Nim proc usable as-is behind an `extern:` sig |
| **extern (shim)** | Nim proc exists; tuck_rt wraps it (catch → `terr`, reshape to record) — the existing `readFile` pattern (tuck_rt.nim:148) |
| **write (rt)** | no usable Nim equivalent; new Nim code in tuck_rt (or `{.emit.}`/asm) |
| **write (prelude)** | pure Tuck, ships as std source on top of the language |

Status column: **std** = already in std/*.tuck · **rt** = type/proc already
in tuck_rt.nim · **new** = not started.

---

## 1. Prelude / result handling

Spec §4.8: "Handling combinators (`ifErr`, defaults) live in the standard
prelude, not in the language."

| Block | Precedent | Nim mapping | Class | Status |
|---|---|---|---|---|
| ok/err/absent predicates | Rust `Result::is_ok`, Elixir `:ok` tuples | — (TuckResult already has `ok`) | write (prelude) | rt (partial) |
| value-or-default | Rust `unwrap_or`, C# `GetValueOrDefault` | — | write (prelude) | new |
| error-branch helper (`ifErr`) | Rust `map_err`, Go `if err != nil` idiom | — | write (prelude) | new |
| absent→error / error→absent converters | Rust `ok_or`, `Option::ok` | — | write (prelude) | new |

## 2. Strings

`str` is UTF-8 text (Nim `string`). Pure ops, no wrappers except parsing.

| Block | Precedent | Nim mapping | Class | Status |
|---|---|---|---|---|
| length (bytes), rune count | Go `len`/`utf8.RuneCount`, Rust `len`/`chars` | `system.len`, `unicode.runeLen` | extern (direct) | new |
| concat, repeat | all | `system.&`, `strutils.repeat` | extern (direct) | new |
| slice / substring | all | `system.[]` (HSlice) | extern (direct) | new |
| search: contains / find / rfind | all | `strutils.contains`, `strutils.find`, `strutils.rfind` | extern (direct) | new |
| prefix / suffix tests | all | `strutils.startsWith`, `strutils.endsWith` | extern (direct) | new |
| split / join | all | `strutils.split`, `strutils.join` | extern (direct) | new |
| trim (both/left/right) | all | `strutils.strip` | extern (direct) | new |
| replace | all | `strutils.replace` | extern (direct) | new |
| case fold (ASCII + unicode) | all | `strutils.toLowerAscii`, `unicode.toLower` | extern (direct) | new |
| compare (ordinal, case-insensitive) | C `strcmp`, Nim `cmp` | `system.cmp`, `strutils.cmpIgnoreCase` | extern (direct) | new |
| parse int / uint / float — fallible | all; Rust `str::parse` | `strutils.parseInt`, `strutils.parseUInt`, `strutils.parseFloat` (raise → terr) | extern (shim) | new |
| int / uint / float → string | all (`$`, `to_string`) | `system.$` | extern (direct) | new (flagged missing in progress.md) |
| UTF-8 validate | Go `utf8.Valid`, Rust `from_utf8` | `unicode.validateUtf8` | extern (direct) | new |
| bytes ↔ string (no copy semantics decided later) | Go `[]byte(s)`, Erlang binaries | `system.cast`/copy via `copyMem` | extern (shim) | new |

Later layers that build on this: formatting/interpolation, regex, json.

## 3. Bytes & binaries

The `Seq[u8]` working set. Erlang's bit syntax is the precedent for
pack/unpack being *fundamental*, not a nicety.

| Block | Precedent | Nim mapping | Class | Status |
|---|---|---|---|---|
| fill / zero | C `memset` | `system.zeroMem` (+ fill loop) | extern (direct) | new |
| copy / move | C `memcpy`/`memmove` | `system.copyMem`, `system.moveMem` | extern (direct) | new |
| compare | C `memcmp` | `system.cmpMem` | extern (direct) | new |
| slice / view | Go slices, Rust `&[u8]` | `system.toOpenArray` (repr decision later) | extern (shim) | new |
| endian load/store u16/u32/u64 BE/LE | Rust `to_be_bytes`, Go `binary.BigEndian` | `std/endians.swapEndian16/32/64` are pointer-based and clumsy | write (rt) | new |
| struct-ish pack/unpack of scalars at offsets | Erlang bit syntax, C casts | — (offsetof exists as builtin §8.2) | write (rt) | new |

## 4. Bit intrinsics

The C/C++/Rust-`core`/Zig set. Pure, `no_alloc`, embedded-critical.

| Block | Precedent | Nim mapping | Class | Status |
|---|---|---|---|---|
| popcount | all metal langs | `bitops.countSetBits` | extern (direct) | new |
| count leading / trailing zeros | all metal langs | `bitops.countLeadingZeroBits`, `bitops.countTrailingZeroBits` | extern (direct) | new |
| rotate left / right | all metal langs | `bitops.rotateLeftBits`, `bitops.rotateRightBits` | extern (direct) | new |
| bit reverse | Zig `@bitReverse` | `bitops.reverseBits` | extern (direct) | new |
| byte swap | C `bswap`, Rust `swap_bytes` | no clean stdlib proc (endians is pointer-based) | write (rt) | new |
| mask/test/set/clear/flip bit | C idioms, Nim bitops | `bitops.testBit`, `bitops.setBit`, `bitops.clearBit`, `bitops.flipBit` | extern (direct) | new |
| next power of two / align up-down | Zig `@alignForward`, Linux macros | `math.nextPowerOfTwo`; align helpers | extern (direct) + write (rt) | new |

## 5. Integer semantics

Backs the spec §4.6 type attrs `[saturating]`, `[wrapping]`, `[trapping]` —
these are compiler-lowered onto rt helpers, so the helpers are stdlib bottom.

| Block | Precedent | Nim mapping | Class | Status |
|---|---|---|---|---|
| wrapping add/sub/mul | Rust `wrapping_*`, C unsigned | Nim `+%`/`-%`/`*%` operators exist but only for exact cases | write (rt) | new |
| saturating add/sub/mul | Rust `saturating_*`, DSP C | none | write (rt) | new |
| checked (overflow-reporting) add/sub/mul | Rust `checked_*`, C# `checked` | Nim traps by default; reporting variant needs wrapper | write (rt) | new |
| safe div/mod (div-by-zero as value) | Rust `checked_div` | none (Nim raises) | write (rt) | new |
| int ↔ float conversions with range check | Rust `try_from` | `system.int`/`float` conversions raise | extern (shim) | new |

## 6. Atomics, volatile & sync

Portable half (`std/atomics`) plus the freestanding half.

| Block | Precedent | Nim mapping | Class | Status |
|---|---|---|---|---|
| atomic load/store/exchange | C11, Rust `core::sync::atomic`, C# `Interlocked` | `atomics.load`, `atomics.store`, `atomics.exchange` (`Atomic[T]`) | extern (direct) | new |
| compare-and-swap | same | `atomics.compareExchange` | extern (direct) | new |
| fetch add/sub/and/or | same | `atomics.fetchAdd`, `atomics.fetchSub`, `atomics.fetchAnd`, `atomics.fetchOr` | extern (direct) | new |
| memory fences (acquire/release/seq_cst) | C11 fences, Rust `fence` | `atomics.fence` + `MemoryOrder` | extern (direct) | new |
| volatile read / write | C `volatile`, Rust `read_volatile` | `volatile.volatileLoad`, `volatile.volatileStore` (std/volatile) | extern (direct) | new |
| spinlock | freestanding C/Rust | trivial over atomics | write (rt) | new |
| OS mutex / condvar | Go `sync.Mutex`, C# `Monitor` | `locks.Lock`/`locks.Cond` | extern (direct) — **flagged: not sanctioned v1; actors are the path** | new |

## 7. Interrupts & MMIO (freestanding)

Ties to effect markers `irq_safe` and the `--os:standalone` build path.

| Block | Precedent | Nim mapping | Class | Status |
|---|---|---|---|---|
| MMIO register decl + bit accessors | C volatile structs, Rust svd2rust | `registerMMIO` macro | write (rt) | rt (tuck_rt.nim:9) |
| enable / disable interrupts, critical section | C `cli/sei`, Zig, FreeRTOS | none portable — `{.emit.}`/asm per target | write (rt) | new |
| wait-for-interrupt / nop / barrier hint | ARM `wfi`, x86 `pause` | none — `{.emit.}` | write (rt) | new |
| cycle counter / high-res tick | ARM DWT, `rdtsc` | none portable | write (rt) | new |

## 8. Fixed-capacity structures (no_alloc set)

The static-memory family; three of four already exist.

| Block | Precedent | Nim mapping | Class | Status |
|---|---|---|---|---|
| ring buffer (SPSC mailbox) | embedded C, BEAM mailbox | `Mailbox[T, Cap]` | write (rt) | rt (tuck_rt.nim:121) |
| bump arena | Zig `FixedBufferAllocator` | `BumpArena[Size]` | write (rt) | rt (tuck_rt.nim:88) |
| object pool | embedded C pools | `ObjectPool[T, Count]` | write (rt) | rt (tuck_rt.nim:102) |
| fixed vector (bounded push/pop, no heap) | C++ `inplace_vector` (P0843), Rust `heapless::Vec` | none | write (rt) | new |
| fixed string (bounded, no heap) | Rust `heapless::String` | none | write (rt) | new |

## 9. Collections (allocating)

`Seq` and `Array` are language types today; nothing else is. **Biggest open
design question of this report:** the extern mechanism is monomorphic
(record-shaped sigs); generic containers need either checker-blessed types
(the `Seq` route) or generic externs. Higher-order ops (map/filter/fold)
wait for fn-refs (`bake`) to mature — they are NOT bottom layer.

| Block | Precedent | Nim mapping | Class | Status |
|---|---|---|---|---|
| Seq: append/pop/len/index/set | all | `system.add`, `system.pop`, `system.len`, `system.[]` | extern (direct) | new (ops unexposed) |
| Seq: insert/delete at index | all | `system.insert`, `system.delete` | extern (direct) | new |
| Seq: contains/find | all | `system.contains`, `system.find` | extern (direct) | new |
| Seq: sort/reverse | all | `algorithm.sort`, `algorithm.reversed` | extern (direct) | new |
| Seq: binary search | C `bsearch`, all | `algorithm.binarySearch` | extern (direct) | new |
| Map (hash) get/put/del/has/len/iterate | Go `map`, Nim `Table`, Elixir `Map`, C# `Dictionary` | `tables.Table` + `tables.[]=`, `tables.getOrDefault`, `tables.hasKey`, `tables.del` | extern (blocked on generics decision) | new |
| Set add/remove/has/len/iterate | Rust `HashSet`, Nim `HashSet`, C# `HashSet` | `sets.HashSet` + `sets.incl`, `sets.excl`, `sets.contains` | extern (blocked on generics decision) | new |
| Deque push/pop both ends | Rust `VecDeque`, Nim `Deque` | `deques.Deque` + `deques.addLast`, `deques.popFirst`, `deques.addFirst`, `deques.popLast` | extern (blocked on generics decision) | new |

## 10. Math

Pure; no wrappers. Integer abs/min/max may end up compiler-known.

| Block | Precedent | Nim mapping | Class | Status |
|---|---|---|---|---|
| abs / min / max / clamp | all | `system.abs`, `system.min`, `system.max`, `system.clamp` | extern (direct) | new |
| sqrt / pow / exp / ln | all (libm) | `math.sqrt`, `math.pow`, `math.exp`, `math.ln` | extern (direct) | new |
| floor / ceil / round / trunc | all (libm) | `math.floor`, `math.ceil`, `math.round`, `math.trunc` | extern (direct) | new |
| trig + atan2 | all (libm) | `math.sin`, `math.cos`, `math.tan`, `math.arctan2` | extern (direct) | new |
| isNaN / isInf / classify | all | `math.isNaN`, `math.classify` | extern (direct) | new |
| float bits ↔ int (transmute) | Rust `to_bits`, C `memcpy` idiom | `system.cast` | extern (shim, `[unsafe]`) | new |
| fixed-point arithmetic | DSP C, embedded | none | write (rt) — deferred until embedded demand | new |

## 11. Random

| Block | Precedent | Nim mapping | Class | Status |
|---|---|---|---|---|
| seeded PRNG (deterministic, value-typed state) | Rust `SmallRng`, Nim `Rand`, Go `math/rand` | `random.initRand`, `random.rand` | extern (shim) | new |
| OS entropy (crypto-grade bytes) | all (`getrandom`) | `sysrand.urandom` | extern (shim) | new |

## 12. Time

| Block | Precedent | Nim mapping | Class | Status |
|---|---|---|---|---|
| wall clock, epoch ms | all | `times.epochTime` | extern (direct) | std (time.tuck nowMs) |
| monotonic clock | Go `time.Since`, Rust `Instant` | `monotimes.getMonoTime`, `monotimes.ticks` | extern (direct) | new |
| sleep | all | `os.sleep` | extern (direct) | std (time.tuck sleepMs) |
| epoch → calendar components (y/m/d h:m:s, UTC) | all | `times.fromUnix`, `times.utc`, `times.getTime` | extern (shim) | new |
| send-after / timer message | BEAM `send_after`, Go `time.After` | — (actor runtime owns it) | write (rt) — lands with actor runtime | new |

## 13. Memory (raw, `[unsafe]`)

`sizeof/alignof/offsetof` are language builtins (spec §8.2), not stdlib.

| Block | Precedent | Nim mapping | Class | Status |
|---|---|---|---|---|
| alloc / alloc-zeroed / realloc / free | C malloc family | `system.alloc`, `system.alloc0`, `system.realloc`, `system.dealloc` | extern (direct) | new |
| memset / memcpy / memmove | C | `system.zeroMem`, `system.copyMem`, `system.moveMem` | extern (direct) | new (same rows as §3) |

## 14. OS: env, paths, filesystem, process

Everything fallible gets an error enum + resource kind (§7.4: files, dirs).

| Block | Precedent | Nim mapping | Class | Status |
|---|---|---|---|---|
| get/set env, args, exit | all | `os.getEnv`, `os.putEnv`, `os.paramStr`, `system.quit` | extern (shim) | std (sys.tuck; putEnv new) |
| cwd get/set | all | `os.getCurrentDir`, `os.setCurrentDir` | extern (shim) | new |
| path ops (join/split/parent/ext/absolute/normalize) — pure | all | `os.joinPath`, `os.splitPath`, `os.parentDir`, `os.changeFileExt`, `os.absolutePath`, `os.normalizePath` | extern (direct) | new |
| read/write/append/remove whole file, exists | all | `syncio.readFile` etc. | extern (shim) | std (fs.tuck ×5) |
| open file handle: read/write bytes at pos, flush, close | C `fopen` family, Go `os.File` | `syncio.open`, `syncio.readBuffer`, `syncio.writeBuffer`, `syncio.setFilePos`, `syncio.flushFile`, `syncio.close` | extern (shim) + resource kind | new |
| mkdir / rmdir / rename / move | all | `os.createDir`, `os.removeDir`, `os.moveFile` | extern (shim) | new |
| dir listing / walk | all | `os.walkDir` (iterator → materialize) | extern (shim) | new |
| stat (size, mtime, kind, perms) | all | `os.getFileInfo` | extern (shim) | new |
| temp dir | all | `os.getTempDir` | extern (direct) | new |
| line/text console IO | all | `syncio` stdin/stdout | extern (shim) | std (io.tuck ×3) |
| raw std stream bytes (read/write/flush) | all | `syncio.readBuffer`/`writeBuffer` on `stdin`/`stdout`/`stderr` | extern (shim) | new |
| spawn process, captured output + exit code | Go `exec`, C# `Process`, Rust `Command` | `osproc.execCmdEx` | extern (shim) | new |
| spawn streaming (pipes to child), wait/kill | same | `osproc.startProcess`, `osproc.waitForExit`, `osproc.terminate`, streams | extern (shim) + resource kind | new |

## 15. Net (sockets only — TLS/HTTP are later layers)

All `[io]`, error enums, `[resource: tcp/udp]` kinds (spec §7.4 names the
UDP example itself).

| Block | Precedent | Nim mapping | Class | Status |
|---|---|---|---|---|
| TCP connect / listen / accept | all | `net.newSocket`, `net.connect`, `net.bindAddr`, `net.listen`, `net.accept` | extern (shim) | new |
| send / recv bytes | all | `net.send`, `net.recv` | extern (shim) | new |
| close / shutdown | all | `net.close` | extern (shim) | new |
| UDP bind / sendTo / recvFrom | all | `net.sendTo`, `net.recvFrom` | extern (shim) | new |
| socket options (nodelay, reuse, timeouts) | all | `net.setSockOpt`; recv timeout param | extern (shim) | new |
| IP address parse/format | all | `net.parseIpAddress`, `system.$` | extern (direct) | new |
| DNS resolve | all | `nativesockets.getAddrInfo` | extern (shim) | new |

## 16. Messaging / actors (BEAM catalogue)

The actor runtime owns these; listed so upper layers know the guaranteed
primitive set. All write (rt).

| Block | Precedent | Nim mapping | Class | Status |
|---|---|---|---|---|
| bounded mailbox enqueue/dequeue | BEAM mailbox | `Mailbox` | write (rt) | rt |
| send-after (timer message) | BEAM `send_after` | — | write (rt) | new |
| monitor / link (failure notice as message) | BEAM monitors/links | — | write (rt) | new (post-actor-runtime) |
| selective receive (`on select`) | BEAM receive | — | write (rt) — spec §9.2 lowering | new |

## 17. Diagnostics

| Block | Precedent | Nim mapping | Class | Status |
|---|---|---|---|---|
| panic / fatal with message | all | `system.quit` + stderr write | write (rt) | new |
| assert (invariants) | all | emitted `assert` via validate() | — (language) | done |
| unhandled-error report | Tuck-specific (policy §4.9) | `tuckReportUnhandled` | write (rt) | rt |
| deferred logging (defmt-style format-string-ID) | Rust `defmt` | none | write (rt + Tuck mixin) — PRD ruling (tuck_prd_0.1.md:752) | new |

## 18. Core protocols & late additions (from the layer audit)

Added 2026-07-12 by the layer-map exercise (stdlib-layers.md): blocks that
every reference stdlib inserts directly above the primitives and that L1+
modules assume. Missing them was the audit's finding.

| Block | Precedent | Nim mapping | Class | Status |
|---|---|---|---|---|
| stream reader/writer/seeker/closer interface (+ file/socket/membuf impls) | Go `io`, .NET `Stream`, Rust `Read/Write` | — (Tuck `interface`, spec §5) | write (prelude) | new |
| hash protocol (primitives) | Go `hash`, .NET `GetHashCode`, Rust `Hash`, Nim `hashes` | `hashes.hash` | extern (direct) | new |
| hash/eq/ord for user records | Rust `derive(Hash, Eq, Ord)` | — | blocked on derive ruling (see open questions) | new |
| radix parse: hex/bin/oct ints | C `strtol`, Go `strconv`, Rust `from_str_radix` | `strutils.parseHexInt`, `strutils.parseBinInt`, `strutils.parseOctInt` | extern (shim) | new |
| radix format: hex/bin/oct | same | `strutils.toHex`, `strutils.toBin`, `strutils.toOct` | extern (direct) | new |
| text/byte builder (amortized append) | Go `strings.Builder`, C# `StringBuilder` | `system.add` on string (Nim strings are growable) | extern (direct) — surface it | new |
| ctrl-c / termination hook | Go `os/signal`, C `signal` | `system.setControlCHook` | extern (shim) | new |
| posix signals (full set) | C `sigaction`, BEAM traps | `posix.signal` / `posix.sigaction` | extern (shim, posix-only) | new |
| path canonicalize (realpath) | all | `os.expandFilename` | extern (shim) | new |

---

## Already covered today (the delta baseline)

- **std/*.tuck externs (14)**: fs — readFile, writeFile, appendFile,
  fileExists, removeFile · io — print, printLine, readLine · sys — argCount,
  argAt, getEnv, exit · time — nowMs, sleepMs.
- **tuck_rt types**: TuckResult (+tok/terr/tnone/tfwd/errCode), Mailbox,
  BumpArena, ObjectPool, registerMMIO. Beef runtime (tuck_rt.bf) mirrors all
  of these.

## Rough totals

~95 blocks. ≈60% **extern (direct)** — Nim already has them; ≈20% **extern
(shim)** — Nim has them behind exceptions/iterators and needs the TuckResult
reshape; ≈15% **write (rt)** — concentrated in integer semantics, endian/pack,
freestanding (irq/wfi/cycle counter), fixed-capacity structures, and the
actor/timer set; ≈5% **write (prelude)** — result combinators. Nothing in the
bottom layer requires reflection or macros beyond the two rt macros that
already exist (registerMMIO) or compiler lowering (checked-arith attrs).

## Open design questions (decisions NOT made here)

1. **Generic containers vs the extern mechanism**: Map/Set/Deque need either
   checker-blessed types like `Seq`, or a generic-extern feature. Everything
   in §9 below the Seq rows is blocked on this one ruling.
2. **Collection call style**: free fns (`{xs, x} push`) vs `..` chain
   mutation (`xs ..push {x}`) — interacts with the `set`-fn rule (§3.6).
3. **Compiler-lowered vs stdlib**: checked/saturating/wrapping arithmetic is
   spec'd as type attrs (§4.6) — the rt helpers land in stdlib bottom, but
   the lowering belongs to codegen. Same split for `volatile` on MMIO.
4. **Resource kinds for fs/net**: §7.4 registry is designed but not
   implemented; file-handle and socket blocks should declare their kinds from
   day one so the sigs don't churn.
5. **Bytes representation**: `Seq[u8]` everywhere vs a distinct binary type
   (BEAM-style) — affects §3 slicing semantics and the string↔bytes seam.
6. **Derive-style codegen for records** (from the layer audit): fmt, hash,
   and json all block on the same ruling — Tuck has no reflection, so
   per-record toStr/hash/encode must be compiler-derived or hand-written.
   One decision, three payoffs (stdlib-layers.md L1/L3 notes).
