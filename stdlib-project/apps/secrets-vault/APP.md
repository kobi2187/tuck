# App: secrets-vault

A local encrypted password manager, CLI-only: `vault init`, `vault add github`, `vault get github` (copies to clipboard, auto-clears after N seconds), `vault gen --length 20` for password generation, backed by a single encrypted file protected by a master passphrase.

## Why this is a good validation target
It is the primary, purpose-built exercise for `std.crypto` beyond TLS: correct key derivation from a low-entropy passphrase, authenticated encryption of the vault contents, and — just as important — correct *use* of `std.random`'s CSPRNG for generated passwords versus deliberately never touching the non-crypto PRNG used by `cli-hangman`.

## Features
- Master-passphrase-derived key (Argon2id or equivalent memory-hard KDF), never stored.
- Vault contents (site → username/password/notes) encrypted at rest with an AEAD cipher; the whole file authenticated so tampering is detected, not silently accepted.
- Password generation with configurable charset/length using the CSPRNG.
- Atomic vault updates (never leave a half-written encrypted file on crash/power loss).
- Clipboard copy with auto-clear timer; no plaintext ever touches disk or logs.

## Modules exercised
| Tier | Module | Why |
|---|---|---|
| std | `std.crypto` | KDF (Argon2id), AEAD encryption/decryption of the vault, CSPRNG for generated passwords |
| sys | `sys.fs` | atomic write of the encrypted vault (write to temp file, fsync, rename) |
| std | `std.encoding` | structured (de)serialization of the decrypted vault contents (JSON/binary) before encryption |
| std | `std.cli` | passphrase prompt with input echo disabled, clipboard interaction |
| sys | `sys.time` | auto-clear timer for clipboard |
| alloc | `alloc.string` | in-memory plaintext secrets — and the module that must answer "can this be zeroized/locked from swap," see note below |
| core | `core.error` | wrong passphrase, corrupted/tampered vault (must fail closed) |

## Anticipated API stress points
This app is the strongest forcing function for a question the Part IV design left implicit: does `alloc.string`/`alloc.vec` offer any way to request zero-on-drop, non-swappable memory for secret material, or is that pushed entirely to `std.crypto` as a separate `SecretBytes` type? A real vault implementation cannot responsibly ignore this, so the module doc for `std.crypto` and `alloc.allocator` both need to take a position rather than stay silent on it.
