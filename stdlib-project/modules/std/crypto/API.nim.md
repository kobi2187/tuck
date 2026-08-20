# std.crypto — Nim API

## Purpose
Hashing, authenticated encryption, signatures, passphrase-hardening and certificates — written in Nim, not wrapped around OpenSSL — shaped so the obvious call is the safe one. There is no bare block cipher, no unauthenticated ciphertext, and no way to read a key back out as plaintext.

## Protocols implemented
Two, and thinly: `Digest` is `Streamable` (the write half — you feed it bytes, you never read bytes back), and `CertStore` is a `Collection[Certificate]`. **Everything else is domain verbs.** `Key`, `PrivateKey` and `SigningKey` deliberately implement neither `Gettable` nor `Settable`: a key you can `get` out as plaintext is the design failure this module exists to prevent.

## The API

```nim
type
  Key* = object          ## AEAD key. Zeroed by `=destroy`. No `show`, no `$`, no `get`.
  Sealed* = object       ## nonce + ciphertext + tag, always together
    nonce*: array[24, byte]
    ciphertext*: List[byte]
  HashKind* = enum Sha256, Sha3_256, Blake3
  Digest* = object       ## streaming hasher; `Streamable`, write half only
  Work* = object         ## how expensive one passphrase guess should be
    memoryKib*, rounds*, lanes*: uint32

func sha256*(data: View[byte]): array[32, byte]
func blake3*(data: View[byte]): array[32, byte]
proc newDigest*(kind = Sha256): Digest
proc write*(d: var Digest; data: View[byte]): int    ## Streamable
proc finish*(d: sink Digest): array[32, byte]
func hmacSha256*(key, data: View[byte]): array[32, byte]

proc newKey*(): Key                                   ## from the OS CSPRNG, never from std.random
proc keyFromPassphrase*(pass: SecretText; salt: array[16, byte];
                        work = recommendedWork()): Key
  ## Argon2id. Returns a `Key`, never raw bytes — passphrase material is typed as
  ## what it is for the instant it exists.
func recommendedWork*(): Work

proc seal*(key: Key; plaintext, alongside: View[byte]): Sealed
  ## Encrypt-and-authenticate. The nonce is generated inside; you cannot reuse one.
  ## `alongside` is authenticated but not encrypted (a format-version byte, an entry name).
proc unseal*(key: Key; box: Sealed; alongside: View[byte]): List[byte]
  ## Raises `Failure` if the tag doesn't check out — tampering is a failure, not an absence.
proc tryUnseal*(key: Key; box: Sealed; alongside: View[byte]): Option[List[byte]]

func sameSecret*(a, b: View[byte]): bool   ## constant-time; the only correct way to compare tags
proc randomBytes*(n: Count): List[byte]    ## OS CSPRNG. std.random cannot reach this.

proc newKeyPair*(): (PrivateKey, PublicKey)              ## X25519
proc sharedSecret*(mine: PrivateKey; theirs: PublicKey): array[32, byte]
proc newSigningPair*(): (SigningKey, VerifyingKey)       ## Ed25519
proc sign*(key: SigningKey; message: View[byte]): Signature
func verify*(key: VerifyingKey; message: View[byte]; sig: Signature): bool

# --- x509 submodule ---
proc toCertificate*(der: View[byte]): Certificate        ## raises on malformed DER
proc tryToCertificate*(der: View[byte]): Option[Certificate]
func subject*(c: Certificate): Name
func issuer*(c: Certificate): Name
func goodFrom*(c: Certificate): ZonedTime
func goodUntil*(c: Certificate): ZonedTime
iterator list*(c: Certificate): SanEntry                 ## the SAN entries
func isAuthority*(c: Certificate): bool
proc chainProblem*(chain: openArray[Certificate]; roots: CertStore;
                   host: TextView; at: ZonedTime): Option[ChainProblem]
  ## `none` means trusted. Absence of a problem is an ordinary answer, so no raise.
proc verifyChain*(chain: openArray[Certificate]; roots: CertStore;
                  host: TextView; at: ZonedTime)         ## raises with the problem attached
proc platformRoots*(): CertStore
proc add*(s: var CertStore; c: Certificate): bool {.discardable.}   ## Collection
iterator list*(s: CertStore): Certificate
```

`ChainProblem` (`Expired`, `HostnameMismatch`, `UntrustedRoot`, `IncompleteChain`) is **defined here** and re-exported by `std.net-tls`, the same way `Certificate` is — the Rust draft had `std.crypto` returning a type `std.net-tls` owned, which is a dependency cycle Nim's module system would reject outright.

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `aead::seal` / `aead::open` | `seal` / `unseal` | `open` is PROTOCOLS' resource verb; reusing it for decryption would be the library's worst collision. `seal`/`unseal` is also plainer English than encrypt/decrypt. |
| `kdf::derive_key(pass, salt, params)` | `keyFromPassphrase(pass, salt, work =)` | Says what comes out, and `Work` names the knob by its purpose: how much a guess costs. |
| `kdf::Params` | `Work` | `mem_kib`/`iterations`/`parallelism` are three implementation words for one idea. |
| `ct_eq` | `sameSecret` | Nobody guesses what `ct` abbreviates, and the name now says when to reach for it. |
| `Hasher` (streaming) | `Digest` | `Hasher` is `core.hash`'s type for a completely different job. One name, one meaning, library-wide. |
| `x509::parse_der` | `toCertificate` | PROTOCOLS' `to<Format>` family, with the `try` sibling doing the fallibility. |
| `not_before` / `not_after` | `goodFrom` / `goodUntil` | Two negations replaced by the question an admin is actually asking. |
| `verify_chain -> Result<(), E>` | `chainProblem -> Option` + `verifyChain` | "Is anything wrong?" is an absence question; the raising sibling exists for callers who just want to proceed or die. |
| `rng::bytes` | `randomBytes` | Greppable, and impossible to confuse with `std.random`'s `Dice`. |

## In use

```nim
# secrets-vault: passphrase in, sealed file out, plaintext never named
let pass = askHidden("master passphrase: ")        # std.cli hands back a SecretText
let key = keyFromPassphrase(pass, header.salt)
vaultFile.write(seal(key, entries.toJson().bytes(), alongside = [formatVersion]).toBytes())

# tls-cert-inspector: report exactly what's wrong, don't just refuse
let shake = greet(socket, serverName = host)
for cert in shake.chain:
  echo cert.subject(), "  expires ", cert.goodUntil()
shake.problem.ifSome(p):
  case p.kind
  of Expired:  echo "expired at ", p.notAfter
  of HostnameMismatch: echo "presented ", p.sanEntries, ", wanted ", p.expected
  else: echo p
```

## Vocabulary exceptions
This module introduces **fifteen domain verbs** — `seal`, `unseal`, `sign`, `verify`, `sameSecret`, `sha256`, `blake3`, `hmacSha256`, `newKey`, `keyFromPassphrase`, `newKeyPair`, `sharedSecret`, `randomBytes`, `toCertificate`, `verifyChain` — which is precisely the count PROTOCOLS' maintainability contract names as evidence a module belongs in the extended ecosystem. It stays in `std` on the escape clause the same document grants: each is a single, universally understood word taking its subject first and its options last, so an unfamiliar reader can still guess the *shape* of `seal(key, plaintext, alongside = ...)` without documentation. What it cannot guess is the meaning — and cryptography is the one place where forcing `get`/`set` onto the meaning would be actively dangerous rather than merely opaque.

**No `Resource` appeared.** The prediction expected "a thin `Resource` shell"; nothing here opens or closes. The shell that did emerge is `Streamable` on `Digest` and `Collection` on `CertStore` — two protocols, both incidental, neither on the key types. `Key` is the deliberate hole in the vocabulary: it has no `get`, no `show`, no `$`, and `secrets-vault`'s guarantee is that `echo key` does not compile.
