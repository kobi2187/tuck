# App: sudoku-solver (solver + generator)

A CLI puzzle tool: `sudoku solve puzzle.txt` solves a 9x9 Sudoku via constraint propagation (naked/hidden singles) falling back to backtracking search; `sudoku generate --difficulty hard` generates a new puzzle with a verified-unique solution and a difficulty rating based on which solving techniques are required.

## Why this is a good validation target
This app is deliberately chosen to use almost nothing above `core`/`alloc` — no filesystem beyond trivial text I/O, no networking, no concurrency requirement, no encoding beyond the simplest possible text grid format. It is the project's control case for a specific, important claim: that a purely algorithmic weekend project (constraint satisfaction, backtracking search, bitset-based candidate tracking) needs *nothing* from `sys`/`std`/`platform` at all — if `core`+`alloc` alone don't make this pleasant to write, the tiering's bottom layers have a real usability problem regardless of how good the upper layers are.

## Features
- Parse a simple 81-character or 9-line grid format (givens + blanks).
- Solve via constraint propagation (candidate elimination: naked singles, hidden singles, pointing pairs) with backtracking search as a fallback for puzzles that need it.
- Generate: start from a solved grid, remove cells while a uniqueness check (does removing this cell still leave exactly one solution?) holds, down to a target difficulty.
- Difficulty rating based on which technique tier was needed (pure constraint propagation = easy; backtracking depth = hard).
- Print the grid, and optionally an annotated candidate-set view for a partially-solved puzzle.

## Modules exercised
| Tier | Module | Why |
|---|---|---|
| core | `core.num` / bitset operations | each cell's candidate set (1-9) is naturally a 9-bit bitset — the app is a direct test of whether `core.num`'s integer API makes bit manipulation (set/clear/test/popcount/iterate-set-bits) pleasant, or whether the app is forced into manual shift-and-mask code |
| core | `core.array` | the fixed 9x9 grid — a compile-time-sized `[[Cell; 9]; 9]` or similar, testing `core.array`'s ergonomics for 2D fixed-size data (contrast with `alloc.vec::Grid<T>`, added for diff-patch's dynamically-sized case) |
| core | `core.iter` | iterating rows/columns/3x3 boxes as a unified abstraction — a real test of whether one iterator adapter chain can express "all 27 constraint groups" cleanly |
| alloc | `alloc.vec` | the backtracking search stack/undo log |
| std | `std.random` | puzzle generation's initial solved-grid randomization and cell-removal order |
| std | `std.testing` | the generator's uniqueness-check and the solver's correctness are both naturally property-tested (`solve(generate()).is_some()`; a generated puzzle never has two distinct solutions) |
| sys | `sys.fs` | trivial: reading a puzzle file, if not given on stdin |

## Anticipated API stress points
`core.array`'s fixed-size 2D grid versus `alloc.vec::Grid<T>`'s dynamically-sized 2D grid (added for `diff-patch`) is a clean, deliberate contrast case: does the stdlib's story for "a grid of things" hold together as one coherent idea across the freestanding/heap boundary, with the compile-time-sized version in `core` and the runtime-sized version in `alloc` sharing an indexing convention, or do they end up as two unrelated designs that happen to solve similar problems? This app is the first to actually need the `core`-tier fixed-size case, so it's the first opportunity to check that consistency. Bitset operations are the other real question: does `core.num` already have popcount/iterate-set-bits primitives (needed on essentially every microcontroller and DSP algorithm too, not just this puzzle), or does this app reveal that "bit manipulation as a first-class citizen" was under-specified in the original core.num design.
