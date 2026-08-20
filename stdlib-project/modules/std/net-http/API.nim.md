# std.net-http — Nim API

## Purpose
A real HTTP client and a real HTTP server, both in the box. The client reuses connections per host and streams response bodies; the server is a handler and some middleware, not a framework.

## Protocols implemented
`Client` is a `Resource` (per PROTOCOLS' assignment table) and so is a pooled connection. `Headers` is `Gettable`, `Settable` and a `Collection`. `Server` is `Lifecycle` and `Waitable`. `Reply` is `Settable` and `Streamable`. `Routes` is a `Collection`.

## The API

```nim
type
  Method* = enum Get, Post, Put, Delete, Head, Patch
  Headers* = object
  Request* = object
    verb*: Method
    url*: Text
    headers*: Headers
    body*: Option[ByteSource]
  Response* = object
    status*: int
    headers*: Headers
    body*: ByteSource          ## streamed. Nothing is buffered unless you ask.
  Client* = object
  Reply* = object

proc newClient*(maxIdlePerHost = 32; maxPerHost = 256; idleFor = 90.seconds;
                followRedirects = true; tls = defaultTls()): Client
proc close*(c: var Client)
proc isOpen*(c: Client): bool

proc fetch*(c: Client; url: TextView; s: Scope;
            verb = Get; headers = Headers(); fromByte = 0'u64;
            upToByte = none(uint64)): Response
  ## The one call. `fromByte`/`upToByte` set `Range:` so resuming a download never
  ## means hand-writing header arithmetic. Raises on timeout, refusal or cancellation.
proc tryFetch*(c: Client; url: TextView; s: Scope; ...): Option[Response]
proc fetch*(c: Client; req: Request; s: Scope): Response     ## overload, not a second name

func canResume*(r: Response): bool          ## reads Accept-Ranges
proc readAll*(r: sink Response): List[byte] ## opt-in whole-body buffering

func get*(h: Headers; name: TextView): Option[TextView]     ## Gettable; never raises
proc set*(h: var Headers; name, value: TextView)            ## Settable
func has*(h: Headers; name: TextView): bool
iterator list*(h: Headers): (TextView, TextView)

# Connection pool — checkout and return are the Resource verbs, nothing new.
proc open*(p: var Pool; host: TextView; s: Scope): Connection
  ## Hands back an idle keep-alive when there is one, opens a new one up to
  ## `maxPerHost`, and suspends the *task* (never the worker thread) beyond that.
proc close*(c: var Connection)              ## back to idle if healthy, dropped if not
func poolStats*(c: Client): PoolStats       ## idle / inUse / total, per host

# Server
type Handler* = concept h
  handle(h, Scope, Request, var Reply)
proc set*(r: var Reply; status: int)
proc set*(r: var Reply; name, value: TextView)
proc write*(r: var Reply; data: View[byte]): int            ## Streamable

type Routes* = object
proc add*(r: var Routes; verb: Method; pattern: string;
          h: Handler): bool {.discardable.}                 ## "/episodes/:id"
proc wrap*(r: var Routes; middleware: proc (next: Handler): Handler)

proc newServer*(address: string; h: Handler; tls = none(ServerTls)): Server
proc start*(s: var Server): bool                            ## Lifecycle
proc stop*(s: var Server): bool     ## stop accepting, drain in flight, then return
proc isRunning*(s: Server): bool
proc wait*(s: Server; timeout = foreverDuration): bool      ## Waitable
```

**Pool locking.** The per-host pool map is guarded by `std.async`'s `TaskLock`, never a plain `sys.sync.Lock`. With `load-tester -c 200` every request task touches the same host entry; a blocking lock there parks one of only `workerCount()` worker threads and stalls every unrelated task queued behind it.

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `Client::get(ctx, url)` | `fetch(c, url, s)` | **The important one.** PROTOCOLS' `get` returns `Option` and never raises for absence; an HTTP request raises on timeout and refusal. Calling it `get` would promise the wrong failure mode on the library's most-used network call. `fetch` is honest, and `tryFetch` is its sibling. |
| `Client::do(ctx, req)` | `fetch` (overload) | Same verb, different second argument. `do` is a Nim keyword anyway. |
| `Request::range(a, b)` | `fromByte =` / `upToByte =` | Options last, and the two names say which end is which. |
| `Response::accepts_ranges` | `canResume` | Names the decision the caller is making, not the header it reads. |
| `body_bytes()` | `readAll` | Reads like the stream verb it is, and looks expensive, which it is. |
| `HeaderMap` | `Headers` | A plural noun, and it picks up `get`/`set`/`has`/`list` from the protocols. |
| `ConnectionPool::checkout` / `return_conn` | `open` / `close` | Borrowing a pooled connection *is* acquiring a resource. Two bespoke verbs disappear. |
| `PoolConfig { .. }` | named args on `newClient` | Three fields become three trailing arguments; there is no config object to discover. |
| `ResponseWriter` | `Reply` | Short, and it takes `set`/`write` from the protocols rather than `set_status`/`set_header`/`writer()`. |
| `Router` / `use_middleware` | `Routes` / `wrap` | `add(routes, Get, "/x", h)` is the Collection verb; `wrap` says what middleware does. |
| `Server::serve(ctx)` | `start` / `stop` / `wait` | Three protocol verbs replace one blocking call, and graceful shutdown stops being a special argument. |

## In use

```nim
# web-downloader: resume from byte N, cancel cleanly, never buffer the file
let resp = client.fetch(url, s = scope, fromByte = partial.size)
if not resp.canResume() and partial.size > 0: partial.clear()
copyInto(resp.body, partial, hash = digest)      # Ctrl-C stops the scope mid-copy

# load-tester: 200 tasks, one pooled client, latency off the hot path
withScope(deadline = some(runFor)):
  for i in 1 .. concurrency:
    it.spawn proc (s: Scope): void =
      while s.isRunning():
        let t0 = now()
        discard client.fetch(target, s).readAll()
        latency.add((now() - t0).millis)         # task-local std.math Quantiles
echo client.poolStats()                          # idle ~0, inUse ~200 means real reuse
```

## Vocabulary exceptions
`fetch` is a domain verb introduced specifically so `get` can keep its promise. This is the clearest case in the whole `std` tier where the vocabulary's rule ("absence returns `Option`, failure raises") outranked the temptation to reuse a structural verb because it read nicely.

`wrap` and `handle` are domain verbs: middleware composition and request dispatch have no structural analogue. `Handler` is a `concept`, so any object with a `handle` proc qualifies — including `Routes` itself, which is how a router nests inside a router with no special case.
