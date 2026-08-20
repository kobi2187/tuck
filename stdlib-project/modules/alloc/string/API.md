# alloc.string

## Purpose
An owned, growable, heap-allocated UTF-8 string plus a builder for efficient incremental construction — the `alloc`-tier complement to `core.str`'s borrowed, allocation-free string-slice operations.

## Design lineage
Modeled on **Rust's `String`** (a `Vec<u8>` with a UTF-8-validity invariant, `&str`-deref for slice interop) for the owned type, and **Go's `strings.Builder`** for the builder (single growable buffer, write-only until `.build()`, avoiding the classic `s += x` quadratic-concatenation trap that plain `String` gets people into in ergonomically-similar languages). Validity is checked once at construction/append boundaries rather than per-character, per the report's general preference for zero-cost abstractions over ambient safety checks.

## Proposed API
```
struct String { .. }               // owned, valid UTF-8, built on alloc.vec::Vec<u8> + core.str invariants
struct StringBuilder { .. }        // write-oriented accumulator; call .build() -> String when done

impl String {
    fn new() -> Self;                                    // default allocator
    fn new_in(a: &dyn Allocator) -> Self;
    fn from_str(s: &str) -> Result<Self, AllocError>;             // copies; default allocator
    fn from_str_in(s: &str, a: &dyn Allocator) -> Result<Self, AllocError>;
    fn with_capacity_in(n: usize, a: &dyn Allocator) -> Self;

    fn push(&mut self, c: char) -> Result<(), AllocError>;
    fn push_str(&mut self, s: &str) -> Result<(), AllocError>;
    fn as_str(&self) -> &str;                             // core.str interop, zero-copy
    fn as_bytes(&self) -> &[u8];
    fn len(&self) -> usize;
    fn clear(&mut self);
    fn truncate(&mut self, new_len: usize);               // added for config-schema-validator; must land on a char boundary
    fn allocator(&self) -> &dyn Allocator;
}

impl StringBuilder {
    fn new_in(a: &dyn Allocator) -> Self;
    fn write_str(&mut self, s: &str) -> Result<(), AllocError>;
    fn write_char(&mut self, c: char) -> Result<(), AllocError>;
    fn build(self) -> String;                             // consumes builder, no extra copy
}

// Secure variant — thin composition, not a forked type (see alloc.allocator)
type SecretString = Secret<String>;                        // String allocated via SecureAllocator; zeroed on drop, redacted Debug
fn secret_string_in(sa: &SecureAllocator) -> SecretString;
```

## Key design decisions
- **UTF-8 validity is an invariant of the type, not a runtime flag callers must remember to check.** `push_str`/`from_str_in` validate once; any byte-level escape hatch (e.g. building from an untrusted `Vec<u8>`) goes through an explicit `String::from_utf8(bytes: Vec<u8>) -> Result<Self, Utf8Error>` rather than an `unsafe` constructor being the *easy* path, matching Rust's precedent but keeping it visible in the public surface here rather than buried.
- **No `SecureString` type — `Secret<String>` composition instead.** `secrets-vault` is the direct forcing function: the position taken (fully consistent with `alloc.allocator`'s stance) is that zero-on-drop, non-swappable secret storage is a property of *which allocator backs the String*, not a different string type with a parallel API surface. `Secret<String>` gets every `String` method through `Deref`, so `vault.plaintext.push_str(&segment)` reads identically to normal code while still zeroing on drop and never touching swappable pages on hosted targets. Rejected alternative: a bespoke `SecureString` with its own (necessarily smaller, divergent) method set — that would violate Principle 4 by giving secret and non-secret strings two different idioms for the same operations.
- **`StringBuilder` is a distinct type from `String`, not `String` with amortized append hidden inside.** Go's `strings.Builder` precedent is followed exactly: separating "I am accumulating, don't read me yet" from "I am a finished, readable string" lets the builder use a growth strategy tuned for many small writes (matches `fmt`'s needs directly, see `alloc.fmt`) without that policy leaking into every `String` that's built once via `from_str` and then only read.
- **Default-allocator convenience mirrors `alloc.vec` exactly** (`new()` vs `new_in(&a)`) rather than inventing a different pattern for strings — deliberate consistency so learning one `alloc` module's allocator ergonomics teaches all of them.
- **Revision (config-schema-validator): added `String::truncate(new_len)`.** Incremental path-building during recursive traversal (`push_str("server"); recurse(); push_str("tls"); recurse(); push_str("cert_path"); ...`) needs to *pop* a segment back off when recursion unwinds, and the Proposed API had no way to do that short of `clear()` (destroys the whole path, forcing a full rebuild from the top on every recursive call — quadratic in traversal depth for no reason) or rebuilding a fresh `String` per recursion level (an allocation per nesting level, for a value that's genuinely just "the same buffer, shorter"). The fix mirrors `alloc.vec::truncate` (already present there) exactly: `path.push_str(segment)` before recursing, save `let mark = path.len()`, recurse, `path.truncate(mark)` on the way back out — one buffer, no allocation on the pop side, and the push/pop symmetry reads as a stack discipline directly in the traversal code rather than needing a separate path-stack data structure alongside the string. `truncate` must reject (or the caller must ensure) a `new_len` that doesn't land on a UTF-8 char boundary, consistent with the type's existing "validity is an invariant, not a runtime flag" stance — safe here specifically because segment boundaries in a field path are always pushed as whole `push_str` calls, so every saved `mark` is by construction a valid boundary.

## Validated by applications
- **secrets-vault**: the primary forcing function for `Secret<String>` above — the decrypted vault plaintext and the master passphrase both need to exist as in-memory strings at some point, and this app is where "just push the plaintext into a normal `String`" is unambiguously the wrong answer. It also validated that the secret type needs full `String`-like ergonomics (`Deref`), not a stripped-down API, since the app still needs substring/formatting operations on the decrypted content.
- **doc-convert-tester**: heavy `StringBuilder` usage reassembling Markdown/HTML/plain-text output during format conversion; this app is what forced `write_str` to be fallible (`Result`) rather than infallible, since round-trip conversion of adversarial/fuzzed input must be able to report an allocation failure as a normal error rather than aborting a fuzz run.
- **cli-hangman**: the masked-word display (`"h _ n g _ a n"`) is a small `String` rebuilt from a `Vec<char>`/`core.iter` each guess — the control-case validation that trivial `String` usage in a trivial app stays trivial (`String::new()`, `push`, `as_str()`, no allocator ceremony visible at all), which is itself the finding the report's "smallest app on purpose" methodology is designed to surface.
- **config-schema-validator**: the direct forcing function for `String::truncate` above. Building field-path strings (`server.tls.cert_path`) incrementally while recursing through a nested config/schema tree is exactly the push-before-recurse/pop-after-recurse pattern `truncate` exists for; without it, this app's own naive first approach would have been forced into either a `Vec<&str>` segment stack joined into a fresh `String` at every leaf (an allocation per violation reported, on a validator whose whole point is reporting *every* violation, not just the first) or repeated `clear()`-and-rebuild (quadratic in tree depth). With `truncate`, the field path is one `String` that grows and shrinks in step with the traversal's own call stack, at zero extra allocation cost per level.

## Open questions / risks
- `Secret<String>`'s `Deref` giving full `String` API access means it's easy to accidentally call a method that returns a borrowed `&str` and let that borrow escape into a non-secret context (e.g. logging it); this needs either a lint-level answer or a deliberately redacted `Display`/`Debug` plus documentation that `as_str()` on a `Secret` is the one method requiring caller discipline — not fully solved by the type system alone.
