# App: tls-cert-inspector

A CLI diagnostic tool: `certinspect example.com:443` connects, performs the TLS handshake, and prints the certificate chain (subject, issuer, validity window, SAN entries, signature algorithm), flags expiring-soon certificates (`--warn-days 30`), and reports whether the chain validates against the system trust store — the kind of tool an admin runs before `web-downloader`'s HTTPS requests would otherwise fail mysteriously.

## Why this is a good validation target
Every prior app that touched TLS (`web-downloader`, `podcast-subscriber`) used it as a black box — connect, get an encrypted stream, done. This app is the first to need to look *inside* the handshake: parse and display X.509 certificate contents, walk the certificate chain, and evaluate trust — which is a materially different, and previously unaddressed, surface of `std.net-tls`/`std.crypto`.

## Features
- Connect and complete a TLS handshake without immediately sending an application-layer request (a lower-level entry point than `std.net-http`'s "give me an HTTP response").
- Retrieve and parse the full certificate chain presented by the server.
- Display parsed certificate fields: subject/issuer distinguished names, validity window, Subject Alternative Names, public key algorithm and size, signature algorithm.
- Validate the chain against the OS/system trust store (and report specifically *why* if validation fails: expired, wrong hostname, untrusted root, incomplete chain).
- `--warn-days N`: exit non-zero and flag any certificate in the chain expiring within N days (a real use case: a pre-deploy CI check).

## Modules exercised
| Tier | Module | Why |
|---|---|---|
| std | `std.net-tls` | the module under direct stress — needs a handshake-only entry point and chain-inspection API, not just "wrap a socket and hand me ciphertext-free bytes" |
| std | `std.crypto` | X.509 certificate parsing (ASN.1/DER structure) — **a new parsing surface, see validation note** |
| sys | `sys.net` | the underlying TCP connection before TLS is layered on |
| std | `std.chrono` | validity-window comparison (`not_before`/`not_after` against now, and against `now + warn_days`) |
| std | `std.cli` | formatted certificate display, exit-code-driven CI-friendly output |
| core | `core.error` | precisely classifying *why* validation failed (expired vs. hostname mismatch vs. untrusted root vs. incomplete chain) as distinct, actionable cases — not one generic "TLS error" |

## Validation note: X.509 parsing is a new surface, and where it lives matters
No module drafted so far parses X.509/ASN.1 — `std.net-tls` has only ever been validated as an opaque stream-wrapping layer. This app forces the design to expose what's presumably already happening internally (the TLS implementation must parse certificates to do handshake validation at all) as a *public* API: `std.net-tls::PeerCertificate` with accessor methods for the fields above, backed by an ASN.1/DER decoder that reasonably belongs in `std.crypto` (X.509 is fundamentally a cryptographic data structure — public keys, signatures, extensions) rather than `std.encoding` (it's not a general-purpose interchange format a user would choose for their own data, unlike JSON/TOML/ICS). The proposed resolution keeps parsing in `std.crypto` (a `x509` submodule) and has `std.net-tls` re-export a read-only view of the negotiated chain through that type, so there is exactly one X.509 parser in the design, not two — directly following the same "don't duplicate a parser across modules" precedent `std.encoding.xml`'s `FeedReader` already established.
