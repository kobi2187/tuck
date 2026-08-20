# core.convert

## Purpose
The single conversion mechanism for the whole stdlib: `From`/`Into` for infallible conversions and `TryFrom`/`TryInto` for conversions that can fail, used uniformly wherever one type needs to become another — numeric widening, byte-buffer-to-struct, error-type wrapping, format (de)serialization.

## Design lineage
Modeled directly on Rust's `convert` module (`From<T>`/`TryFrom<T>` as dual, symmetric traits, with a blanket `Into`/`TryInto` derived automatically from any `From`/`TryFrom` impl). The report's Part IV explicitly names this as "the single conversion mechanism used everywhere," and Part II's cross-cutting analysis flags inconsistent ad hoc conversion conventions (constructor overloading in Java/C#, implicit narrowing casts in C/C++) as a recurring inconsistency category this design closes by giving every module exactly one shape to implement.

## Proposed API
```
trait From<T> {
    fn from(value: T) -> Self;
}

trait Into<T> {
    fn into(self) -> T;
}
// blanket impl: anything implementing From<T> for U gets Into<U> for T for free

trait TryFrom<T> {
    type Error;
    fn try_from(value: T) -> Result<Self, Self::Error>;
}

trait TryInto<T> {
    type Error;
    fn try_into(self) -> Result<T, Self::Error>;
}
// blanket impl, symmetric to Into

trait AsRef<T: ?Sized> {
    fn as_ref(&self) -> &T;     // cheap, non-owning view conversion (e.g. String -> &str)
}
```

## Key design decisions
- `From`/`TryFrom` are the *only* place a conversion is ever defined; `Into`/`TryInto` are never implemented directly — they are always derived — so there is exactly one implementation site per type pair, preventing the "two conversion functions that quietly disagree" bug class.
- Fallibility is expressed purely by trait choice (`From` vs `TryFrom`), not by a runtime flag or an infallible-but-actually-panics escape hatch — a type author is forced to declare up front whether a conversion can fail, which then determines whether `core.error`'s `Result` machinery is involved at all.
- `AsRef` is kept as a separate, narrower trait (cheap reference-to-reference view, not an owning transformation) rather than folded into `From`, because `From`/`Into` are allowed to be expensive (allocate, copy) while `AsRef` promises O(1) — conflating them was considered and rejected specifically because `doc-convert-tester`'s schema-driven conversions need to distinguish "reinterpret cheaply" from "transform."

## Validated by applications
- **doc-convert-tester**: this app's own profile calls `core.convert` "the core object under test" for the harness's cross-format conversion. It is the strongest possible validation: the app needs every format (Markdown, HTML, CSV, JSON, TOML) to plug into the *same* trait so the test harness can iterate "all known codecs" generically. This directly confirmed the design holds for the easy formats and surfaced a real risk (see below) for CSV, whose ambiguous type inference (is `"04"` a string or a number?) doesn't fit cleanly into infallible `From` and pushed CSV's numeric-field conversions into `TryFrom` with a dedicated `AmbiguousType` error variant — a refinement from the naive first design, which assumed all tabular conversions could be `From`.
- **archive-cli**: OS file-permission bits, path separators, and timestamp representations need lossless round-trip conversion between the archive format's on-disk representation and the host OS's native types; this is a smaller-scope but concrete use of `TryFrom` (a permission bit pattern from an untrusted archive may not map to a valid OS mode) validating that fallible conversions must be the default assumption for anything crossing an "untrusted external data" boundary, not an afterthought.
- **embedded-sensor-node**: raw I2C register bytes to typed sensor readings (with endianness handled via `core.num`) is expressed as `TryFrom<[u8; N]>` for the reading type, rejecting out-of-range bus garbage at the conversion boundary rather than propagating an invalid typed value further into the filter pipeline — validates that `TryFrom` works with zero allocation and zero heap for a freestanding target, which was a design requirement, not just a nice-to-have.

## Open questions / risks
Whether a third, "conversion that may lose precision but always succeeds" tier (e.g. `f64` → `f32`) deserves its own trait or is left to `core.num`'s explicit saturating/truncating methods is unresolved; currently resolved in favor of `core.num` owning that case to avoid a fourth trait in this module.
