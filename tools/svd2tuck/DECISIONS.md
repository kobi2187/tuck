# svd2tuck — decisions (append-only)

## 2026-11-21 — Adapt svd2nim's parser front half, not its emitter

Examined: the Rust `svd2rust` family (the obvious prior art) and
`EmbeddedNim/svd2nim` v0.6.2 (MIT, last touched 2024-08-21, ~3,348 LOC).
Chose the Nim front half (`svdparser.nim`, `basetypes.nim`,
`transformations.nim`, `utils.nim`) verbatim and wrote a small Tuck emitter;
discarded svd2nim's 987-line `codegen.nim`. Rationale: the parsed model is
exactly what we need, the output surface is only `register ... at ...`, and a
Rust binary plus output converter would add a second language and a lossy parse
of generated Rust for no gain. Rejected: a Tuck-in-Tuck generator (the
compiler has no SVD XML reader and T8 must not grow the grammar).

## 2026-11-21 — One module per SVD, standalone tool

Chose a standalone Nim tool under `tools/svd2tuck/` rather
than a `tuck svd` subcommand. The tool's output is ordinary Tuck text, so the
compiler stays unaware of SVD; a board program imports the generated module.
Rejected: making SVD a compiler dependency (embedding XML parsing and vendor
overlays in the compiler) and emitting multiple files per device (Tuck has one
global register namespace per program).

## 2026-11-21 — Apache-2.0 SVD input

Used `modm-io/cmsis-svd-stm32/stm32f1/STM32F103.svd` instead of svd2nim's
bundled `tests/STM32F103.svd`, which has no explicit licence header. The
licence is vendored beside it.

## 2026-11-21 — Overlay for board-sized output

Whole-device generation is correct but makes Nim host codegen take 102 s.
Rather than change the generator's semantics, added `--overlay bluepill.json`
to keep only RCC and GPIOC, and committed both outputs. The full module stays
as the scale artifact; the small one is the test fixture.
