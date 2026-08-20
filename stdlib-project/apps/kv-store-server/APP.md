# App: kv-store-server (redis-lite)

A small in-memory key-value server: `SET`/`GET`/`DEL`/`EXPIRE`/`INCR` over a line-based TCP protocol, with a write-ahead log for durability and periodic snapshotting, servicing many concurrent clients under sustained load (thousands of ops/sec, not `chat-server`'s comparatively idle chatroom traffic).

## Why this is a good validation target
`chat-server` validated `sys.net`/`sys.sync` under many *idle* long-lived connections; this app validates the same modules under many *busy* connections issuing a continuous stream of small requests — a materially different concurrency shape (throughput-bound, not connection-count-bound) that stresses `std.async`'s scheduler and `sys.sync`'s contention behavior differently. It's also the strongest test yet of `sys.fs`'s durability story (fsync semantics, crash-safe append) since a WAL that lies about durability is a correctness bug, not a performance one.

## Features
- In-memory map with TTL-based expiry (`EXPIRE`), lazy + active expiration.
- Write-ahead log: every mutating command appended before being applied, fsync'd per a configurable durability policy (every write / every N ms / OS-buffered).
- Periodic snapshot + WAL truncation, and crash recovery (replay WAL since last snapshot on startup).
- Simple line-based text protocol (not binary) for easy `nc`/`telnet` debugging.
- Basic backpressure: a slow client's socket buffer filling shouldn't stall other clients.

## Modules exercised
| Tier | Module | Why |
|---|---|---|
| sys | `sys.net` | TCP server accepting many concurrent, high-throughput connections |
| sys | `sys.sync` | the shared map is on the hot path of every single request — lock contention is the whole ballgame here |
| sys | `sys.fs` | WAL append + fsync semantics, snapshot file writing |
| std | `std.async` | scheduling potentially thousands of concurrent client tasks under sustained load, not just many idle ones |
| alloc | `alloc.map` | the core data structure — this app is a real stress test of its performance under high mutation rate |
| std | `std.chrono` | TTL expiry timing |
| std | `std.encoding` | binary struct packing for WAL records and snapshot format |
| std | `std.testing` | crash-recovery correctness is exactly the kind of property that needs a test harness: kill the process mid-write, replay the WAL, assert no lost or corrupted acknowledged writes |
| core | `core.error` | protocol errors, WAL corruption detection (should fail closed, not silently apply a truncated record) |

## Anticipated API stress points
This is the sharpest test in the whole project of whether `sys.fs`'s "atomic write" story (already established by `todo-cli`'s undo log and `secrets-vault`'s vault file) generalizes to a genuinely high-frequency append-only log rather than just occasional whole-file rewrites — specifically, whether `sys.fs` exposes fsync-on-append as a cheap, explicit, per-call choice or forces a whole-file rewrite pattern that would make this app's durability policy prohibitively slow. It also directly tests `std.async`'s claimed answer (from the original `INDEX.md` finding) that one `Context`/`Scope` design serves both `web-downloader`'s bounded batch and `chat-server`'s long-lived-idle shape — this app adds a third shape, long-lived-and-busy, that the same primitives need to serve without a redesign.
