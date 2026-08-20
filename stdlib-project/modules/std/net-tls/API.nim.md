# std.net-tls — Nim API

## Purpose
Wrap any two-way stream in TLS, for either side of a connection, using `std.crypto`'s own primitives — no system OpenSSL, no build-time C dependency. Verification is always on; there is no flag to turn it off.

## Protocols implemented
`TlsStream` is `Resource` and `Streamable`. That is deliberately all of it: once the handshake is done, TLS is invisible, so anything already written against `read`/`write` works unchanged.

## The API

```nim
type
  Version* = enum Tls12, Tls13       ## there is no code path for anything older
  ClientAuth* = enum NoClientCert, OptionalClientCert, RequiredClientCert
  TlsStream* = object
  Handshake* = object
    ## What `greet` gives back: what the server presented, whether it holds up,
    ## and a usable stream only if it does.
    chain*: List[Certificate]        ## always filled if a handshake completed at all
    problem*: Option[ChainProblem]   ## none means trusted
    stream*: Option[TlsStream]       ## some only when `problem` is none

proc openTls*(inner: var Streamable; serverName: TextView;
              roots = platformRoots(); minVersion = Tls12;
              alpn: openArray[string] = []): TlsStream
  ## Client side. Handshakes, checks the chain and the hostname, and hands back a
  ## stream — or raises, carrying the `ChainProblem` on the `Failure`.
proc tryOpenTls*(inner: var Streamable; serverName: TextView; ...): Option[TlsStream]

proc serveTls*(inner: var Streamable; chain: openArray[Certificate];
               key: PrivateKey; clientAuth = NoClientCert): TlsStream
  ## Server side.

proc greet*(inner: var Streamable; serverName: TextView;
            roots = platformRoots()): Handshake
  ## Handshake and stop. A separate entry point from `openTls`, not a flag on it,
  ## because the two have opposite contracts: `openTls` throws the chain away when
  ## it fails to validate, and inspecting a chain that failed is this one's whole job.

proc read*(t: var TlsStream; n: int): List[byte]     ## Streamable, decrypting
proc write*(t: var TlsStream; data: View[byte]): int ## Streamable, encrypting
proc close*(t: var TlsStream)                        ## sends close_notify; idempotent
proc isOpen*(t: TlsStream): bool
proc unwrap*(t: sink TlsStream): Streamable          ## take the plain stream back
func alpn*(t: TlsStream): Option[TextView]
func peerCertificates*(t: TlsStream): View[Certificate]

# Re-exported from std.crypto's x509 submodule — not redefined here.
export Certificate, CertStore, ChainProblem, platformRoots
```

`ChainProblem` is a closed enum with data on every case: `Expired(which, notAfter)`, `HostnameMismatch(expected, presented)`, `UntrustedRoot`, `IncompleteChain`. A `case` over it is exhaustive, so `tls-cert-inspector`'s "tell me *why*" turns into four printed diagnoses rather than one string comparison.

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `Conn<S>` | `TlsStream` | Says what it is and what it does. `Conn` could be any layer of the stack. |
| `Conn::client(s, cfg)` | `openTls(inner, serverName =, ...)` | The vocabulary's acquire verb, with everything `ClientConfig` held as trailing named arguments. No config struct to build for the common case. |
| `Conn::server(s, cfg)` | `serveTls` | Pairs audibly with `openTls`, and the verb says which side you are. |
| `handshake_only` | `greet` | One friendly word for "say hello and stop there", and it doesn't read as a boolean-flavoured variant of the normal path. |
| `HandshakeResult<S>` | `Handshake` | What `greet` gives back. `Result` is a word this library no longer has. |
| `ChainError` | `ChainProblem` | `core.error`'s `Failure` is the error type; this is the *reason*, carried on it. Renaming avoids implying a second error mechanism. |
| `close_notify() -> S` | `close` + `unwrap` | `close` is the protocol verb and returns nothing; `unwrap` separately recovers the inner stream for pool reuse. Same split as `std.compress`. |
| `negotiated_alpn` | `alpn` | The only ALPN anyone asks about is the negotiated one. |
| `ClientConfig` / `ServerConfig` | *(gone)* | Two structs whose every field became a named argument on the call that needed it. |

## In use

```nim
# tls-cert-inspector: print what was presented, whether or not it validates
let shake = socket.greet(serverName = host)
for cert in shake.chain:
  echo cert.subject().commonName().get("?"), "  ", cert.goodFrom(), " .. ", cert.goodUntil()
  if cert.goodUntil().until(now().inZone(here)) < warnDays.days:
    echo "  expiring within ", warnDays, " days"; exitCode = 1
shake.problem.ifSome(p):
  case p.kind
  of Expired:          echo "cert ", p.which, " expired ", p.notAfter
  of HostnameMismatch: echo "wanted ", p.expected, ", got ", p.presented
  of UntrustedRoot:    echo "root not in the system store"
  of IncompleteChain:  echo "server did not send enough intermediates"

# web-downloader (indirect): std.net-http wraps every https:// socket for you
let client = newClient()               # platformRoots(), Tls12 floor, verification on
```

## Vocabulary exceptions
`greet`, `serveTls` and `unwrap` are domain verbs. `greet` earns its place because the alternative — `openTls(..., keepChainOnFailure = true)` — would put a flag on the common path that ninety-nine callers in a hundred never set, and would change `openTls`'s return type for all of them.

**`Handshake.stream` is `none` whenever `problem` is `some`.** That invariant is the reason the type exists: even from this deliberately lower-level entry point it stays structurally impossible to read or write application data over a chain that did not validate. `tls-cert-inspector` gets the chain it came for and no connection it should not have.

**There is no `insecureSkipVerify`.** A caller who genuinely needs to trust a private CA does it by `add`ing to a `CertStore` — a `Collection` operation on a value they name — never by switching verification off. This closes the single most common TLS misuse in every other language's binding, by not shipping the switch.
