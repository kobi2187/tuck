# core.error

## Purpose
The one error/panic/contract mechanism for the entire standard library: `Result`-carried recoverable errors via an `Error` trait, plus opt-in preconditions/postconditions/invariants that are checked at compile time where provable and at runtime (as a trap) otherwise. Every other module's fallible operation returns `Result<T, E: Error>` — no module defines its own error convention.

## Design lineage
Modeled on a fusion of Rust's `Result` + `std::error::Error` trait (uniform, composable recoverable-error propagation with `?`-style short-circuiting) and Ada/SPARK's contracts (`Pre`/`Post`/`Invariant` as a language-level, not library-level, concept — checked statically by a verifier where the proof obligation is dischargeable, and compiled to a runtime check otherwise), plus Zig's error-set-as-part-of-the-function-signature idea for making exactly which errors a function can return part of its visible contract. The report names Ada/SPARK's contracts as the one entry in the whole survey that "treats correctness itself, not just convenience, as a stdlib-adjacent concern" — this module is the direct implementation of that observation, fused with Principle 4's demand for exactly one error idiom stdlib-wide.

## Proposed API
```
trait Error: fmt::Debug + fmt::Display {
    fn source(&self) -> Option<&dyn Error>;   // causal chain, for wrapped/nested errors

    // Added — see Key design decisions "Revision (config-schema-validator)".
    // A composable, tier-agnostic slot for "where did this happen," distinct
    // from the human-readable message Display already carries. Provided
    // default is None so this is purely additive: no existing Error impl
    // needs to change to keep compiling.
    fn location(&self) -> Option<&dyn Location> { None }
}

// A minimal, allocation-free trait so `core.error` itself never needs
// `alloc` to define the *concept* of a location — only Display is required.
// core-tier code can implement it with plain numeric fields (SourcePos,
// below); alloc/std-tier code can implement it with a full owned field-path
// string (e.g. a FieldPath type living alongside alloc.string, composed via
// alloc.string::String + the truncate-based push/pop pattern) without
// core.error needing to know that type exists.
trait Location: fmt::Display {}

// core-tier concrete implementation: numeric only, no allocation, for
// parsers/lexers that only have byte/line/column offsets to report.
struct SourcePos { line: u32, column: u32, offset: usize }
impl Location for SourcePos {}

// Contracts: attribute-like annotations on functions, checked where provable at
// compile time (via the same analysis SPARK uses for dischargeable proof
// obligations) and lowered to a runtime trap otherwise.
#[requires(divisor != 0)]
#[ensures(result * divisor <= dividend)]
fn checked_div(dividend: u32, divisor: u32) -> u32;

#[invariant(self.len <= self.capacity)]
struct BoundedBuffer { /* ... */ }

// Propagation sugar (the `?` operator equivalent): a fallible call inside a
// function returning Result<T, E> short-circuits on Err, converting the error
// type via core.convert::From if needed:
fn read_config() -> Result<Config, ConfigError> {
    let raw = read_file(path)?;          // io::Error -> ConfigError via From
    let parsed = parse(raw)?;
    Ok(parsed)
}

// Panics: reserved for genuinely unrecoverable programmer-error conditions
// (contract violations, out-of-memory in an infallible path), never for
// expected/recoverable failure:
fn panic(message: &str) -> !;
```

## Key design decisions
- Contracts are opt-in and gradual: an unannotated function has no proof obligation at all, an annotated one is checked statically wherever the compiler/verifier can discharge the obligation, and falls back to a runtime trap only where it cannot — this avoids the two failure modes the report's survey associates with contract systems, "all-or-nothing formal verification too heavy to adopt incrementally" and "documentation-only contracts nobody actually checks."
- `Result`/`Error` is the *only* mechanism for recoverable failure; `panic` exists solely for contract violations and true logic-bug conditions, never for expected failure modes (a missing file is a `Result::Err`, not a panic) — this is the single hardest rule this module enforces stdlib-wide, and it is what makes Principle 4 real rather than aspirational.
- `Error::source()` provides a causal chain (an error can wrap the lower-level error that caused it) so that diagnostic tooling (`std.log`, `core.fmt`'s `Debug`) can print full context without every module reinventing an ad hoc "caused by" convention.
- **Revision (config-schema-validator): `Error::location() -> Option<&dyn Location>` added as a shared, composable "what and where" extension point.** This precision requirement was first raised by `doc-convert-tester` and reinforced independently by `kv-store-server`'s WAL-corruption byte-offset reporting, but until now each of those was left as "whatever structured context the concrete error type happens to carry via `source()`/`Display`" — a real gap the report's own module doc flagged but never closed, and exactly the kind of ad hoc, module-by-module bolt-on Principle 4 exists to prevent. `config-schema-validator` is the sharpest version of the requirement yet: every reported violation needs *both* a field path (`server.tls.cert_path`) and, where the source format supports it, a line/column — and it needs *all* violations at once (`--strict` mode reports every problem in one pass), so the location can't just live in a one-off formatted message string per call site. The resolution keeps `core.error` itself allocation-free (Principle 2): `location()` returns a trait object behind a new minimal `Location: fmt::Display` trait, so the *shape* of "an error can carry a location" is defined once in `core`, while the *concrete* location type is free to be as cheap (`SourcePos`, numeric-only, defined right here, no allocation) or as rich (an owned field-path `String` built via `alloc.string`'s push/pop-truncate pattern, at the `alloc`/`std` tier where that config-schema-validator's field paths actually get assembled) as the reporting module needs. This retroactively gives `doc-convert-tester` and `kv-store-server` the same mechanism to converge on rather than leaving each app's location-reporting as a bespoke, non-reusable pattern — the concrete `FieldPath`-style type itself is left for the `alloc`/`std` module that needs it to define (not added here, since `core.error` has no business knowing about `alloc.string`), but the trait contract that makes it pluggable now exists.

## Validated by applications
Every one of the 11 apps uses `core.error` — it is the one module the report anticipates as universal — so the interesting validation is which apps forced *refinement* beyond a naive design, not merely "used it":
- **web-downloader**: retry/backoff logic needs to distinguish *retryable* failures (timeout, 5xx) from *permanent* ones (404, checksum mismatch) uniformly across the app's whole retry loop. The naive first design was a flat `Error` trait with no classification; this app's exponential-backoff requirement forced adding a `is_retryable()`-style convention (expressed as a marker sub-trait or associated const on specific error types, not a special case in `core.error` itself) so retry logic can be written generically against any module's error type rather than pattern-matching on concrete error enums per call site.
- **secrets-vault**: "fail closed" on a wrong passphrase or tampered vault means the error path must be impossible to accidentally ignore or partially handle — this validated that `Result` (forcing explicit handling at every call site, unlike an exception that can propagate silently past an unaware frame) is the correct choice over an exception-based alternative that was considered and rejected specifically because of this app's threat model.
- **embedded-sensor-node**: I2C bus errors ("common and must not hang the device," per the app profile) are the direct validation of the contract half of this module — a `#[requires(retries <= MAX_RETRIES)]`-style precondition on the bus-read retry loop, checked at compile time where the retry bound is a compile-time constant, is what prevents a firmware bug from becoming an infinite retry hang, without needing a runtime watchdog as the only backstop.
- **todo-cli**: malformed query strings and corrupt storage files need errors precise enough to say *what and where* failed (which token in the query, which byte offset in the file), not just "parse failed" — validated that `Error::source()`'s causal chaining, combined with `core.fmt::Display`, must carry structured context, not just a message string, refining an early draft that treated `Error` as effectively just a formatted string.
- **process-supervisor**: a supervised child's outcome is a genuine three-way (or more) classification — exited cleanly, exited nonzero, killed by a signal, or never spawned at all (missing binary, permission denied) — not the binary retryable/permanent split `web-downloader` established. This validates that the `is_retryable()`-style marker convention was never meant to be the *only* classification shape a caller can build on top of `Error`; a closed enum of outcome variants (owned by `sys.process`, not by this module) composes fine with `Error::source()` for the "never spawned" case (which wraps the underlying OS spawn error) without `core.error` itself needing to know about processes or signals.
- **image-thumbnailer**: the "skip a corrupt file, log it, keep processing the batch" requirement is a batch-level control-flow pattern (catch each item's `Result`, accumulate, continue) that this module's existing `Result`-only-for-recoverable-failure rule already supports with no extension — validated as a non-event: an app that must *never* let one failure abort a whole run is exactly what forcing `Result` (rather than an unwinding exception that could propagate past the per-item boundary uncaught) was already meant to guarantee, per the same reasoning `secrets-vault` established for its fail-closed path.
- **kv-store-server**: WAL replay on crash recovery must fail closed on a truncated/corrupt record — applying a partial write would silently corrupt server state for every client, which is worse than refusing to start. This is a second, independent confirmation (after `secrets-vault`) that `Result`'s "cannot be silently ignored" property is load-bearing specifically *because* the failure mode here is data corruption, not just a rejected user action; no change to the module was needed, but it raises confidence that the fail-closed guarantee generalizes from a single-user local tool to a server process handling concurrent, already-acknowledged writes.
- **config-schema-validator**: the sharpest test yet of the "what and where" precision requirement, and the direct forcing function for the `Error::location()`/`Location` addition above. Every reported schema violation must carry a field path (`server.tls.cert_path`, built incrementally during recursive traversal — see `alloc.string`'s `truncate` revision) plus, where the source format preserves position information, a line/column — and `--strict` mode's "report every violation, not just the first" requirement means these can't be squeezed into a single `Display` message per call and stop there; calling code needs to *extract* the field path and position separately (to group violations by field, to sort them, to render them in a table) not just print them. Before this revision, `core.error` had no shared vocabulary for that: each module would have kept inventing its own bespoke "here's my error, and separately here's a string I concatenated with the location baked in" convention, which is precisely what `todo-cli`'s validation already flagged as the wrong shape ("refining an early draft that treated `Error` as effectively just a formatted string"). With `location()` in place, this app's `SchemaViolation` error type implements `Location` once with a `FieldPath`-shaped concrete type, and every violation in the batch carries a structured, independently-queryable location alongside its message.
- **embedded-display-node**: a second embedded validation of the contract half of this module, deliberately on a different bus than `embedded-sensor-node`'s I2C — SPI transfer errors (display controller) get the same `#[requires]`/bounded-retry treatment already established, confirming that pattern isn't accidentally I2C-specific. The RTC read path adds a genuinely new wrinkle worth naming: a dead backup battery doesn't necessarily make the I2C transaction itself fail (the bus operation can succeed while the *value* it returns is stale/nonsensical because the RTC lost power and reset its clock). That's not cleanly an `Err` in the usual sense — it's an `Ok` value whose validity is separately suspect — and this module's `Result`-only vocabulary doesn't have a built-in way to say "succeeded, but treat the payload as untrusted" short of the caller's own domain-specific sanity check on the returned timestamp; noted in Open Questions rather than resolved.

## Open questions / risks
How much static contract-checking is realistically dischargeable by a mainstream compiler (versus requiring a separate SPARK-like verifier pass most projects won't run) is the central open risk — the report's own Part V flags this tension for `platform.hal` traits; the same tension applies here to how much of the "checked at compile time where provable" promise is actually load-bearing versus aspirational without dedicated tooling investment.

- **git-lite**: corrupt-object detection (the hash of a decompressed object's content doesn't match the filename it was stored under) is a fail-closed, non-retryable data-integrity error — a non-event validation in the same vein as `image-thumbnailer` and `kv-store-server`'s WAL-corruption case: `Result`'s "must be handled, can't silently propagate past an unaware frame" property is exactly what a content-addressed store's self-check needs, and nothing about this app required a change to the module.
- **diff-patch**: malformed patch syntax and a hunk that fails to apply (context lines don't match the target file) are a second, independent consumer of the `Location`/`SourcePos` mechanism added for `config-schema-validator` above — a patch-parse error naturally wants "which line of the `.diff` file" and a non-applying hunk wants "which hunk header, expected vs. actual context," both of which are exactly what `Error::location()` exists to carry rather than folding into the `Display` message. No further change to `core.error` was needed beyond what `config-schema-validator` already forced; this app is confirmation the mechanism generalizes to a second, differently-shaped "where" (a hunk index and byte range within a small text file, not a nested field path).
- **ble-scanner**: malformed or unrecognized advertisement payloads must be skipped, not crash the scanner — the same "one bad item shouldn't abort the whole run" pattern `image-thumbnailer` already validated, now applied to a live streaming scan rather than a batch file loop. Non-event: `Result`-per-decode-attempt already covers it with no change needed.

`embedded-display-node`'s battery-backed-RTC read surfaces a category this module doesn't currently name: a "successfully returned, but semantically untrustworthy" result, distinct from both a normal `Ok` and an `Err`. Whether that belongs as a third outcome shape at this layer (e.g. some kind of tagged/suspect result wrapper) or is correctly left to each domain (a `platform.hal` RTC trait returning a `PowerLossDetected`-flavored `Err` variant instead, which would keep `core.error` itself unchanged) is unresolved — flagged here rather than speculatively added, since only one app in the set has surfaced it so far.
