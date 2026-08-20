# App: web-downloader

A CLI tool in the spirit of `wget`/`aria2c`: given one or more URLs (or a `-i urls.txt` list), download to disk with resumable range requests, N-way parallel connections per host, a live progress display, retry/backoff on transient failures, and an optional recursive mode (follow same-origin links one level deep).

## Why this is a good validation target
It is the single best app in this set for stressing the `std.net.http` / `sys.net` / `std.async` boundary: resuming a partial download requires correct interaction between HTTP range headers, filesystem append semantics, and cancellation (Ctrl-C mid-download should leave a resumable partial file, not a corrupt one).

## Features (medium scope, not a full wget clone)
- Single and batch URL download, HTTP and HTTPS.
- Resume via `Range:` requests when the server supports it (check `Accept-Ranges`).
- Configurable parallelism (N concurrent downloads, M connections per host).
- Progress bar per file plus an aggregate summary (bytes/sec, ETA).
- Retry with exponential backoff on 5xx/timeout, give up after configurable attempts.
- Checksum verification (SHA-256) if the user supplies expected hashes.
- Graceful Ctrl-C: finish or safely truncate in-flight writes, print a resume command.

## Modules exercised
| Tier | Module | Why |
|---|---|---|
| std | `std.net.http` | GET with range headers, redirect following, header inspection |
| std | `std.net.tls` | HTTPS |
| std | `std.async` | N-way concurrent downloads with a shared cancellation context |
| std | `std.crypto` | SHA-256 checksum verification |
| std | `std.chrono` | ETA/throughput calculation, timestamps in logs |
| std | `std.log` | structured progress/error logging |
| std | `std.cli` | progress bars, colored status, argument parsing |
| sys | `sys.net` | underlying socket the http client is built on |
| sys | `sys.fs` | create/append/truncate output files, atomic rename on completion |
| sys | `sys.signal` | Ctrl-C → cooperative cancellation, not abrupt kill |
| alloc | `alloc.vec` / `alloc.string` | buffering, URL/header string handling |
| core | `core.error` | uniform error propagation across retry logic |

## Anticipated API stress points
`std.async`'s cancellation context needs to compose with `sys.fs` writes so that a cancelled download's partial file is left in a well-defined, resumable state rather than requiring app code to hand-roll cleanup handlers. `std.net.http` needs a clean way to express "resume from byte N" without the caller reimplementing range-header math.
