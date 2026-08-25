# sys.net — Tuck translation

## This module already exists — `std/net.tuck` is real, implemented code.

Second of two (with `sys.time`) where this is a **diff against working
code** rather than a translation. `std/net.tuck` ships
`listen`/`accept`/`connect`/`recv`/`send`/`close` with a `NetError` enum,
all over `fd: int`, and it is the precedent every other `sys` module here
was matched to.

## What the real module already has

```tuck
type NetError:
  | Refused        # nothing listening, or the peer rejected the connection
  | AddressInUse   # another process holds that port
  | Unreachable    # no route, or the address does not resolve
  | Closed         # the peer hung up mid-operation
  | IoFailed       # anything else the OS reported

extern:
  fn listen({port: int}) -> !{fd: int} [io, error: NetError]
  fn accept({fd: int}) -> !{fd: int} [io, error: NetError]
  fn connect({host: str, port: int}) -> !{fd: int} [io, error: NetError]
  fn recv({fd: int, max: int}) -> !{data: str} [io, error: NetError]
  fn send({fd: int, data: str}) -> !{sent: int} [io, error: NetError]
  fn close({fd: int}) -> void [io]
```

Design notes from that file worth keeping visible:

- **Every call suspends the calling task rather than blocking the
  process** — sockets have real readiness, so they reach the epoll/kqueue
  reactor. Measured flat to 32 concurrent connections on one thread.
- **A socket is a plain fd, so `on select | read fd | timeout {N.ms}` works
  on one directly** — that is the operation-timeout primitive (spec §9.3)
  applied to real network I/O rather than to a fixture. This is a genuinely
  better answer than the Nim design's per-socket `readTimeout=` setter.
- **An empty `recv` means the peer closed cleanly** — "that is not an
  error, so callers check `.len == 0` rather than matching a variant."

## What the Nim design adds that isn't there yet

- **UDP** — `openUdp`/`send`/`receive` with a `Packet` carrying its sender.
  Entirely absent from the real module.
- **Unix domain sockets** — `listenLocal`/`connectLocal`, which the Nim
  design deliberately routed to the *same* `Listener`/`TcpStream` types.
  That reasoning ("two more types earned nothing; the protocol-agnostic
  stream is the point") applies here for free, since everything is already
  `fd: int`.
- **`resolve(host, port)`** as a separate step — currently folded into
  `connect`, which is simpler but gives no way to see or choose among
  multiple addresses.
- **Half-close (`finishWriting`)** — needed by any protocol where the
  client signals "I'm done sending, now read my response."
- **`Address` as a type.** The real module passes `host: str, port: int`;
  the Nim design had a resolved `Address` value. Worth it only if `resolve`
  is added — otherwise the pair is fine.

## The one thing to be careful about
`recv` returns `str`, not `Seq[u8]`. That is convenient for line protocols
and wrong for binary ones — a `str` in Tuck is UTF-8-shaped by convention,
and arbitrary socket bytes are not. Either `recv` gains a `Seq[u8]` sibling
or the type is understood as "bytes that happen to be spelled `str`."
Worth deciding before `std.net-http` and `std.net-tls` build on it.
