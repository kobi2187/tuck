# sys.net — Nim API

## Purpose
TCP, UDP and Unix-domain sockets, plus name resolution. It hands you a connected stream and stops there — no HTTP, no TLS, no assumption about what you'll say over it.

## Protocols implemented
`TcpStream` is `Resource` + `Streamable`; `Listener` is `Resource` + `Collection` (of incoming connections) — per PROTOCOLS' assignment table. `UdpSocket` is `Messenger[Packet]`.

## The API

```nim
type
  Address* = object            ## IPv4/IPv6 host plus port, already resolved
  TcpStream* = object          ## Resource + Streamable. Never Seekable — a socket can't rewind
  Listener* = object           ## Resource + Collection[TcpStream]
  UdpSocket* = object          ## Messenger[Packet]
  Packet* = object
    data*: seq[byte]
    sender*: Address

proc listen*(at: Address; backlog = 128; reusePort = false): Listener
proc tryListen*(at: Address; backlog = 128; reusePort = false): Option[Listener]
iterator list*(l: Listener): TcpStream
  ## The Collection primitive, and the whole accept loop: `for client in server.list(): ...`.
  ## Blocks between connections; ends when the listener is closed.
proc close*(l: var Listener)            ## unblocks `list` — this is how a graceful shutdown starts
proc address*(l: Listener): Address

proc connect*(to: Address; timeout = 10.seconds): TcpStream
  ## The timeout has a default *because* leaving it off means "wait out the OS's TCP timeout",
  ## which is minutes. One proc, not `connect` plus `connect_timeout`.
proc tryConnect*(to: Address; timeout = 10.seconds): Option[TcpStream]
proc peer*(s: TcpStream): Address
proc copy*(s: TcpStream): TcpStream
  ## An independent handle on the same socket — one for a reader thread, one for a writer.
proc finishWriting*(s: var TcpStream)
  ## Half-close: the peer sees end-of-stream, you can still read what they have left to say.

proc `readTimeout=`*(s: var TcpStream; d: Duration)
proc `writeTimeout=`*(s: var TcpStream; d: Duration)
proc `noDelay=`*(s: var TcpStream; on: bool)     ## off Nagle; what a small-request protocol wants
proc `blocking=`*(s: var TcpStream; on: bool)    ## `false` makes reads raise `WouldBlock`
proc handle*(s: TcpStream): OsHandle
  ## The raw fd/SOCKET, for `std.async`'s reactor to register with epoll/kqueue/IOCP.
  ## Named to be greppable; nothing in `sys` uses it.

proc openUdp*(at: Address): UdpSocket
proc send*(u: var UdpSocket; msg: Packet)
proc receive*(u: var UdpSocket; timeout = Forever): Option[Packet]

proc listenLocal*(path: Path; backlog = 128): Listener   ## Unix domain, same Listener type
proc connectLocal*(path: Path): TcpStream                ## …and the same stream type
proc resolve*(host: string; port: int): seq[Address]      ## blocking; raises if the name is unknown
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `TcpListener::bind` | `listen(at)` | "bind" is a syscall name; `listen` is what the thing is for |
| `incoming()` iterator | `list(listener)` | it is the `Collection` primitive, so `count`/`first`/`each` come free |
| `connect` + `connect_timeout` | `connect(to, timeout = 10.seconds)` | the trailing-named-arg rule, and the safe path becomes the default |
| `try_clone` | `copy` | PROTOCOLS' word for "independent duplicate", already meaning that in six other modules |
| `shutdown(Shutdown::Write)` | `finishWriting` | says the intent; nobody has to learn that "shutdown" doesn't close |
| `set_nodelay(true)` | `s.noDelay = true` | Nim's assignment sugar *is* `set`, and reads better than any method |
| `UnixListener` / `UnixStream` | `listenLocal` / `connectLocal` → same types | two more types earned nothing; the protocol-agnostic stream is the point |
| `recv_from` / `send_to` | `receive` / `send` with a `Packet` | UDP is genuinely a `Messenger`; the address rides along in the message |
| `AsRawFd` *(gap)* | `handle()` | resolved: one honest escape hatch so `std.async` can multiplex |

## In use

```nim
# chat-server: the whole accept loop, plus a shutdown that actually unblocks it
var server = listen(Address("0.0.0.0", 6667))
for client in server.list():
  client.readTimeout = 5.minutes            # a slow client must not stall the room
  client.noDelay = true
  run(handleClient, client)                 # sys.thread

# …meanwhile, on the signal watcher thread:
signals.receive().ifSome(sig):
  server.close()                            # `list` ends, the accept loop falls out
  rooms.use do (r: var Rooms): r.announce("server going down")
```

## Vocabulary exceptions
- **`listen`, `connect`, `resolve` and `finishWriting` are domain verbs.** `open` is taken by `Resource` (reconnecting an existing `TcpStream`), and "connect to a host" is not "acquire this handle again" — conflating them would make `retry(stream, 3, 500.ms)` mean two different things.
- **Socket options use Nim's `x.field = v` sugar rather than `set(s, key, value)`.** Their values have different types, so a keyed `set` would need an untyped variant. The setter *is* `set`, spelled the way Nim already spells it.
- **`Listener` is a `Collection` you cannot `add` to or `remove` from.** Only `list` is meaningful; the derived bundle (`first`, `each`) still applies and is genuinely useful.
