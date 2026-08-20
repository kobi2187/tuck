# alloc.fmt

## Purpose
An allocating convenience layer over `core.fmt`'s zero-allocation `Display`/`Debug` write-to-sink mechanism: format-to-`String` in one call, without every caller manually wiring up a `StringBuilder` sink for the common case.

## Design lineage
Modeled on **Rust's `alloc::fmt` / the `format!` macro** (the same `Display`/`Debug` traits from `core.fmt`, just given an owned `String` destination instead of requiring a caller-supplied writer) and **Go's `fmt.Sprintf`** for the "one function, format string in, `String` out" ergonomic bar. Deliberately *not* a second formatting mechanism — per Principle 4 ("one coherent idiom per cross-cutting concern"), this module contributes zero new trait definitions; it is purely `core.fmt`'s existing `Display`/`Debug`/format-spec machinery pointed at an `alloc.string::StringBuilder` instead of an arbitrary sink.

## Proposed API
```
// The single entry point most callers use:
fn format(args: FormatArgs) -> Result<String, AllocError>;               // default allocator
fn format_in(args: FormatArgs, a: &dyn Allocator) -> Result<String, AllocError>;

// Language-level format-string sugar (illustrative; actual macro/codegen mechanism is language-dependent):
// format!("{name} scored {score}") expands to a call to `format(...)` above, reusing
// core.fmt's existing format-spec parser — no second parser, no second spec syntax.

// Direct, non-macro building block for hot paths that want to reuse one builder across many calls:
fn write_into(sb: &mut StringBuilder, args: FormatArgs) -> Result<(), AllocError>;

// Convenience for the extremely common "just Display this one value" case, skipping the format-string path entirely:
fn to_string<T: core.fmt::Display>(value: &T) -> Result<String, AllocError>;
fn to_string_in<T: core.fmt::Display>(value: &T, a: &dyn Allocator) -> Result<String, AllocError>;
fn debug_string<T: core.fmt::Debug>(value: &T) -> Result<String, AllocError>;
```

## Key design decisions
- **This module defines no new traits.** Every type that already implements `core.fmt::Display`/`Debug` (which, per Principle 4, is every formattable type in the entire standard library, top to bottom) works with `alloc.fmt` for free — the alternative (a separate `ToString`-style trait, as some ecosystems have historically grown by accident alongside `Display`) would be exactly the "reinvented per module" failure Principle 4 exists to prevent, so it's explicitly rejected here even though it's a common pattern in real languages surveyed.
- **`to_string`/`debug_string` exist as named shortcuts specifically because "format a single value with no format string" is disproportionately common** (log lines, error messages, simple CLI output) and forcing every such call through a format-string literal (`format("{}", &value)`) adds visual noise for the single-argument case without adding clarity — this is a deliberate ergonomic concession, not a new mechanism, since both shortcuts are trivial wrappers over the same `core.fmt::Display`/`Debug` calls `format` itself uses.
- **`write_into` exists for the case where allocating a fresh `String` per call is wasteful** — a hot loop producing many short-lived formatted strings (e.g., per-line log formatting) can reuse one `StringBuilder`, `clear()` it, and `write_into` again, amortizing the allocator calls; `format`/`format_in` are the right default but this is the deliberate escape hatch for when they aren't, following the same "convenience default + explicit control" pattern used by every other `alloc` module's allocator ergonomics.
- **Fallible (`Result<String, AllocError>`) even for the trivial cases**, consistent with the rest of the tier — a format call in a memory-constrained embedded context (e.g. rendering a sensor reading for a debug UART line, off `embedded-sensor-node`'s fixed arena) can genuinely fail, and pretending it can't by aborting would contradict Principle 2 as directly as a silently-aborting `Vec::push` would.

## Validated by applications
- **log-grep**: colored match-line formatting (`{file}:{line}: {matched_text}`, with ANSI color codes interpolated per `std.cli`) runs once per matching line across potentially millions of lines in a large scan — this is the app that validated `write_into` needed to exist as a distinct, reusable-builder path rather than only the allocate-fresh `format()` convenience, since re-allocating a `String` per matched line at that volume would be a measurable, avoidable cost directly traceable back to this module.
- **todo-cli**: colored/tabular list output formats each task's due date, priority, and tags into one line per task for `todo list` — straightforward `format()` usage per row, validating that the common case (one-shot formatting of a handful of fields per call, moderate call volume) needs nothing beyond the basic `format`/`format_in` pair with no builder-reuse ceremony required.
- **cli-hangman**: win/lose banner text and the masked-word display line are each a single `to_string`/`format` call — again the smallest possible real usage, and again the control-case finding is that it stays that simple: no format-string macro ceremony is required to print `"You win! The word was: {word}"`.
- **archive-cli**: progress display during large archive operations needs frequent (several times per second) re-formatting of "N of M files, X MB/s" status lines — a second validation (alongside log-grep) of the `write_into`-into-a-reused-`StringBuilder` pattern mattering for genuinely repeated, latency-sensitive formatting rather than being a speculative optimization with no real caller.

## Open questions / risks
- Whether the format-string macro/codegen mechanism itself (compile-time parsing of `"{name} scored {score}"`-style literals into `FormatArgs`) belongs specified here or is inherently language-dependent (macro system, `derive`-style codegen, or a `printf`-style runtime parser) is left open — this doc treats it as an implementation detail behind the `format()` entry point and only commits to the *result* (one spec syntax, defined once in `core.fmt`, reused everywhere) being uniform.
