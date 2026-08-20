# App: chat-server

A small multi-client TCP chat server (mini-IRC): clients connect, pick a nickname, join named rooms, broadcast messages to a room, and see join/leave notifications. A companion CLI client connects and provides a simple line-based UI. Graceful shutdown (`SIGTERM`) notifies all clients and closes cleanly.

## Why this is a good validation target
It is the primary exercise for raw `sys.net` (as opposed to `std.net.http`, exercised elsewhere) and for `sys.sync`/`sys.thread` (or `std.async`) under genuine concurrent-client load, plus `sys.signal` for orderly shutdown — none of the other apps in this set requires a long-lived server accepting concurrent inbound connections.

## Features
- TCP listener accepting many concurrent client connections.
- Per-client read loop; per-room broadcast to all subscribed clients.
- Nickname registration/collision handling, join/part/quit notifications.
- Idle-connection timeout and basic backpressure (slow client shouldn't stall the server).
- Graceful shutdown: stop accepting, notify connected clients, drain, exit.

## Modules exercised
| Tier | Module | Why |
|---|---|---|
| sys | `sys.net` | raw TCP listener/accept/read/write — the thing `std.net.http` is itself built on |
| sys | `sys.thread` / `std.async` | one task/thread per connection (or an event-loop model) — a real comparison point between the two concurrency styles |
| sys | `sys.sync` | shared room/client registry accessed from many connection handlers concurrently |
| sys | `sys.signal` | `SIGTERM`/`SIGINT` → graceful drain instead of dropped connections |
| alloc | `alloc.map` | room → client-list and nickname → connection registries |
| std | `std.log` | connection/error/shutdown logging |
| std | `std.chrono` | message timestamps, idle-timeout tracking |
| core | `core.error` | malformed client input, connection reset handling |

## Anticipated API stress points
This app directly tests whether `std.async`'s cancellation-propagating context (Part IV, `std.async`) is actually usable for a long-lived server with thousands of short-lived per-connection tasks, or whether it was really only designed with the `web-downloader`'s "N downloads, then done" shape in mind. It's also the strongest test of whether `sys.sync`'s primitives are fast enough under contention to avoid needing a bespoke lock-free structure — a real finding either way.
