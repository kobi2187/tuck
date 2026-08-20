# core.str

## Purpose
UTF-8-validated, non-owning string-slice operations — the read-only text vocabulary usable with no allocator (owned, growable strings are `alloc.string`, one tier up). Guarantees every `str` value is well-formed UTF-8 at construction, never after.

## Design lineage
Modeled on Rust's `&str` (a `[u8]` slice statically guaranteed valid UTF-8, so no function needs to re-validate or handle malformed text internally) combined with Zig's approach of treating strings as `[]const u8` plus a separate `std.unicode` module for codepoint-aware operations — kept as two layers here too (byte-level `core.str` operations vs. Unicode-semantic operations like normalization, which the report's Part IV places at `std.i18n` since they need locale/table data too large for a freestanding tier).

## Proposed API
```
struct Str<'a> { /* opaque: validated-UTF-8 byte slice with lifetime 'a */ }

impl<'a> Str<'a> {
    fn len(&self) -> usize;                          // bytes, not chars
    fn is_empty(&self) -> bool;
    fn as_bytes(&self) -> slice::Slice<u8>;
    fn chars(&self) -> impl Iterator<Item = char>;    // decodes UTF-8 lazily
    fn char_indices(&self) -> impl Iterator<Item = (usize, char)>;
    fn bytes(&self) -> impl Iterator<Item = u8>;
    fn split(&self, pat: impl Pattern) -> impl Iterator<Item = Str<'a>>;
    fn splitn(&self, n: usize, pat: impl Pattern) -> impl Iterator<Item = Str<'a>>;
    fn trim(&self) -> Str<'a>;
    fn starts_with(&self, pat: impl Pattern) -> bool;
    fn find(&self, pat: impl Pattern) -> Option<usize>;   // byte offset
    fn get(&self, range: Range<usize>) -> Option<Str<'a>>; // None on non-boundary slice
    fn from_utf8(bytes: slice::Slice<u8>) -> Result<Str<'a>, Utf8Error>;
    unsafe fn from_utf8_unchecked(bytes: slice::Slice<u8>) -> Str<'a>;
}

trait Pattern { /* char, Str, or closure — matches D ranges'/UFCS-style flexible matching */ }
```

## Key design decisions
- `from_utf8` validates once at the boundary and returns `Result`; every method afterward assumes validity and never re-checks, so `core.iter`-style chained operations pay the UTF-8 decode cost exactly once, at the earliest possible point (Design Principle 3's composability without redundant work).
- `get(range)` returns `Option` rather than panicking on a byte offset that isn't a char boundary — a naive `index`-style API modeled directly on `slice::index` was the first draft, but text-processing apps showed that "slice a string at an arbitrary byte offset" is common enough (regex match spans, header parsing) that panicking-by-default was the wrong tradeoff for this specific type, unlike `core.slice`.
- Codepoint-level Unicode semantics (case folding beyond ASCII, normalization, grapheme clusters) are explicitly excluded and pushed to `std.i18n` — `core.str` only guarantees "valid UTF-8, decodable into scalar values," which keeps this module allocator-free and table-free, per Principle 1.

## Validated by applications
- **doc-convert-tester**: this app's round-trip diffing is Unicode-heavy by design (BOM markers, combining-character sequences, mixed line endings), which is exactly what exposed the boundary between `core.str` and `std.i18n`: `core.str.chars()` decoding into scalar values is necessary but not sufficient for "are these two strings equivalent text," confirming the report's own decision to keep normalization out of `core`. Without this app's stress test, an earlier draft risked scope-creeping normalization into `core.str` for convenience.
- **log-grep**: Unicode-aware case-insensitive matching (`-i`) needs `core.str` iteration over a possibly enormous mmap'd byte region without copying, which forced `chars()`/`char_indices()` to be genuinely lazy (backed by `core.iter`, not an eagerly materialized `Vec<char>`) — the difference between a streaming scan and an O(file size) allocation on every search.
- **todo-cli / cli-hangman**: both do lightweight parsing (tag `+tag` splitting, single-letter guess validation) that is the "is this API pleasant for trivial cases" control case the report calls out for `std.testing`; the same principle applies here — `split`/`trim`/`starts_with` needed to work with zero ceremony for these apps, confirming the `Pattern` trait (accepting a bare `char` or `&str` interchangeably) rather than requiring an explicit matcher object at every call site.
- **spellchecker**: `chars()`/`char_indices()` are the substrate directly underneath the app's Unicode-correct word tokenization — but this app is also the sharpest confirmation yet of this module's own documented boundary with `std.i18n`. `core.str` correctly decodes UTF-8 into codepoints one at a time; it has (deliberately) no concept of *word* boundaries, which for this app is genuinely hard (English space-splitting doesn't work for Chinese/Japanese/Thai, and even English needs to handle hyphenation, contractions, and combining marks). Tokenization itself is therefore `std.i18n`'s job (UAX #29-style segmentation), consuming `core.str.char_indices()` as its input stream — this app validates that the layering holds even under a harder real-world case than `doc-convert-tester`'s, with no change needed to `core.str` itself.

## Open questions / risks
Grapheme-cluster iteration (user-perceived "characters," as opposed to Unicode scalar values) is needed by some `std.cli` rendering use cases but requires Unicode segmentation tables too large for `core`; whether `std.i18n` alone can satisfy `std.cli`'s cursor-movement needs is unresolved.
