# std.net.http

## Purpose
A production-capable HTTP client and server, in the box — request/response types, connection pooling, redirects, and a composable server handler/middleware model — with no third-party dependency required for either direction.

## Design lineage
Modeled directly on Go's `net/http`, called out in the report as "the strongest single precedent in the whole survey" for shipping both a real client and a real server in a language's own standard library. The handler-as-a-small-interface pattern (`Handler` with one method, middleware as `Handler -> Handler`) is taken from the same package, since it's the concrete mechanism that makes Go's server composable without a framework.

## Proposed API
```
// Client
struct Client;
impl Client {
    fn new() -> Client;                                   // sane defaults: pooled connections, redirect-follow, timeouts
    fn with_transport(t: Transport) -> Client;
    fn with_pool(t: Transport, pool: PoolConfig) -> Client;   // explicit pool sizing, see decisions below

    fn get(&self, ctx: &std::async::Context, url: &str) -> core::types::Result<Response, HttpError>;
    fn do(&self, ctx: &std::async::Context, req: Request) -> core::types::Result<Response, HttpError>;
    fn pool_stats(&self) -> PoolStats;                     // idle/in-use/total per-host connection counts
}

// Added for load-tester — see "Key design decisions" and std.async's executor-model resolution.
// Per-host keep-alive connection reuse under sustained concurrency; NOT one-connection-per-request.
struct PoolConfig {
    max_idle_per_host: u32,           // default 32
    max_total_per_host: u32,          // default 256; a checkout beyond this awaits a free connection
    idle_timeout: core::types::Duration,   // default 90s; idle connections older than this are closed
}
impl PoolConfig { fn default() -> PoolConfig; }

struct PoolStats { idle: u32, in_use: u32, total: u32 }

// Internal to Client, shown here because its locking strategy is a documented design decision,
// not an implementation detail: checkout/return is guarded by std.async::AsyncMutex, never
// sys.sync::Mutex, per std.async's executor-model corollary (a blocking Mutex here would stall
// the OS worker thread — and every other task scheduled on it — on every contended checkout).
struct ConnectionPool {
    per_host: alloc::map::Map<alloc::string::String, PooledHostConns>,   // guarded by std.async::AsyncMutex
}
impl ConnectionPool {
    fn checkout(&self, ctx: &std::async::Context, host: &str) -> core::types::Result<PooledConn, HttpError>;
    fn return_conn(&self, conn: PooledConn);   // back to idle if healthy, closed+dropped if the response indicated Connection: close
}
struct Request {
    method: Method, url: alloc::string::String,
    headers: HeaderMap, body: Option<Box<dyn sys::io::Reader>>,
}
impl Request {
    fn get(url: &str) -> Request;
    fn range(mut self, start: u64, end: Option<u64>) -> Request;   // sets Range: bytes=start-end
}
struct Response {
    status: u16, headers: HeaderMap, body: Box<dyn sys::io::Reader>,  // streamed, never fully buffered by default
}
impl Response {
    fn accepts_ranges(&self) -> bool;                       // checks Accept-Ranges header
    fn body_bytes(self) -> core::types::Result<alloc::vec::Vec<u8>, HttpError>;  // opt-in whole-body buffering
}
enum Method { Get, Post, Put, Delete, Head, Patch }
struct HeaderMap;
impl HeaderMap { fn get(&self, name: &str) -> Option<&str>; fn set(&mut self, name: &str, value: &str); }

// Server
trait Handler { fn handle(&self, ctx: &std::async::Context, req: &Request, w: &mut ResponseWriter); }
type Middleware = fn(next: Box<dyn Handler>) -> Box<dyn Handler>;

struct ResponseWriter;
impl ResponseWriter {
    fn set_status(&mut self, code: u16);
    fn set_header(&mut self, name: &str, value: &str);
    fn writer(&mut self) -> &mut dyn sys::io::Writer;       // streamed response body
}

struct Router;
impl Router {
    fn new() -> Router;
    fn route(&mut self, method: Method, pattern: &str, h: impl Handler + 'static);  // "/episodes/:id"-style
    fn use_middleware(&mut self, m: Middleware);
}
impl Handler for Router { /* dispatches by method+pattern */ }

struct Server;
impl Server {
    fn new(addr: &str, h: impl Handler + 'static) -> Server;
    fn with_tls(self, cfg: std::net::tls::ServerConfig) -> Server;
    fn serve(self, ctx: &std::async::Context) -> core::types::Result<(), HttpError>;  // blocks; ctx cancel = graceful drain
}

enum HttpError { Timeout, ConnectionRefused, TlsError(alloc::string::String), StatusError(u16), Cancelled }
```

## Key design decisions
- **Response bodies are streamed (`Box<dyn sys::io::Reader>`) by default; whole-body buffering (`body_bytes`) is an explicit opt-in call**, not the default return shape — this matches `web-downloader`'s requirement to write large files to disk incrementally rather than holding them fully in memory, and matches `podcast-subscriber`'s need to parse feed XML streamingly via `std.encoding.xml` directly off the response body.
- **`Request::range` exists specifically so resuming a partial download never requires hand-rolling a `Range:` header string** — `web-downloader`'s app profile flags exactly this ("a clean way to express resume-from-byte-N without reimplementing range-header math"); `Response::accepts_ranges` closes the loop by checking `Accept-Ranges` before a resume is attempted.
- **`Server::serve` takes a `std::async::Context` and treats cancellation as "stop accepting, drain in-flight handlers, then return"** rather than an abrupt socket close — this is the direct integration point with `chat-server`'s `SIGTERM`-triggered graceful shutdown requirement, reusing `std.async`'s context rather than the server module inventing its own shutdown signal shape.
- **`Handler` is a one-method interface and `Middleware` is `Handler -> Handler`**, deliberately avoiding a framework-style registration DSL (decorators, annotations, a app-object with dozens of configuration methods) — composing behavior (logging, auth, rate-limiting) is function composition, matching Principle 3.
- **`Client` pools and reuses per-host connections by default — `Client::new()`'s "pooled connections" was already stated in the prose but never given a concrete shape before `load-tester`, and it now is: `ConnectionPool` (keyed by host, `max_idle_per_host`/`max_total_per_host`/`idle_timeout` via `PoolConfig`).** Every prior validating app (`web-downloader`, `podcast-subscriber`) issues requests at a pace and concurrency (bounded fan-out, tens of connections at most) where "pooled" versus "one-connection-per-request" is not distinguishable from the outside — both would pass. `load-tester -c 200` against one target host is the first app whose entire point is sustained per-host throughput, and one-connection-per-request at that concurrency means 200+ TCP handshakes (and, over TLS, 200+ full handshakes including certificate verification) competing with the target server on every single measured request — which would make the load-tester's own overhead dominate the very latency numbers it's trying to measure, an unacceptable outcome for a tool whose entire job is accurate measurement. The resolution is concrete rather than a restated intent: `ConnectionPool::checkout` returns an existing idle keep-alive (HTTP/1.1) connection to the requested host when one is available, opens a new one up to `max_total_per_host` when not, and blocks (task-suspends, not thread-blocks — see below) a caller requesting a connection beyond that cap until one is returned. `PoolStats`/`Client::pool_stats()` exists so `load-tester`'s live progress view (and any diagnostic tooling) can report actual reuse behavior rather than inferring it indirectly.
- **`ConnectionPool`'s internal per-host map is guarded by `std.async::AsyncMutex`, not `sys.sync::Mutex` — a direct, load-bearing application of `std.async`'s executor-model resolution, not an arbitrary implementation choice.** `std.async` resolved this round that `spawn` runs tasks on a bounded M:N work-stealing pool, and that any lock seeing real contention under concurrent load must be an `AsyncMutex` so a blocked checkout suspends only the waiting task, not the OS worker thread it happens to be running on. `load-tester -c 200` makes every one of 200 concurrent request tasks touch the *same* per-host pool entry on every single request — the textbook contended-hot-lock case that motivated the `AsyncMutex`-mandatory rule in the first place. Had `ConnectionPool` used a plain `sys.sync::Mutex` here, a contended checkout would park a worker thread outright, and with only N (≈ core count) workers backing 200 tasks, that is a direct throughput cliff exactly where `load-tester` is trying to measure the target server's throughput, not the client's own scheduler contention.

## Validated by applications
- **web-downloader**: the primary client-side exercise — `Request::range` for resumable transfers, `Response::accepts_ranges` gating whether resume is attempted at all, streamed `Response::body` written incrementally to disk via `sys.fs`, and `std::async::Context` cancellation propagating from Ctrl-C through an in-flight `Client::do` call so a cancelled download can leave a well-defined partial file rather than a corrupt one — this is the app that most shaped the client half of the API.
- **podcast-subscriber**: exercises `Client::get` for both feed XML (streamed straight into `std.encoding.xml::FeedReader`) and episode audio downloads under `std.async`'s shared concurrency cap — validates the client works identically for "parse this response as a stream" and "write this response to a file" without different code paths.
- **chat-server**: does **not** use `std.net.http` at all (it is explicitly the raw-`sys.net` exercise instead) — this is a deliberate negative validation that `std.net.http`'s server half stays scoped to actual HTTP semantics (routing, headers, status codes) rather than becoming a general "network server" abstraction that would blur the `sys.net`/`std.net.http` boundary Principle 1 requires.
- **secrets-vault**: does not use networking at all — noted because it confirms `std.net.http` imposes zero cost (no ambient runtime, no global connection pool spun up) on programs that never construct a `Client` or `Server`, consistent with "no hidden allocation/no hidden setup" below the point of actual use.
- **load-tester**: the forcing case for `ConnectionPool`/`PoolConfig` above — the app's entire premise (sustained, high-concurrency, single-target-host throughput measurement) is the first validating load where connection reuse is load-bearing rather than incidental. `loadtest -c 200 -d 30s` constructs one `Client::with_pool(transport, PoolConfig { max_total_per_host: 200, .. })` sized to its own concurrency flag (so the pool cap is never itself the bottleneck being measured), issues requests from 200 concurrently `spawn`'d tasks each doing `checkout → do → return_conn` in a loop for the run's duration, and reads `pool_stats()` periodically to confirm connections are actually being reused (a near-zero `idle` count with `in_use` tracking the `-c` value indicates real keep-alive reuse; a `total` count that keeps climbing past `-c` would indicate a pooling bug — connections being churned rather than reused). This is also the app that makes the `AsyncMutex`-guarded internal locking concrete rather than a documented-but-unverified intent: 200 tasks checking out against the same host is precisely the contention pattern the executor-model resolution's corollary is written against.

## Open questions / risks
Whether HTTP/2 (and its multiplexed-stream implications for the `Transport`/connection-pool model) belongs in the initial `std` surface or should land as a later addition behind the same `Client`/`Request`/`Response` types is unresolved; the API above is written HTTP/1.1-first with the assumption that `Transport` is the seam a future HTTP/2 implementation would slot into without changing call sites. `ConnectionPool`'s `PoolConfig` defaults (`max_idle_per_host: 32`, `max_total_per_host: 256`) are reasonable starting points modeled on Go's `net/http` `Transport` defaults but are not tuned against any real measurement in this analysis-only project — `load-tester` validates the *shape* of pool configuration and reuse, not a specific numeric default.
