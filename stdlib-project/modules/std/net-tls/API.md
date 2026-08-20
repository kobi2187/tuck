# std.net.tls

## Purpose
TLS wrapping any `sys.net` socket (or, more generally, any `sys.io` duplex stream), for both client and server roles, built on `std.crypto`'s in-language primitives — not an OpenSSL binding.

## Design lineage
Modeled on Go's `crypto/tls` (a `Conn` that wraps a `net.Conn` and itself implements `io.Reader`/`io.Writer`, so TLS is transparent to anything already written against the stream interfaces) and Rust's `rustls` for the in-language, memory-safe implementation stance — no dependency on a system OpenSSL/LibreSSL install, consistent with `std.crypto` never being an FFI wrapper.

## Proposed API
```
struct ClientConfig {
    root_certs: CertStore,                    // defaults to the platform trust store via sys.env/sys.fs
    server_name: Option<alloc::string::String>, // for SNI + hostname verification; inferred from URL if omitted
    min_version: Version,                       // default TLS 1.2, TLS 1.3 preferred when both ends support it
    alpn: alloc::vec::Vec<alloc::string::String>,
}
struct ServerConfig {
    cert_chain: alloc::vec::Vec<Certificate>,
    private_key: PrivateKey,
    client_auth: ClientAuth,                    // None | Optional | Required(CertStore)
}
enum Version { Tls12, Tls13 }
enum ClientAuth { None, Optional, Required(CertStore) }

struct Conn<S: sys::io::Reader + sys::io::Writer>;   // wraps any duplex stream — a raw sys.net socket, typically
impl<S: sys::io::Reader + sys::io::Writer> Conn<S> {
    fn client(stream: S, cfg: &ClientConfig) -> core::types::Result<Conn<S>, TlsError>;   // performs handshake, validates chain
    fn server(stream: S, cfg: &ServerConfig) -> core::types::Result<Conn<S>, TlsError>;

    // Added for tls-cert-inspector: complete the handshake and expose the negotiated chain WITHOUT
    // sending any application data — a lower-level entry point than Client::client's "handshake
    // then hand me a Reader/Writer for HTTP" shape. Chain validation still runs (so ChainError is
    // still reported precisely) but a HandshakeFailed(ChainError) does not prevent the caller from
    // inspecting what was actually presented — see decisions below.
    fn handshake_only(stream: S, cfg: &ClientConfig) -> HandshakeResult<S>;

    fn negotiated_alpn(&self) -> Option<&str>;
    fn peer_certificates(&self) -> &[std::crypto::x509::Certificate];   // re-exported type, see decisions
    fn close_notify(self) -> core::types::Result<S, TlsError>;   // sends TLS close_notify, returns inner stream
}
impl<S: sys::io::Reader + sys::io::Writer> sys::io::Reader for Conn<S> { /* decrypting pull */ }
impl<S: sys::io::Reader + sys::io::Writer> sys::io::Writer for Conn<S> { /* encrypting push */ }

// handshake_only's return: unlike Conn::client's Result<Conn<S>, TlsError> (which discards the
// chain entirely on a validation failure — fine for "give me an HTTP connection or don't", wrong
// for "show me what's wrong with this certificate"), the negotiated chain is available whether or
// not it validated, since inspecting an invalid chain is the whole point of this entry point.
struct HandshakeResult<S: sys::io::Reader + sys::io::Writer> {
    chain: alloc::vec::Vec<std::crypto::x509::Certificate>,   // always populated if a handshake completed at all
    validation: core::types::Result<(), ChainError>,           // Ok if trusted; structured reason if not
    conn: Option<Conn<S>>,                                      // Some only if validation was Ok — never hand back a connection over an untrusted chain
}

// Re-exported from std.crypto::x509 — std.net-tls does not define a second CertStore/Certificate
// type. See std.crypto's x509 submodule for the full Certificate/CertStore API surface.
use std::crypto::x509::{Certificate, CertStore};

struct PrivateKey(std::crypto::ed25519::SigningKey); // or RSA/ECDSA variant per key type loaded

// Added for tls-cert-inspector: distinct, actionable failure cases instead of one generic
// CertificateInvalid — this is std.net-tls's own type (not std.crypto::x509::X509Error, which
// covers malformed-DER parse failures, a different and earlier failure class — see std.crypto's
// decisions for why parse and trust errors are kept separate).
enum ChainError {
    Expired { cert_index: usize, not_after: std::chrono::ZonedDateTime },
    HostnameMismatch { expected: alloc::string::String, san_entries: alloc::vec::Vec<alloc::string::String> },
    UntrustedRoot,
    IncompleteChain,   // server didn't present enough intermediates to build a path to a trusted root
}

enum TlsError { HandshakeFailed(alloc::string::String), CertificateInvalid(ChainError),
                 ProtocolVersion, Closed }
// Note: the prior design had both a bare `CertificateInvalid` variant and a separate
// `HostnameMismatch` variant on TlsError — collapsed into one `CertificateInvalid(ChainError)`
// this round, since ChainError::HostnameMismatch already carries that case with more detail
// (expected name + actual SAN entries) than the old unit variant could.
```

## Key design decisions
- **`Conn<S>` is generic over any `S: sys::io::Reader + sys::io::Writer`, not tied to `sys.net`'s socket type** — this lets `std.net.http`'s client/server wrap a `Conn` exactly where it would otherwise use a raw socket, with zero special-casing, and in principle lets TLS wrap a Unix-domain socket or even an in-memory duplex pipe for testing, matching Design Principle 3 directly.
- **TLS 1.3 is preferred whenever both ends support it and TLS 1.2 is the floor** — no SSL 3.0/TLS 1.0/1.1 code path exists at all, removing an entire category of downgrade-attack surface by construction rather than by configuration discipline, echoing `std.crypto`'s "hard to call insecurely" stance.
- **Certificate/hostname verification is always on**; there is no `insecure_skip_verify`-style flag in `ClientConfig` — a caller who genuinely needs to trust a custom CA does so via `CertStore::add`/`from_pem_file`, never by disabling verification, which closes off the single most common TLS misuse pattern seen across other languages' TLS APIs.
- **`Conn::close_notify` returns the inner stream `S`** rather than just closing it — this matters for protocols that need to reuse or inspect the underlying transport after a graceful TLS shutdown (e.g. connection-pool reuse in `std.net.http`'s client), keeping the wrap/unwrap symmetric.
- **Added for tls-cert-inspector: `Certificate`/`CertStore` are re-exports of `std.crypto::x509`'s types, not a second definition.** Before this round, `std.net-tls` defined its own `struct Certificate(Vec<u8>)` (an opaque DER blob with no accessors) and its own `CertStore`, because the module had only ever been validated as a stream-wrapping black box — nothing needed to look inside a certificate. `tls-cert-inspector` needs exactly that, and the resolution follows its own validation note directly: rather than growing a second, TLS-specific certificate type with its own subject/issuer/SAN accessors (duplicating `std.crypto::x509::Certificate` field-for-field, and risking the two drifting apart), `std.net-tls::Certificate` and `CertStore` are now `use std::crypto::x509::{Certificate, CertStore}` — literally the same type, re-exported for call-site convenience so `std.net-tls` consumers don't need to import `std.crypto` directly for the common case. `peer_certificates()` returns `&[std::crypto::x509::Certificate]` directly, so every accessor (`subject()`, `not_after()`, `subject_alt_names()`, ...) `tls-cert-inspector` needs is already there with no new surface on the `net-tls` side at all — the module's own job stays "negotiate the connection and hand back what was presented," not "also know how to read a certificate."
- **`handshake_only` is a genuinely separate entry point from `Conn::client`, not a flag on it, because the two have incompatible failure-handling contracts.** `Conn::client` is the "give me a working HTTP connection or an error" shape every prior TLS consumer (`web-downloader`, `podcast-subscriber`) needs — on a chain-validation failure it must not hand back a connection at all, and discarding the invalid chain along with the error is correct there (nothing downstream would ever want to inspect a chain it's about to refuse to use). `tls-cert-inspector`'s entire purpose inverts that: it wants exactly the case `Conn::client` throws away — a completed handshake with an *invalid* chain, so it can report why. Making this one function with a "keep the chain even on failure" boolean flag would mean every ordinary caller of `Conn::client` carries a flag they never set and a `HandshakeResult`-shaped return they don't want; a separate `handshake_only` returning `HandshakeResult<S>` (chain always populated if a handshake happened at all, `validation: Result<(), ChainError>` independent of whether `conn` is populated) keeps the common case's signature untouched and gives the inspection case exactly the shape it needs — `conn: Option<Conn<S>>` is deliberately `None` whenever `validation` is `Err`, so it remains structurally impossible to accidentally read/write application data over a chain that didn't validate, even from this lower-level entry point.
- **`ChainError` is a closed enum with four distinct, data-carrying cases (`Expired`/`HostnameMismatch`/`UntrustedRoot`/`IncompleteChain`), not one generic `CertificateInvalid` unit variant** — `tls-cert-inspector`'s core reporting requirement ("report specifically *why* if validation fails") is inexpressible against the prior design, which collapsed every trust failure into one undifferentiated case. Each variant carries the data needed to act on it without re-deriving it (`Expired` carries which certificate in the chain and its `not_after`; `HostnameMismatch` carries both the expected name and the actual SAN entries presented, so a diagnostic tool can show the mismatch directly rather than requiring the caller to re-fetch the certificate to explain its own error) — matching this project's established stance (see `sys.process::ExitStatus`, Extension round 1) that a closed enum forcing exhaustive handling beats an opaque struct with independently-nullable accessors whenever a caller's correct behavior genuinely differs by case, which a pre-deploy CI check (`--warn-days`, "fail the build, but tell the log *why*") is a clean example of.

## Validated by applications
- **web-downloader**: the direct exercise for the client half — HTTPS downloads go through `std.net.http::Client`, which internally does `Conn::client(tcp_socket, &cfg)` per connection; `CertStore::platform_defaults()` is exercised as-is (the app never supplies custom certs), validating the zero-configuration default path works for ordinary public-internet downloads.
- **podcast-subscriber**: exercises the same client path as web-downloader but against many different hosts per poll cycle, which stresses `ClientConfig::server_name`/SNI inference from each feed's URL and confirms connection setup doesn't require the caller to manually thread hostname state through each `Conn::client` call.
- **chat-server**: does not use `std.net.tls` (the app is deliberately plaintext TCP to isolate the `sys.net` exercise) — a useful negative validation that `std.net.tls` imposes no cost or requirement on `sys.net` consumers who don't opt in, and that `Conn<S>`'s generic-over-any-duplex-stream design didn't have to leak into `sys.net` itself to exist.
- **secrets-vault**: does not use networking, confirming (alongside `std.net.http`'s equivalent note) that constructing zero `Conn`/`Client`/`Server` values costs nothing at runtime for a purely local application.
- **tls-cert-inspector**: the app that finally exercises this module below the "opaque encrypted stream" layer — the direct forcing case for `handshake_only`, the `Certificate`/`CertStore` re-export from `std.crypto::x509`, and `ChainError`'s four distinct cases (see decisions above). `certinspect example.com:443` opens a raw `sys.net` TCP connection, calls `Conn::handshake_only(stream, &cfg)`, and always prints `result.chain` regardless of `result.validation` (an expired or self-signed certificate is exactly the interesting case an admin runs this tool to see, not a case to hide behind an error). `--warn-days N` reads `not_after()` off every certificate in the chain via the re-exported `x509::Certificate` accessors directly, and the tool's exit code is driven by matching on `result.validation`'s `ChainError` (or its absence) — `Expired`/`HostnameMismatch`/`UntrustedRoot`/`IncompleteChain` each map to a distinct printed diagnosis, confirming the closed-enum design serves the "tell me exactly why" requirement the app's profile states directly, not just in the abstract.

## Open questions / risks
Whether `std.net.tls` should expose session-resumption/ticket controls for high-connection-churn servers (relevant to a hypothetical much-larger `chat-server`-shaped app under real TLS) is left unaddressed by the current apps, since none of the eleven actually terminates TLS server-side under load; this is flagged as untested by the app corpus rather than resolved.
