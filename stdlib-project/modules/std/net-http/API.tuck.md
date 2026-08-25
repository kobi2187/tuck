# std.net-http — Tuck translation

## Shape decision
Freeform `pending:` verbs over `Seq[Header]` and plain records.
**Compiler-verified**, `./tuck ch`: `OK`.

## The API

```tuck
type Method:
  | Get
  | Post
  | Put
  | Delete
  | Head
  | Patch

type Header = {name: str, value: str}
type Response = {status: int, headers: Seq[Header], body: Seq[u8]}

type SameSite:
  | Strict
  | Lax
  | NoneSite

type Cookie = {name: str, value: str, path: str, domain: str, maxAgeSec: i64, httpOnly: bool, secure: bool, sameSite: SameSite}

type HttpError:
  | Timeout
  | ConnectionFailed
  | BadStatusLine
  | TooLarge

pending:
  fn fetch({url: str, verb: Method, headers: Seq[Header], body: Seq[u8], timeoutMs: u32}) -> !Response [io, error: HttpError]
  fn headerOf({r: Response, name: str}) -> str?
  fn cookiesOf({headers: Seq[Header]}) -> Seq[Cookie]
  fn setCookieHeader({c: Cookie}) -> Header
  fn serve({port: int, handler: str}) -> !void [io, error: HttpError]
```

## Notes
- **`fetch` keeps its name and its reasoning.** Round-4's sharpest naming
  call: `get` promises "absence returns `?`, never raises," and an HTTP
  request raises on timeout and refusal — so calling it `get` would promise
  the wrong failure mode on the library's most-used network call. Tuck's
  `!Response [error: HttpError]` makes that failure surface explicit in the
  signature, which strengthens the argument.
- **`Headers` becomes `Seq[Header]`**, not a map — `alloc.map` is blocked
  on key hashing, and HTTP headers are order-significant and repeatable
  (`Set-Cookie` appears many times), so a list is arguably more correct
  anyway.
- **`Cookie` and the session example carry over** from round 4 — the type
  was the real gap; signed sessions stay a composition over
  `std.crypto::hmacSha256` + `sameSecret` rather than a `Session` type.
- **`NoneSite` rather than `None`** — `None` collides with nothing in Tuck
  today but reads as an optional; renamed for clarity.
- **The body is `Seq[u8]`, not a stream.** The Nim design streamed response
  bodies so a large download never buffered. Without stream types that
  guarantee is gone — `web-downloader`'s "never buffer the file" property
  needs the `fd: int` handle route (`fetchTo({url, destFd})`) instead.
  Same shape as `std.compress`'s lost streaming form; worth solving once,
  consistently.
- **`serve`'s handler is a placeholder.** A real signature needs a `fnsig`
  taking a request and returning a response — expressible, but the routing
  layer (`Routes`, `wrap` for middleware) is a bigger design than a
  translation pass should invent. Deferred.
