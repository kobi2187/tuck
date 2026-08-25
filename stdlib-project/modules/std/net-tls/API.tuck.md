# std.net-tls — Tuck translation

## Shape decision
Freeform `pending:` over an `fd: int` handle, so a TLS socket is the same
kind of thing as a plain one. **Compiler-verified**, `./tuck ch`: `OK`.

## The API

```tuck
type TlsError:
  | Expired
  | HostnameMismatch
  | UntrustedRoot
  | IncompleteChain

type CertInfo = {subject: str, issuer: str, notBeforeMs: u64, notAfterMs: u64}

pending:
  fn connectTls({host: str, port: int, verify: bool}) -> !{fd: int} [io, error: TlsError]
  fn handshakeOnly({host: str, port: int}) -> !{chain: Seq[CertInfo]} [io, error: TlsError]
  fn verifyChain({chain: Seq[CertInfo], host: str}) -> TlsError?
```

## Notes
- **`ChainError`'s four variants become `TlsError`**, closed and exhaustive
  — round-3's addition for `tls-cert-inspector`, unchanged. A caller
  matching on them cannot forget one.
- **A TLS connection is an `fd`**, so everything in `sys.net` and `sys.io`
  works on it unchanged. That is the same "protocol-agnostic stream" point
  the Nim design made for Unix sockets, and it costs nothing here.
- **`handshakeOnly` survives** — inspecting a certificate chain without
  sending application data is exactly what a diagnostic tool needs.
- **`verify: bool` is a deliberate footgun to keep visible.** Disabling
  verification is sometimes legitimate (self-signed staging servers) and
  always dangerous; a named argument at the call site is better than a
  builder method buried three lines up.
- **Certificate parsing belongs to `std.crypto::x509`**, which is deferred
  — this module re-exports the type rather than defining a second parser,
  continuing round-0's "one parser, not two" rule.
