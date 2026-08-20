# std.crypto

## Purpose
In-language (not OpenSSL-wrapped) cryptographic primitives — hashing, MACs, AEAD ciphers, X25519/Ed25519, Argon2id key derivation, constant-time comparison, and a CSPRNG — designed so the easy way to call each function is also the secure way.

## Design lineage
Modeled directly on Zig's `std.crypto` for scope and for being implemented in-language rather than a thin FFI shim over a C library, and on libsodium's misuse-resistant ergonomics: high-level functions default to safe choices (random nonce generation, authenticated encryption only, no bare unauthenticated cipher exposed at the top level) so that calling them "the normal way" is hard to get wrong, rather than exposing raw primitives that are correct only when combined exactly right.

## Proposed API
```
// Hashing — one call shape per algorithm family, all producing fixed-size digests.
mod hash {
    fn sha256(data: &[u8]) -> [u8; 32];
    fn sha3_256(data: &[u8]) -> [u8; 32];
    fn blake3(data: &[u8]) -> [u8; 32];
    struct Hasher;                                   // streaming variant for large/unbounded input
    impl Hasher {
        fn new(alg: HashAlg) -> Hasher;
        fn write(&mut self, chunk: &[u8]);
        fn finish(self) -> [u8; 32];
    }
}

// MACs
mod mac {
    fn hmac_sha256(key: &[u8], data: &[u8]) -> [u8; 32];
}

// AEAD — the only symmetric-encryption entry point; there is no bare block-cipher API in std.crypto.
mod aead {
    struct Key([u8; 32]);                            // opaque; zeroized on drop (see decisions)
    fn generate_key() -> Key;                         // uses std.crypto::rng, not std.random
    fn seal(key: &Key, plaintext: &[u8], aad: &[u8]) -> Sealed;   // random nonce generated internally
    fn open(key: &Key, sealed: &Sealed, aad: &[u8]) -> core::types::Result<alloc::vec::Vec<u8>, CryptoError>;
    struct Sealed { nonce: [u8; 24], ciphertext: alloc::vec::Vec<u8> }  // XChaCha20-Poly1305 by default
}

// Key derivation from low-entropy input (passphrases) — memory-hard, Argon2id only exposed.
mod kdf {
    struct Params { mem_kib: u32, iterations: u32, parallelism: u32 }   // sane default via Params::default()
    fn derive_key(passphrase: &[u8], salt: &[u8; 16], params: &Params) -> aead::Key;
    fn recommended_params() -> Params;                // tuned per Design Decisions below
}

// Asymmetric: key exchange + signatures
mod x25519 {
    struct SecretKey([u8; 32]); struct PublicKey([u8; 32]);
    fn generate() -> (SecretKey, PublicKey);
    fn diffie_hellman(sk: &SecretKey, pk: &PublicKey) -> [u8; 32];
}
mod ed25519 {
    struct SigningKey([u8; 32]); struct VerifyingKey([u8; 32]); struct Signature([u8; 64]);
    fn generate() -> (SigningKey, VerifyingKey);
    fn sign(sk: &SigningKey, msg: &[u8]) -> Signature;
    fn verify(pk: &VerifyingKey, msg: &[u8], sig: &Signature) -> bool;
}

// Constant-time comparison — the only correct way to compare secrets/tags/MACs.
fn ct_eq(a: &[u8], b: &[u8]) -> bool;

// CSPRNG — deliberately its own namespace, never std.random's.
mod rng {
    fn fill(buf: &mut [u8]);                          // OS CSPRNG-backed
    fn bytes(n: usize) -> alloc::vec::Vec<u8>;
}

// Added for tls-cert-inspector — X.509/ASN.1 certificate parsing. Lives here, not std.encoding
// (not a general-purpose interchange format a caller would choose for arbitrary data — it's a
// fixed, cryptographic wire structure, the same reasoning that keeps unified-diff out of
// std.encoding for the opposite-shaped reason) and not duplicated inside std.net-tls (see that
// module's re-export of Certificate rather than a second parser/type).
mod x509 {
    // Parses a DER-encoded certificate. PEM input (the common on-disk/copy-pasted form) is
    // base64-with-armor over DER — callers go through std.encoding.base::decode64 on the
    // stripped PEM body first, so x509 itself only ever parses one wire shape (DER), not two.
    struct Certificate;
    impl Certificate {
        fn parse_der(der: &[u8]) -> core::types::Result<Certificate, X509Error>;

        fn subject(&self) -> DistinguishedName;
        fn issuer(&self) -> DistinguishedName;
        fn not_before(&self) -> std::chrono::ZonedDateTime;
        fn not_after(&self) -> std::chrono::ZonedDateTime;
        fn subject_alt_names(&self) -> alloc::vec::Vec<SanEntry>;
        fn signature_algorithm(&self) -> SignatureAlgorithm;
        fn public_key_algorithm(&self) -> PublicKeyAlgorithm;
        fn public_key_bits(&self) -> u32;                       // e.g. 2048, 4096 (RSA), 256 (EC/Ed25519)
        fn is_ca(&self) -> bool;                                 // BasicConstraints CA:TRUE
        fn der_bytes(&self) -> &[u8];                            // the original encoded form, for re-verification/pinning

        // Verification is a free function, not a method, because it inherently needs the whole
        // chain plus a trust anchor set — a single Certificate has no self-contained notion of
        // "valid" in isolation (see std.net-tls's ChainError for the structured failure reasons
        // this returns).
    }
    fn verify_chain(chain: &[Certificate], roots: &CertStore, hostname: &str, at: std::chrono::ZonedDateTime)
        -> core::types::Result<(), ChainError>;

    struct DistinguishedName;   // subject/issuer, RFC 4514-ish
    impl DistinguishedName {
        fn common_name(&self) -> Option<&str>;
        fn organization(&self) -> Option<&str>;
        fn to_string(&self) -> alloc::string::String;   // full "CN=...,O=...,C=..." form
    }
    enum SanEntry { Dns(alloc::string::String), Ip(alloc::string::String), Email(alloc::string::String) }
    enum SignatureAlgorithm { RsaSha256, RsaSha384, EcdsaSha256, EcdsaSha384, Ed25519 }
    enum PublicKeyAlgorithm { Rsa, EcdsaP256, EcdsaP384, Ed25519 }

    // Named enum, not a re-thrown parse-vs-validate ambiguity — parse errors (malformed DER) and
    // trust errors (a well-formed but untrustworthy cert) are deliberately different error types
    // (X509Error vs. ChainError), since a caller handles "can't even read this" and "read it fine,
    // don't trust it" very differently (see std.net-tls's ChainError for the latter's own cases).
    enum X509Error { MalformedDer, UnsupportedAlgorithm, TruncatedInput }

    // Trust-anchor container lives here (a set of X.509 certificates is exactly what it is — a
    // cryptographic data structure, not a TLS-specific concept), not in std.net-tls, so both
    // Certificate and its trust store have one home; std.net-tls re-exports this type rather than
    // defining a second one (see that module's decisions).
    struct CertStore;
    impl CertStore {
        fn platform_defaults() -> CertStore;                                            // OS trust store
        fn from_pem_file(path: &sys::fs::Path) -> core::types::Result<CertStore, X509Error>;
        fn add(&mut self, cert: Certificate);
    }
}

enum CryptoError { AuthenticationFailed, InvalidKeyLength, InvalidParams }
```

## Key design decisions
- **Only AEAD ciphers are exposed for symmetric encryption — no raw block-cipher/CBC/CTR API exists at the top level of `std.crypto`.** This directly reconciles the three apps' otherwise-different needs into one shape: `secrets-vault` (encrypt-at-rest), `archive-cli` (per-entry encryption), and any future TLS-adjacent use all call `aead::seal`/`aead::open`, never a lower-level primitive that could be composed incorrectly (e.g. reused nonce, unauthenticated ciphertext). `Sealed` always carries its nonce and is always authenticated; there is no way to produce ciphertext without a tag.
- **`kdf::derive_key` returns an `aead::Key` directly**, not raw bytes — passphrase-derived key material never exists as a bare `[u8; N]` the caller could accidentally mishandle (log, hash again, compare non-constant-time); it is immediately typed as the thing it's for. `secrets-vault`'s master-passphrase flow is `kdf::derive_key(passphrase, salt, &params) -> Key`, then that `Key` feeds `aead::seal`/`open` with no intermediate representation.
- **Hashing (`std.crypto.hash`, for content-integrity checksums like `web-downloader`'s SHA-256 verification) is namespaced separately from `aead`/`kdf`** even though it lives in the same module, because a checksum is not a secret and callers should not need to reach for key-management types to hash a downloaded file.
- **`Key`, `SecretKey`, and `SigningKey` are zeroized on drop and never implement `Debug`/`Display`** — this is the module's answer to the question `secrets-vault`'s app profile raises about `alloc.string`/`alloc.vec` zeroization: `std.crypto` owns "can this secret be zeroized," not `alloc`. Plaintext vault contents in transit through `std.encoding` still rely on the caller discarding buffers promptly; `std.crypto` guarantees only its own key/secret types, not arbitrary application buffers.
- **Added for tls-cert-inspector: X.509/ASN.1 certificate parsing lives in `std.crypto` as a new `x509` submodule, not in `std.encoding` and not duplicated inside `std.net-tls`.** This app is the first to need to look *inside* a TLS handshake rather than treat it as an opaque encrypted stream, and X.509 parsing didn't previously exist as a public surface anywhere in the design — `std.net-tls`'s `Conn` must already be parsing certificates internally to do handshake validation at all, but nothing exposed that structure to a caller. Placement follows the app's own validation note directly: `std.encoding` is for general-purpose, user-chosen interchange formats (JSON/TOML/CSV/XML/ICS — formats a caller picks to serialize *their own* arbitrary data), and X.509 fails that test the same way unified-diff does for the opposite reason — it's not a format a caller would ever choose to serialize arbitrary application data into, it's a fixed cryptographic wire structure (public keys, signatures, validity constraints, extensions) that only ever means one specific thing. It belongs with the rest of this module's asymmetric-crypto surface (`x25519`/`ed25519`) instead: a certificate is fundamentally "a public key plus a signature plus metadata," which is squarely `std.crypto`'s domain. Keeping it here (rather than inside `std.net-tls`) also avoids a second implementation: `std.net-tls` already depends on `std.crypto` for its handshake primitives (see "Validated by applications" below), so having `std.net-tls::Certificate` simply *be* `std.crypto::x509::Certificate` (re-exported, not redefined — see that module's own decisions) means there is exactly one X.509 parser in the whole design, the same "one parser, not two" precedent `std.encoding.xml::FeedReader` set for RSS/Atom over `XmlReader` and `std.encoding.ics` repeats this round for RRULE over `std.chrono::Recurrence`.
- **`x509::verify_chain` is a free function taking the whole chain plus a trust-anchor set, not a method on a single `Certificate`** — trust is a property of a chain-plus-context (root store, hostname, point in time), never of one certificate in isolation, so there is deliberately no `cert.is_valid()`-shaped method that could be called correctly-looking but meaninglessly on a single leaf certificate with no chain or trust anchor behind it.
- **Parse failures (`X509Error`: malformed DER) and trust failures (`ChainError`, defined in `std.net-tls`: expired/hostname-mismatch/untrusted-root/incomplete-chain) are two distinct error enums, not one generic error type reused for both** — `tls-cert-inspector`'s core reporting requirement is telling an admin *which* of those happened, and collapsing "this byte stream isn't even a certificate" into the same error shape as "this is a well-formed certificate I don't trust" would make that reporting a string-matching exercise instead of an exhaustive `match`.

## Validated by applications
- **secrets-vault**: exercises `kdf::derive_key` (Argon2id from a low-entropy passphrase, tuned via `recommended_params()`), `aead::seal`/`open` for the whole-file encrypted vault (AAD binds a format-version byte so old/new vault formats can't be silently cross-decrypted), and `rng::bytes` for generated-password charset sampling — explicitly *not* `std.random`, which is the app's core validation of the crypto/non-crypto PRNG separation.
- **archive-cli**: exercises the same `kdf`+`aead` pair as secrets-vault but per-archive-entry rather than whole-file — validates that `aead::seal`/`open`'s per-call (not per-session) design supports many independent small encryptions without re-deriving the key each time (`derive_key` once, `seal` per entry), and that `Sealed`'s self-contained nonce means entries can be extracted independently/out of order.
- **web-downloader**: uses only `hash::sha256`/`hash::Hasher` (streaming, since checksums are computed over data as it's written to disk, not buffered whole) to verify user-supplied expected hashes — confirms the hashing namespace is usable with zero exposure to `aead`/`kdf`/`Key` types for the (common) case of "just checksum this download."
- **net-tls** (module-to-module dependency): `std.net.tls` calls into `x25519` and `ed25519` for the handshake and certificate verification, meaning `std.crypto`'s asymmetric primitives are validated by a second `std` module's production use, not only by apps directly.
- **tls-cert-inspector**: the originating case for `x509` above — `certinspect example.com:443` parses every certificate `std.net-tls::Conn::peer_certificates()` returns via `x509::Certificate::parse_der` (already done internally by the handshake, exposed here as the same values), reads subject/issuer/validity/SAN/signature-algorithm off each one for display, and calls `x509::verify_chain` explicitly (rather than relying only on the handshake's own internal validation) so it can report *why* a chain fails using `ChainError`'s distinct cases — expired, hostname mismatch, untrusted root, incomplete chain — instead of one generic failure. `--warn-days N` is `not_after()` compared against `std.chrono::ZonedDateTime::duration_until` plus `N` days, confirming `std.chrono` and `std.crypto::x509` compose without either module needing to know about the other's internals.
- **image-thumbnailer**: exercises `hash::blake3` (or `hash::sha256`) as a skip-if-unchanged cache key — hashing each source image's bytes to decide whether its thumbnail is stale, stronger than an mtime comparison alone since a touched-but-unchanged file shouldn't trigger a re-encode. Same non-secret hashing namespace `web-downloader` already validates (no `aead`/`kdf`/`Key` exposure needed); the one new wrinkle is that this app hashes many files as routine, repeated, non-security-critical work rather than verifying one user-supplied checksum, which is a call-frequency observation rather than a design gap — `hash::sha256`/`blake3` are plain functions with no session/key setup cost to amortize either way.

## Open questions / risks
Whether to expose a lower-tier "raw primitives" escape hatch (e.g. bare ChaCha20 without Poly1305) for protocol implementers who genuinely need it, gated behind an unmistakably-named `std.crypto.unsafe_primitives` submodule, or to keep the surface closed entirely and push that need to the extended ecosystem, is unresolved — Zig takes the former approach; this design currently leans toward the latter to preserve the misuse-resistance guarantee unconditionally.
