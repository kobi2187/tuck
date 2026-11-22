# svd2tuck — vision

One CMSIS-SVD file becomes one importable Tuck module of `register`
declarations. The tool is a standalone Nim program outside the compiler; its
only product is Tuck text the existing compiler already understands.

## Ranked goals

1. Deterministic, byte-stable output for a pinned SVD.
2. Exact addresses and bit ranges for the fields a board program uses.
3. Honest notes for every SVD feature the Tuck register surface cannot carry.
4. Reproducible generation from vendored, licensed inputs.

## Non-goals

- No changes to the Tuck grammar, AST, or checker for T8.
- No field enums, reset values, read actions, clusters, or typestate. Those are
  separate language decisions; this tool emits what `register ... at ...`
  means today.
- No Rust stage, no JSON IR interchange, no Rust in CI.

## Parked questions (resolving signal)

- **Typed register access / sealed transitions.** Resolve when Tuck has a
  type surface that can express a write-once field; the signal is a decision in
  `LANGUAGE-OVERVIEW.md`, not in this tool.
- **Peripheral instances and clusters.** Resolve when a board needs two
  instances of one peripheral; the signal is a generated-name collision that
  `--prefix` cannot settle.
