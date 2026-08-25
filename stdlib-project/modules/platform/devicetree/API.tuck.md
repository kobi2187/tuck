# platform.devicetree — Tuck translation

## The Nim pass's best finding here holds, and Tuck keeps it.

That pass discovered: *"Compile-time devicetree turned out freer than
expected. The `.dts` parser runs in Nim's compiler VM via `staticRead`, so
it may use `seq`, `string` and recursion — the no-`seq` rule constrains
**emitted** code, not the code that emits it. A failed claim on a
devicetree-declared pin becomes a **compile** error rather than a runtime
`none`."*

That distinction survives: whatever runs at build time is unconstrained by
the freestanding rules, and Tuck already has the pieces —
`when TARGET == "..."` for board selection (spec §8.3, run-verified) and
`register ... at 0x...` declarations that a generator can emit.

## The shape this suggests
Rather than a runtime API, this is a **build-time generator**: read the
board description, emit `register` declarations and pin constants. The
application then says `device"tempSensor"` and gets a compile error if the
board doesn't have one.

That is closer to Tuck's existing SVD-import story (spec §8.1: "one SVD
importer gives type-safe register access for the entire ARM Cortex-M
ecosystem") than to a library — and the two should probably be the same
mechanism.

## What's unresolved
- **No macro or compile-time file-reading facility is verified in Tuck.**
  `staticRead` is Nim's; whether Tuck exposes an equivalent decides whether
  this is in-language or an external codegen step. Same missing facility
  `std.serde-derive` and `std.testing::check` want — now a fourth demand.
- **Overlays** (the vendor escape hatch the Nim design named) are untouched
  here.
