# App: config-schema-validator

A CLI tool: `validate config.toml --schema app.schema.json` checks a config file against a declared schema (required fields, types, ranges, enums) and reports every violation with a precise location (file, line, column, field path) — not just "invalid config."

## Why this is a good validation target
This app is the purpose-built exercise for `std.reflect`/`std.serde-derive`'s schema-driven path and for `core.error`'s "what and where" precision requirement (first raised by `doc-convert-tester`, never deeply tested since). It also forces a direct, considered answer on whether YAML belongs in `std.encoding` — a real-world config format this app's users will expect to validate, and the third format (after `podcast-subscriber`'s XML and `diff-patch`'s unified-diff text) to test how far `std.encoding`'s scope is meant to stretch.

## Features
- Load a config file (TOML primarily; JSON as a secondary target since the schema format itself is JSON-Schema-like).
- Validate against a schema: required/optional fields, type checks, numeric ranges, string patterns, enum membership, nested object/array validation.
- Precise error reporting: every violation includes the field's path (`server.port`) and, where the source format supports it, the original file's line/column.
- `--strict` mode: reject unknown fields not declared in the schema (catch typos like `tiemout` instead of `timeout`).

## Modules exercised
| Tier | Module | Why |
|---|---|---|
| std | `std.reflect` / `std.serde-derive` | schema-driven validation — walking a decoded value against a schema description generically |
| std | `std.encoding` | TOML/JSON parsing — **and the forcing function for a real decision on YAML**, see validation note |
| core | `core.error` | field-path + source-location precision in every reported violation — the sharpest test yet of this requirement |
| std | `std.cli` | multi-violation report formatting (all errors at once, not fail-on-first) |
| std | `std.testing` | schema-validation logic is naturally table-driven (schema + input + expected violations) |
| alloc | `alloc.string` | building field-path strings (`server.tls.cert_path`) during nested traversal |

## Validation note: the YAML decision, made explicitly
YAML is conspicuously absent from `std.encoding`'s format list, and a config-validation tool is exactly where users will ask for it. The resolution proposed in `modules/std/encoding/API.md`'s update takes the same posture the report already applied to `std.gui`: YAML is deliberately excluded from `std`, not omitted by oversight. The reasoning: YAML's specification has genuine, repeatedly-exploited ambiguity (the "Norway problem" — unquoted `no`/`yes`/`on`/`off` silently becoming booleans instead of strings; implicit typing of version-looking strings as numbers) and a documented history of unsafe-by-default parsers in other ecosystems (arbitrary object construction via type tags, e.g. Python's historical `yaml.load` before `safe_load` became the recommended default). Given `std.encoding`'s existing precedent — the XML codec exists specifically *because* its dangerous mode (DTD/entity resolution) could be structurally removed while keeping the useful part — and YAML's ambiguity is load-bearing to the format itself, not an optional extension, the module takes the position that YAML support belongs in the extended ecosystem, where a specific library can make and own that safety/ergonomics tradeoff, rather than in `std` where the safe subset can't be cleanly separated from the unsafe one the way it could for XML.
