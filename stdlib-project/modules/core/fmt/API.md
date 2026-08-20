# core.fmt

## Purpose
Zero-allocation text formatting: the `Display`/`Debug` traits that any type implements to describe itself, and a `Write`-style sink trait so formatted output can be pushed into a stack buffer, a fixed-size ring, or (one tier up) a growable `alloc.string` — without `core.fmt` itself ever allocating.

## Design lineage
Modeled on Rust's `core::fmt` (the `Display`/`Debug` split, and `write!`-style formatting driven entirely through a `Write` sink trait so the same formatting code runs identically on a heap-backed `String` or a fixed embedded buffer) and Zig's `std.fmt` (explicit destination-buffer formatting with no hidden allocation, the direct model for keeping this in `core` rather than `alloc`). The `Display`/`Debug` split specifically answers the report's Principle 4: one formatting mechanism, used by `std.log`, `std.cli`, and every error type, rather than each module defining its own `to_string`-equivalent.

## Proposed API
```
trait Write {
    fn write_str(&mut self, s: str::Str) -> Result<(), FmtError>;
    fn write_char(&mut self, c: char) -> Result<(), FmtError>;
    fn write_fmt(&mut self, args: Arguments) -> Result<(), FmtError>;  // from format!-style macro
}

trait Display {
    fn fmt(&self, f: &mut Formatter) -> Result<(), FmtError>;   // human-readable
}

trait Debug {
    fn fmt(&self, f: &mut Formatter) -> Result<(), FmtError>;   // programmer-facing, structural
}

struct Formatter<'a> { /* wraps a Write sink; tracks width/precision/fill flags */ }

impl<'a> Formatter<'a> {
    fn write_str(&mut self, s: str::Str) -> Result<(), FmtError>;
    fn debug_struct(&mut self, name: &str) -> DebugStruct;  // builder for Debug impls
    fn width(&self) -> Option<usize>;
    fn precision(&self) -> Option<usize>;
}

// A fixed-size, allocation-free sink for freestanding targets:
struct FixedBuf<const N: usize> { /* Array<u8, N> + cursor; implements Write, errors on overflow */ }
```

## Key design decisions
- `Display` (user-facing) and `Debug` (structural/diagnostic) are two separate traits rather than one with a mode flag — this mirrors `core.cmp`'s `Eq`/`Ord` split rationale: a type may reasonably have one without the other (a raw byte buffer has `Debug` but no meaningful `Display`), and keeping them distinct lets `secrets-vault`-style types implement `Debug` to redact secret fields while still refusing to implement `Display` at all, rather than one trait with an easy-to-forget "don't leak the password" runtime check.
- Formatting is sink-based (`Write`) rather than string-returning, so `core.fmt` has zero dependency on an allocator and works identically whether the destination is a `FixedBuf<64>` on a microcontroller stack or `alloc.string`'s `String` — this is the direct enforcement of Principle 2 for the formatting concern specifically.
- `Debug` is expected to be mechanically derivable (structurally, field by field) while `Display` is always hand-written — codifying the convention (borrowed from Rust) that `Debug` output is not a stable, user-facing contract, only `Display` output is.

## Validated by applications
- **secrets-vault**: the strongest, most distinctive validation. The app must guarantee "no plaintext ever touches disk or logs," which is a direct requirement on `core.fmt`: the `Debug`/`Display` split lets the vault's secret-holding types implement a redacting `Debug` (`"Secret(**hidden**)"`) while deliberately not implementing `Display` at all, so any accidental `println!`/`log::info!` of a secret value is a compile error, not a runtime leak. A naive single-trait formatting design (one `to_string`-style method every type gets automatically) was rejected specifically because it would have made accidental secret logging silently possible.
- **mp3-player**: the playback-position display updates ~4x/sec from a dedicated UI thread while the audio thread runs uninterrupted; formatting straight into a `FixedBuf`-style stack sink (no allocation per frame) is what keeps this update path from ever touching the general-purpose allocator the app's real-time constraints forbid on the hot path — direct validation of the sink-based, allocation-free design.
- **log-grep**: colored match-highlighting output is built by composing `Display` impls for match spans with `std.cli`'s color codes; this confirmed `Formatter`'s width/precision/fill tracking needs to be sufficient for column-aligned output (file:line:col formatting) without `std.cli` needing a second, competing formatting layer — validating Principle 4 held even under a real terminal-rendering use case.

## Open questions / risks
Whether format-string macros (`write!`-style compile-time-checked argument matching) are a language feature or a library-level `Arguments` builder API is left unresolved here — it affects tooling more than the trait design itself.
