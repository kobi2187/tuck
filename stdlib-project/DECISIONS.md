# Stdlib decisions: what ships, and how

Written 2026-11-08 for the "finish the stdlib" week. For every module that had a
design but no Tuck source, four questions, answered once:

1. **Does it fit Tuck?** (the Tier-1 rules: no stored pointers, no `ref`, value
   semantics, call-by-payload, no scope-exit hook)
2. **Does a builtin make it superfluous, in whole or in part?**
3. **Shim or Tuck?** A *shim* is an `extern`/`impl:` binding to a host library;
   *Tuck* is ordinary code the compiler checks on all three backends.
4. **What is the testable core?** Every module carries a `main` of checks and
   runs on Nim, Odin and D; anything that needs hardware or a library is split
   so the part that can be checked is.

## Decided with the owner (2026-11-08)

* The eight dissolved designs **stay dropped**: `alloc.box`, `alloc.rc`,
  `alloc.allocator`, `alloc.fmt`, `core.ptr`, `core.atomic`, `core.sync-cell`,
  `core.slice`. `core.slice`'s verbs live in `core.array` (`slice`, `take`,
  `drop`, `windows`, `splitAt`).
* Everything else gets a module, decided one by one below.
* `std.serde-derive` and compile-time reflection are **deferred**; the runtime
  half of `std.reflect` is done.

## The rest

| Module | Fits Tuck? | Builtin that covers part | Approach | Testable core |
|---|---|---|---|---|
| `std.reflect` | runtime half yes; derive no | `Json` is the dynamic value | **Tuck, done** | schemas, validation paths, leaf paths, diff |
| `platform.interrupt` | partly: the compiler enforces ISR purity, not shared state | none | **Tuck simulation**: controller state as a value; critical sections hold and flush | raise/mask/critical/flush |
| `platform.rtos` | mostly absorbed: tasks, actor mailboxes, `on select` timers | `task`, `[queue: N]`, timers | **Tuck simulation** of the leftovers (priority table, tick counter, stack watermark) | priorities, ticks |
| `sys.fs` | yes | `std/fs` externs + `sys.files` already cover it | **No new module**: the flat `fd` verbs are `std/fs`; `FsError` mapping already in `files` | existing `files` checks |
| `std.db` | an actor cannot be many connections; a handle cannot be stored | none | **Two layers**: pure-Tuck SQL builder (quoting, `?` binding, identifiers) now; sqlite3 shim over `std/` externs once the builder lands | builder output text |
| `std.net-tls` | yes, as `fd` + closed `TlsError` | `std/net` is the `fd` model | **Tuck for chain verification** (validity window, hostname match with wildcard, chain order); the handshake is an OpenSSL shim, later | `verifyChain` |
| `sys.audio` | lifecycle yes; the real-time fill callback cannot be an actor | none | **Tuck for the pure parts** (format maths, PCM conversion, ring buffer, tone generator) + a null sink; device I/O is a shim, later | frame maths, conversion, ring |
| `sys.window` | yes, as designed (state + lossless events) | actor model | **Tuck** headless window: held-key bitset, drop-oldest event queue with `ackEvents`; display is a shim, later | queue policy, bitset |
| `sys.ble` | scanner yes; stack is host | none | **Tuck** advert filtering and AD-structure parsing over `platform.net-lowpower`; scanning is a shim, later | parse/filter |
| `core.simd` | yes: `Pack[N, T]` is a value over `Array` | `Array[N, T]`; LLVM/clang vectorise lane loops | **Tuck**: lane-wise loops, left to the C/D/Odin compiler to vectorise; no intrinsics | lane ops, reductions, masks |
| `core.mem` | scrub needs a scope-exit hook Tuck lacks | `pool`/`arena` zero on release? (to check) | **Deferred** with the reason; revisit with the language answer | — |
| `std.serde-derive` | needs compile-time type introspection | none | **Deferred** (owner: probably not the Tuck way) | — |

## Why shims come second

A shim is only as checkable as the library behind it, and CI has no sound card,
display or Bluetooth radio. Each hardware-facing module is therefore split: the
pure core is tested everywhere now, and the shim is a thin layer added after
that does nothing the core has not already been checked against.

## Status after the shim pass (2026-11-08)

Every module now has a checked core and, where hardware or a library is behind
it, a driver with shims on Nim, Odin and D.

| Module | Core | Driver (shims on all three backends) | Verified how |
|---|---|---|---|
| `std.db` | `db` builder | `sqlite`: sqlite3 | in-memory database round trip |
| `std.net-tls` | `tls` verdicts | `openssl`: X509 and TLS client | PEM parsing offline; a real handshake against a local `openssl s_server`, strict verify refuses the self-signed certificate |
| `sys.audio` | arithmetic, ring, WAV sink | `alsa`: playback | ALSA's `null` PCM (accepts and discards), no sound card needed |
| `sys.window` | headless window, scripted `replay` | `x11`: Xlib | a key injected into a real window under Xvfb is read back through `pump`; with no X server the check says so and passes |
| `sys.ble` | filter, dedup, CSV replay | `hci`: BlueZ raw HCI socket | the report parser byte for byte against hand-built packets; live only to the "no adapter" path, because this machine has no Bluetooth adapter |
| `core.mem` | secret buffers behind a handle | `secret`: `mlock`, `explicit_bzero` | create, compare in constant time, wipe, read-after-wipe |
| `std.serde-derive` | — | — | deferred by the owner; needs compile-time type introspection |

`core.mem`'s `Scrubbed[T]` (a value that wipes itself on scope exit) still cannot
be written: Tuck has no destructor. What replaces it is the discipline it was
for: the secret lives in shim-owned locked memory behind a handle, and `wipe`
ends it explicitly.

## Where the line falls: shim, or native Tuck (owner's ruling, 2026-11-08)

* **Algorithm-heavy modules are shims over a vetted C library**: `std.crypto`
  (libcrypto: hashes, HMAC, PBKDF2, random bytes, ChaCha20-Poly1305),
  `std.compress` (zlib and libzstd), `std.chrono`'s zones (libc's tz database),
  and the drivers (sqlite3, OpenSSL, ALSA, Xlib, BlueZ). Where a pure-Tuck
  implementation already existed (SHA-256, HMAC, DEFLATE) it stays as an
  independent cross-check: what one writes the other must read.
* **Basic building blocks are Tuck**: `std.net-http` (client, server, messages),
  `std.cli`, `std.encoding`, `sys.env`. HTTP talks to sockets by descriptor and
  needs no library.
* **Process and environment are native, not shims.** They are the language's own
  runtime: `std/sys` carries `spawnProcess`, `fdRead`, `fdReadWithin`,
  `fdWrite`, `fdClose`, `waitProcess`, `pollProcess`, `killProcess`, `setEnv`,
  `unsetEnv`, `currentDir`, `changeDir` and `exePath`, implemented in all three
  runtimes (`tuck_rt.nim`, `tuckrt/tuck_rt.odin`, `tuckrt_d/tuck_rt.d`); a
  child's pipes are descriptors the reactor awaits, so a read suspends only the
  calling task, as a socket does. `sys.process` and `sys.env` are Tuck on top.
