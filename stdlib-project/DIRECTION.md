# Stdlib direction: a contract and blessed implementations

Owner, 2026-10-09/10. This is the plan the rest of `stdlib-project/` is moving toward.
Where an older document here disagrees, this one wins. It extends the three-rung model in
`GOVERNANCE.md`, which it does not replace.

## The shape

| Rung (GOVERNANCE.md) | Here |
|---|---|
| A: `std` proper | **the contract**: groups (`value`, `collection`, `io`, `serde`, `format`, ...). A group names operations and carries no code. This is the stable surface. |
| B1: blessed, bundled | **blessed implementations**: satisfiers maintained with the language and shipped with the toolchain. A program gets one per group by default. |
| C: community | **anyone's satisfiers** for the same groups: to test, compete or improve. A good one can graduate to blessed. |

## Mix and match, per group

There are three ways to write a satisfier, and one program can use all three:

- a **shim**: `extern [impl: nim "...", odin "...", d "..."]`, binding each backend's own
  library (`tests/suites/extern_impl.nim`);
- an **ffi** extern: `extern [c, header: "..."]`, one C source for primitive operations;
- **pure Tuck**, over whatever primitives sit below it, possibly replacing them.

Progress is gradual and per group. A group's blessed satisfier moves from shim to ffi to
pure only when a time and memory comparison on each backend favours the move. The v2 rule
"one satisfier per group per program" keeps any mix sound: each operation has exactly one
provider, visible at the call.

## Choosing implementations

A compiler flag names the stdlib entry point, `--stdlib:NAME`, after `--target:NAME`:

- the entry module imports one satisfier per group; the blessed set is the default entry;
- a user, or a next-version stdlib, points `--stdlib` at its own entry, which can import
  the blessed satisfiers for most groups and its own for the ones it is testing;
- `STDLIB == "NAME"` is testable in `when` blocks, as `TARGET` is.

Tracked as #105.

## Temporary support code

Today's `std/` (`seq str bits console fs sys net scheduler time`) exists to support
language features while they settle. It stays until the stdlib step, then merges into the
contract and the blessed satisfiers. After that it is not a separate layer.

## Order

The stdlib comes after the bugs, the design decisions, and the important features, so it
is built on a language that holds still (ROADMAP.md, "Direction 2026-10-10"). The steps:

1. **Contract**: the v2 groups move into `std/`, reviewed against the settled language.
2. **Entry point**: `--stdlib:NAME` and the `STDLIB` define.
3. **Blessed satisfiers** for every group the weekend kit, `examples/` and the apps use,
   each picking shim, ffi or pure on its merits. Today's `std/` code is absorbed here.
4. **Comparison bench**: program × satisfier × backend, wall time and peak memory, in
   `benches/SCORES.md`.
5. **Conformance suite**: any satisfier, blessed or community, can show it meets its group
   with one command.

Later, on the same groups: managers (the role types composed with `+`, VISION.md), some of
them actors.

## Open questions

- **Where satisfiers live.** Imports resolve within a file's own directory or `std/`. Either
  blessed satisfiers sit under `std/` beside the contract, or `--stdlib` adds its entry
  module's directory to the search path. The second lets community implementations live
  outside the toolchain.
- **What conforming means.** Type-checking against the group, or also passing the
  conformance suite? Blessing should need the second.
