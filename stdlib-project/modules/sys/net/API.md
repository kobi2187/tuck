# sys.net

## Purpose
Raw TCP, UDP, and Unix-domain sockets plus DNS resolution — the transport-layer primitives `std.net.http` (and any future protocol implementation) is built on top of. No HTTP, no TLS: those are `std` tier.

## Design lineage
Modeled on Go's `net` package (minus `net/http`) for its clean split between listener/connection types and its `Addr`-resolution model, and Rust's `std::net` for its typed `SocketAddr`/`Ipv4Addr`/`Ipv6Addr` hierarchy and its `TcpListener`/`TcpStream` naming, which this design keeps verbatim since it reads clearly. POSIX sockets are the underlying reference for what operations must be representable (`bind`/`listen`/`accept`/`connect`/`shutdown`), but the raw `sockaddr`-family API surface is deliberately not exposed directly — it's wrapped the way Go and Rust both already demonstrate is possible without losing capability.

## Proposed API
```
struct TcpListener { .. }
impl TcpListener {
    fn bind(addr: &str) -> Result<TcpListener, NetError>;         // "0.0.0.0:8080", resolves via sys.net::resolve
    fn accept(&self) -> Result<(TcpStream, SocketAddr), NetError>; // blocks
    fn incoming(&self) -> IncomingIter;                            // core.iter-compatible: Iterator<Item=Result<TcpStream,NetError>>
    fn local_addr(&self) -> Result<SocketAddr, NetError>;
    fn set_nonblocking(&self, v: bool) -> Result<(), NetError>;
}
struct TcpStream { .. }
impl TcpStream {
    fn connect(addr: &str) -> Result<TcpStream, NetError>;
    fn connect_timeout(addr: &SocketAddr, timeout: Duration) -> Result<TcpStream, NetError>;
    fn peer_addr(&self) -> Result<SocketAddr, NetError>;
    fn set_read_timeout(&self, d: Option<Duration>) -> Result<(), NetError>;
    fn set_write_timeout(&self, d: Option<Duration>) -> Result<(), NetError>;
    fn set_nodelay(&self, v: bool) -> Result<(), NetError>;
    fn shutdown(&self, how: Shutdown) -> Result<(), NetError>;     // Read | Write | Both — half-close support
    fn try_clone(&self) -> Result<TcpStream, NetError>;            // independent handle, e.g. for split read/write threads
}
impl Reader for TcpStream { .. }   impl Writer for TcpStream { .. }

struct UdpSocket { .. }
impl UdpSocket {
    fn bind(addr: &str) -> Result<UdpSocket, NetError>;
    fn send_to(&self, buf: &[u8], addr: &str) -> Result<usize, NetError>;
    fn recv_from(&self, buf: &mut [u8]) -> Result<(usize, SocketAddr), NetError>;
    fn connect(&self, addr: &str) -> Result<(), NetError>;   // fixes peer; then send/recv without addr
}

struct UnixListener { fn bind(path: &Path) -> Result<UnixListener, NetError>; .. }
struct UnixStream { fn connect(path: &Path) -> Result<UnixStream, NetError>; .. }  // implements Reader/Writer

fn resolve(host: &str) -> Result<Vec<IpAddr>, NetError>;   // blocking DNS lookup, no async variant at this tier
```

## Key design decisions
- `TcpListener::incoming()` returns a `core.iter`-compatible iterator of `Result<TcpStream, NetError>`, matching Go's accept-loop idiom (`for conn := range listener.Accept()`-shaped code), so the most common server pattern — accept-loop spawning a handler per connection — needs no boilerplate beyond a `for` loop and a `sys.thread::spawn` (or `std.async` task spawn) call per item.
- `shutdown(Shutdown::Write)` (half-close) is exposed explicitly rather than only offering a full `close`, because graceful protocol shutdown (finish writing, signal EOF to the peer, still read their remaining data) is a real pattern this design refuses to make apps work around with raw `Drop` timing.
- `connect_timeout` is a separate constructor from `connect`, not an option struct, because connection establishment is the one socket operation where "no timeout" silently means "wait for the OS's TCP-level timeout" (often minutes) — making the timeout-aware path syntactically distinct nudges correct usage.
- DNS resolution (`resolve`) is synchronous/blocking only at this tier, consistent with `sys.io` being blocking-only — an async resolver is `std.async`'s or a `platform`-tier concern, not duplicated here.

## Validated by applications
- **chat-server**: this is the module's primary validation target, explicitly named as "the thing `std.net.http` is itself built on." The accept-loop-plus-per-connection-handler pattern (whether via `sys.thread` or `std.async`) directly exercises `TcpListener::incoming()`, and the idle-connection-timeout/backpressure requirement ("a slow client shouldn't stall the server") is why `set_read_timeout`/`set_write_timeout` are first-class per-stream settings rather than a global socket-option escape hatch — a naive design without per-operation timeouts would force the app to implement its own timeout via a second monitoring thread per connection, which this API avoids. Graceful shutdown (stop accepting, notify clients, drain, exit) is also why `shutdown(Shutdown::Write)` exists: the server can stop *writing* to a listener's connections (or half-close outbound) while still draining reads, rather than only supporting an abrupt full close.
- **web-downloader**: consumes `sys.net` only indirectly, as the socket underneath `std.net.http`'s client — but this app is why `connect_timeout` needed to exist as a distinct, easily-composed-with-retry-logic call: the app's exponential-backoff retry loop needs a bounded-time connection attempt per try, not an indefinitely blocking `connect` that could stall a whole retry budget on one hung attempt.
- **podcast-subscriber**: parallel, rate-limited-per-host feed polling (also built on `std.net.http` over `sys.net`) is a secondary confirmation that `TcpStream::try_clone` (or equivalent independent-handle support) matters — concurrent per-host connection limiting at the `std` tier needs to track and bound live `sys.net` connections without the module getting in the way of that bookkeeping.
- **kv-store-server** (Round 2): a distinct load shape from `chat-server`'s — many *busy*, throughput-bound connections issuing a continuous stream of small requests, rather than many mostly-*idle* long-lived ones. This is the first app in the set to actually exercise `set_nodelay`, which was already in the API sketch but uncited: a line-based protocol exchanging small `SET`/`GET`/`INCR` requests/responses is exactly the case Nagle's algorithm (batching small writes) actively hurts by adding latency, so `set_nodelay(true)` being a first-class per-stream call (not a global socket-option escape hatch) is what this app needed and the module already provided. The accept-loop shape itself (`TcpListener::incoming()`) holds up unchanged; per-connection backpressure ("a slow client's socket buffer filling shouldn't stall other clients") is served by `set_write_timeout` plus the app's own per-connection task/buffer being independent, the same mechanism `chat-server` already validated — this app confirms it also holds under sustained throughput, not just occasional slow clients.
- **tls-cert-inspector** (Extension round 3): the first app in the set to need a `TcpStream` that is deliberately *not* immediately handed to an HTTP layer or treated as an opaque post-handshake byte stream — it needs the raw connected socket so `std.net-tls` can perform a handshake-only exchange (retrieve and inspect the certificate chain, no application-layer request ever sent) on top of it. Checking this against the existing surface: it composes cleanly with no change needed. `TcpStream::connect`/`connect_timeout` already return a plain `TcpStream` implementing `Reader`/`Writer`, with no assumption baked in anywhere in this module about what protocol (if any) runs on top — `std.net-http` layering an HTTP client on it and `std.net-tls` layering a TLS handshake on it are both just "a `std`-tier module that takes a `Reader + Writer`," which is exactly the "just give me a connected socket, I'll layer TLS myself" shape the original design intended `std.net-tls` to wrap (per `REPORT.md`'s tier split: `sys.net` is transport-only, "no HTTP, no TLS" is stated explicitly in this module's own Purpose). This app is the first to actually exercise that boundary in the handshake-only direction rather than the "socket immediately becomes an HTTP connection" direction every prior TLS-touching app (`web-downloader`, `podcast-subscriber`) exercised — and it confirms the boundary holds: `sys.net` hands back a socket and stops, with no knowledge of or accommodation for what comes next, which is precisely what let `std.net-tls` add a handshake-only, no-application-data entry point (see that module's own file) without needing anything new from `sys.net` itself.
- **process-supervisor** (Round 2): the first app in the set to actually exercise `UnixListener`/`UnixStream` (the local control socket for `supervisorctl status|restart|stop|tail`) — both types were in the original API sketch but had no citing app until now. No change was needed: `UnixStream` implementing `Reader`/`Writer` the same way `TcpStream` does is exactly what lets the control-protocol parsing code be agnostic to which socket type it's reading from.

## Open questions / risks
**Gap noted (not resolved here):** kv-store-server's "thousands of busy connections" shape is meant to be served by `std.async`'s scheduler sitting on top of `sys.net` (per `INDEX.md` finding 6, `std.async`'s one-scope-design-two-shapes story), but that requires the async runtime's reactor to do OS-level readiness multiplexing (epoll/kqueue/IOCP) across many sockets at once — and this module's sketch has no way to hand out a raw platform handle (`AsRawFd`/`AsRawHandle`-equivalent) for a reactor to register against; `set_nonblocking` plus a `WouldBlock`-distinguishable `IoError` (already an open question in `modules/sys/io/API.md`) may be sufficient without one, or may not be. This is a real gap surfaced by this app but belongs to the `sys.net`/`std.async` boundary rather than being resolved unilaterally here — flagged for whoever next touches either module's file.
Whether `resolve()` should return records in a documented, stable order (some resolvers reorder for latency/Happy-Eyeballs-style reasons) — chat-server and web-downloader don't currently stress this, but a future IPv6-dual-stack app would. Also open: whether raw socket options (`SO_REUSEADDR`, `SO_REUSEPORT`) get typed setters here or a generic escape-hatch `set_option(level, name, value)` — the former is more principle-4-coherent but can't anticipate every platform-specific flag.
