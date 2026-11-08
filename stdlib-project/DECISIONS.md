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

| Module | Done | Not done, and why |
|---|---|---|
| `std.db` | builder (`db`), sqlite3 driver (`sqlite`, shims on Nim/Odin/D) | none |
| `std.net-tls` | verdicts (`tls`), OpenSSL driver (`openssl`, shims on Nim/Odin/D; handshake checked against a local `openssl s_server`, strict verify refuses a self-signed certificate) | none |
| `sys.audio` | arithmetic, ring, 16-bit WAV file sink | a live device backend: no ALSA headers here, and CI has no sound card |
| `sys.window` | headless window, scripted input `replay` | a display backend: needs an X server or SDL, neither available to CI |
| `sys.ble` | filter, dedup, recorded-scan replay (`advertsFromRows`) | a live scanner: no BlueZ here, no radio in CI |
| `core.mem` | — | scrubbing needs a scope-exit hook; a `Scrubbed` value that wipes itself cannot be written yet |
| `std.serde-derive` | — | owner deferred; needs compile-time type introspection |

The three "not done" device backends are one file per backend each, behind the
same handle-and-bytes contract the sqlite and OpenSSL shims use, and nothing in
the checked cores changes when they land.
