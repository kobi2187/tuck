# std.crypto — Tuck translation

## Shape decision
Freeform `pending:` verbs over `Seq[u8]`. **Compiler-verified**,
`./tuck ch`: `OK`.

## The API

```tuck
type HashKind:
  | Sha256
  | Sha3_256
  | Blake3

type CryptoError:
  | BadKey
  | BadTag
  | BadCertificate

pending:
  fn sha256({data: Seq[u8]}) -> Seq[u8]
  fn blake3({data: Seq[u8]}) -> Seq[u8]
  fn hmacSha256({key: Seq[u8], data: Seq[u8]}) -> Seq[u8]
  fn seal({key: Seq[u8], nonce: Seq[u8], plaintext: Seq[u8], alongside: Seq[u8]}) -> Seq[u8]
  fn unseal({key: Seq[u8], nonce: Seq[u8], ciphertext: Seq[u8], alongside: Seq[u8]}) -> Seq[u8]?
  fn keyFromPassphrase({phrase: str, salt: Seq[u8], iterations: int}) -> Seq[u8]
  fn randomBytes({count: int}) -> Seq[u8] [io]
  fn sameSecret({a: Seq[u8], b: Seq[u8]}) -> bool
```

## The module's central safety property is **lost** in translation

The Nim design's most important claim was:

> **`Key` is the deliberate hole**: no `get`, no `show`, no `$`, so
> `echo key` does not compile. The vocabulary being refused where obeying
> it would be dangerous is the system working, not failing.

That worked because `Key` was an opaque type implementing *neither*
`Showable` nor `Gettable`. **Here keys are `Seq[u8]`** — an ordinary value
that prints, copies, and lingers in memory like any other. `echo key`
compiles fine.

Restoring it needs a `distinct Key = Seq[u8]` with no `show` attached,
which is expressible (`distinct` is real, and `satisfies` is opt-in, so a
type that never declares `Showable` cannot be rendered). **That is probably
the right change** and it's cheap — recorded rather than applied, because
it interacts with the wider `Secret[T]`/scrubbing gap:

- **`core.mem::Scrubbed[T]`** (zero-on-drop, optimizer barrier) — no Tuck
  counterpart, no destructor hook.
- **`alloc.allocator::SecureAllocator`** — no counterpart, allocators are
  language-level regions.
- **`std.cli::askSecret`** returns plain `str` for the same reason.

So `secrets-vault`'s whole threat model — a passphrase that cannot be
printed, cannot be swapped to disk, and is wiped on scope exit — currently
survives in *none* of its three parts. That is the single largest security
regression in the translation and belongs in one design conversation, not
three module footnotes.

## Notes
- **Fifteen domain verbs stay fifteen domain verbs.** Round-4's own
  analysis said this module strains the closed vocabulary hardest and stays
  in `std` on the escape clause ("each is one universally understood word
  obeying the argument-order rule"). Unchanged.
- **`unseal` returns `?`** — a failed tag check is not an exceptional
  event, it's the expected answer for tampered ciphertext, and `?` says so
  without a raise.
- **`sameSecret` (constant-time comparison) is the one verb that must not
  be "optimized"** into an early-exit `==`. Nothing in Tuck expresses that
  constraint; it's an implementation obligation, same as in the Nim design.
- **`x509` submodule not translated** — certificate parsing is a large
  surface and depends on `std.chrono` for validity windows. Deferred with
  `Recurrence`.
