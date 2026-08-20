# std.serde-derive

## Purpose
Compile-time code generation of `Encode`/`Decode` (and, optionally, `Reflect`) implementations for a type, so performance- or startup-time-sensitive code paths never pay a runtime introspection cost — the static alternative to `std.reflect`'s dynamic path, implementing the exact same `std.encoding` interface.

## Design lineage
Modeled directly on Rust's `serde_derive` macros (`#[derive(Serialize, Deserialize)]`): a compile-time code generator (proc-macro or equivalent metaprogramming facility) reads a type's field declarations once, at compile time, and emits a hand-written-quality `Encode`/`Decode` implementation with no runtime field enumeration, no dynamic dispatch, and no per-call metadata lookup — the generated code is, by design, indistinguishable from what a careful engineer would write by hand for that specific type.

## Proposed API
```
// The attribute surface a type author writes. The compiler/build step consumes this and emits
// a concrete `impl Encode for T` / `impl Decode for T` — no trait object, no vtable, at std.encoding call sites.
#[derive(Encode, Decode)]
struct EpisodeRecord {
    #[serde(rename = "guid")]
    id: alloc::string::String,
    title: alloc::string::String,
    #[serde(default)]
    listened: bool,
    #[serde(skip)]
    _cache: Option<alloc::vec::Vec<u8>>,          // never encoded/decoded at all
    #[serde(with = "std::chrono::iso8601")]        // per-field custom codec hook
    published_at: std::chrono::ZonedDateTime,
}

// Field-level attributes the derive understands — a small, closed set, deliberately not
// a general-purpose annotation/plugin system.
// #[serde(rename = "...")]   — wire name differs from the Rust-side field name
// #[serde(default)]          — missing input field decodes to Default::default(), not an error
// #[serde(skip)]             — field participates in neither encode nor decode
// #[serde(with = "path")]    — delegate this field's (de)serialization to a named Codec-shaped module

// Enum support: tagged by default (matches std.encoding.json's convention for every codec, not just JSON).
#[derive(Encode, Decode)]
enum Event {
    Joined { user: alloc::string::String },
    Left { user: alloc::string::String },
}
// encodes as { "type": "Joined", "user": "..." } in JSON; the same tag/variant shape in every other Codec.

// What the derive actually emits (conceptually) — this is the contract, not a callable API surface:
// impl std::encoding::Encode for EpisodeRecord {
//     fn encode_to(&self, e: &mut dyn std::encoding::Encoder) -> core::types::Result<(), core::error::Error> {
//         e.field("guid", &self.id)?; e.field("title", &self.title)?; e.field("listened", &self.listened)?;
//         e.field("published_at", &iso8601::encode(&self.published_at))?; Ok(())
//     }
// }
// impl std::encoding::Decode for EpisodeRecord { /* mirrors the above, field-by-field, no reflection */ }
```

## Key design decisions
- **The generated code implements exactly the same `std.encoding::Encode`/`Decode` traits `std.reflect`'s generic bridge implements** — a `Codec` (json, toml, csv, binary, xml) never knows or cares whether a given type's implementation came from `serde-derive`, `std.reflect`, or hand-written code, which is Principle 4's "one interface" applied at the implementation-strategy level, not just the format level.
- **The attribute set is small and closed** (`rename`, `default`, `skip`, `with`) rather than an extensible plugin/macro system — this is a deliberate ceiling: anything more exotic (conditional fields, cross-field validation) is expected to be a hand-written `Encode`/`Decode` implementation, keeping the derive itself simple enough that its generated code stays auditable and its compile-time cost stays low.
- **Enum tagging is uniform across every `Codec`, not format-specific** — a JSON-flavored "internally tagged" vs. "externally tagged" vs. "adjacently tagged" choice is exactly the kind of per-format divergence that would break the one-`Codec`-interface promise the moment a type moved from `json` to `csv` or `binary`; the derive picks one tagging convention and every codec backend honors it identically.
- **`#[serde(skip)]` fields are compiled out of the generated code entirely**, not filtered at runtime — a skipped field costs literally nothing at either compile time (beyond the derive itself) or runtime, which matters for `_cache`-style fields on hot-path types where even a runtime `if skip { continue }` check would be an unwanted branch.

## Validated by applications
- **mp3-player**: the binary struct-packing case — ID3v2 frame decoding is exactly the performance-sensitive, called-per-file-load path the module exists for; `#[derive(Decode)]` over a fixed-layout frame struct (through `std.encoding::binary`) generates field-by-field byte-offset reads with no dynamic dispatch, which matters because tag reading happens synchronously on playlist load and must not introduce reflection-driven overhead on a path the app's own profile already flags as latency-sensitive (adjacent to the real-time audio thread, even though tag reading itself is off that thread).
- **podcast-subscriber**: the primary consumer for enum tagging and `#[serde(with = ...)]` — `EpisodeRecord`-shaped types decode from JSON (local library index) and need `published_at` to route through `std.chrono`'s date parsing rather than a generic string field, which is what motivated the `with` attribute existing at all rather than requiring every date-bearing type to hand-write its `Decode` impl just for one field.
- **config-schema-validator (negative validation)**: deliberately does not use `std.serde-derive` for the config-file-under-validation path — the app's whole premise is that the config's shape is checked against an externally supplied, runtime-loaded schema, not a compile-time-known Rust type, so there is no struct to `#[derive(Decode)]` against in the first place. The app decodes via `std.encoding`'s `decode_value` instead (see `modules/std/reflect/API.md`'s `DynValue::Map` addition). This is the same category of negative validation `secrets-vault` provided for `std.reflect` against `todo-cli`'s comparison point below — it confirms that `serde-derive`'s compile-time-derive story and `std.reflect`'s per-type-opt-in story are both, correctly, *not* the mechanism for a fully dynamic-schema problem, which needed a third path (`std.encoding::decode_value` plus `DynValue::Map`) that didn't exist in either module before this round.
- **todo-cli**: uses `serde-derive` for the hot-path local task-database encode/decode (every `todo list` re-reads and re-parses the full task file), deliberately choosing it over `std.reflect` for this type specifically because the file is re-parsed on every invocation of a CLI tool where startup latency is user-visible — this is the concrete comparison point against `std.reflect`'s choice for the same app's JSON-import-diffing path, validating that both mechanisms coexist per-type within one program without conflict.

## Open questions / risks
Whether the derive mechanism requires a genuine compile-time macro/codegen facility in the host language (as Rust's proc-macros do) or can be approximated via a build-step code generator for languages without macros is a language-implementation question this API-level design defers; the attribute surface above is written to be implementable either way.
