# App: doc-convert-tester

A harness (not a single converter) that exercises round-trip and cross-format document conversion: Markdown ↔ HTML ↔ plain text, and tabular data across CSV ↔ JSON ↔ TOML, verifying that content, structure, and Unicode text survive conversion and that mis-encoded input is rejected with a clear error rather than silently mangled.

## Why this is a good validation target
It is the purpose-built exercise for `std.encoding`'s "one Codec interface, many formats" claim and for `std.i18n`. A format-conversion test harness is exactly the kind of program that immediately exposes whether a stdlib's serialization design is genuinely uniform (same `encode`/`decode` calling convention regardless of format) or only uniform for the easy formats.

## Features
- Convert Markdown → HTML → plain text and back where lossy steps are clearly flagged as lossy.
- Convert tabular data between CSV, JSON (array-of-objects), and TOML, preserving types (numbers vs. strings vs. dates) where the target format supports them.
- Round-trip test mode: convert A → B → A and diff against the original, reporting exactly what didn't survive.
- Fuzz/property-based test mode using `std.testing`'s hooks: generate random-but-valid documents and confirm no conversion panics or corrupts Unicode.
- Explicit handling of edge cases: BOM markers, mixed line endings, combining-character Unicode sequences, embedded null bytes.

## Modules exercised
| Tier | Module | Why |
|---|---|---|
| std | `std.encoding` | the core object under test — json/toml/csv codecs through one interface, plus a markdown/html text-format layer |
| std | `std.i18n` | Unicode normalization (NFC/NFD) so round-trip diffing isn't fooled by equivalent-but-differently-encoded text |
| std | `std.testing` | property-based round-trip testing, fuzzing hooks |
| std | `std.reflect` / `std.serde-derive` | schema-driven conversion (mapping a typed record through multiple formats) |
| sys | `sys.fs` | reading input documents, writing converted output |
| alloc | `alloc.string` | text manipulation across formats |
| core | `core.convert` | the `From`/`Into`/`TryFrom` mechanism underlying every format's (de)serialization |
| core | `core.error` | precise "what and where" errors for malformed input, not just "parse failed" |

## Anticipated API stress points
This app is where `core.convert`'s uniform conversion mechanism (Design Principle 4: one idiom per cross-cutting concern) either pays off — every format plugs into the same trait so the harness can iterate over "all known codecs" generically — or breaks down if any one format (e.g. CSV's ambiguous type inference) needs a genuinely different calling convention, which would be a real finding, not just friction.
