# App: load-tester (ab/wrk-lite)

A CLI HTTP load-testing tool: `loadtest http://localhost:8080/ -c 200 -d 30s` fires sustained concurrent requests at a target for a duration (or a fixed request count), and reports latency percentiles (p50/p90/p99/max), throughput (req/sec), and error rate.

## Why this is a good validation target
This is the sharpest test yet of `std.async` and `std.net-http` under deliberately extreme, adversarial-shaped load — thousands of requests per second, hundreds of concurrent connections, sustained for a fixed duration — a fourth concurrency shape distinct from `web-downloader` (bounded batch), `chat-server` (many idle), and `kv-store-server` (busy but server-side). This app is client-side sustained-throughput, which stresses connection pooling/reuse in a way none of the others do, and it's the direct consumer of `std.math`'s percentile statistics from `math-toolkit-cli`, now under real-time pressure (percentiles must be computed cheaply enough not to distort the measurement itself).

## Features
- Configurable concurrency (`-c`) and duration or request count (`-d`/`-n`).
- Connection reuse/pooling across requests to the same host (measuring realistic HTTP/1.1 keep-alive or HTTP/2 multiplexed behavior, not one-connection-per-request).
- Per-request latency recording with minimal measurement overhead (recording itself shouldn't skew results).
- Live progress during the run (current req/sec, running p99) plus a final summary report.
- Graceful early stop (Ctrl-C) that still prints a valid partial report.

## Modules exercised
| Tier | Module | Why |
|---|---|---|
| std | `std.async` | the module under direct stress — hundreds of concurrent request-response cycles sustained over a fixed duration |
| std | `std.net-http` | connection pooling/reuse behavior under sustained load — a client-side stress test complementing `web-downloader`'s more modest concurrency |
| std | `std.math` | percentile/histogram computation — reusing `stats::percentiles` from math-toolkit-cli, now needing to run continuously during the test, not just once at the end |
| sys | `sys.time` | high-resolution per-request latency timestamps (`Instant`, not `SystemTime` — this app cares only about elapsed duration, never wall-clock) |
| std | `std.cli` | live-updating progress display without disrupting the measurement |
| std | `std.testing` | validating the load generator's own timing/percentile-math correctness against synthetic, known-distribution inputs |
| sys | `sys.signal` | Ctrl-C → stop issuing new requests, drain in-flight ones, print the partial report — same pattern as web-downloader but under much higher connection count |
| core | `core.error` | classifying connection-refused vs. timeout vs. non-2xx response as distinct error categories in the final report |

## Anticipated API stress points
This app directly tests the open, unresolved risk `std.async` picked up in Extension round 1 (whether `spawn`'s executor is thread-per-task or a bounded M:N pool) under the worst-case scenario for that question: hundreds of concurrent in-flight requests is exactly the regime where a thread-per-task model would exhaust OS threads, while a bounded pool needs genuinely non-blocking I/O underneath to avoid head-of-line blocking. Whichever executor model the design settles on, this app is the one that would actually reveal whether it holds up — the module's own honesty about this being unresolved (not just optimistically assumed fine) is directly validated by this app existing.
