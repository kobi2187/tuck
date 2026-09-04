# sudoku-solver — dogfooding findings

## What was built

A single hardcoded 9x9 puzzle (the canonical "5 3 . . 7 . . . ." example),
solved by plain backtracking search over a flat 81-cell `Seq[int]` (0 =
blank), printed to stdout. No puzzle parser, no file I/O, no generator, no
uniqueness check, no difficulty rating, no naked/hidden-single constraint
propagation — APP.md's full scope is a solve+generate CLI tool with a real
grid-format parser and a difficulty rater; this slice only proves the core
algorithmic loop (backtracking + row/col/box validity) compiles and runs
end to end using nothing but `console`, `str`, and `seq`. It typechecks
(`./tuck ch`), builds, and runs, producing a correctly solved grid.

## Missing stdlib functions needed

None. `console.printLine`, `str.toStr`, and `seq`'s `at`/`setAt` (via bracket
sugar) were sufficient. No `pending:` stubs were needed — everything used is
already implemented in `std/*.tuck` today. `core.array`'s fixed-size 2D grid
and `core.num` bitset ops that APP.md anticipates were not needed either: a
flat `Seq[int]` addressed by `row*9+col` covered the whole grid.

## Compiler bugs / friction hit

**Real bug: `xs[i]`/`xs[i] = v` on a `Seq[T]` silently requires `import seq`,
and the failure mode is a broken Nim compile, not a Tuck-level diagnostic.**

Reproduced: with only `import console` and `import str` (no `import seq`),
`./tuck ch stdlib-project/apps/sudoku-solver/sudoku.tuck` reports `OK` — the
checker is satisfied. `./tuck b` then fails at the Nim stage:

```
/tmp/tuck-sudoku-solver-out/sudoku/sudoku.nim(12, 11) Error: undeclared identifier: 'seq_at'
candidates (edit distance, scope distance); see '--spellSuggest':
 (1, 9): 'setAt'
```

Root cause, `compiler/typecheck.nim:2708-2717` (`indexCallee`): bracket
indexing on a `Seq[T]` always resolves to a qualified call
`exkQualified(modulePath: ["seq"], qualName: "at"/"setAt")`, regardless of
whether the source file actually wrote `import seq`. `compiler/codegen.nim:60-71`
(`genQualified`) then does `modName & "." & qualName` if `modName` is a real
imported module, else falls back to `modName & "_" & qualName` — the fallback
meant for C-style prefix-mangled externs. Since `seq` was never imported,
`ctx.realModules` doesn't contain it, so bracket indexing silently degrades
into `seq_at(...)`, an identifier that doesn't exist anywhere (`tuck_rt.nim`
only defines bare `at`/`setAt`). Adding `import seq` (even though nothing in
the file calls a `seq.`-qualified function directly; only the `[]` sugar is
used) fixes it immediately and produces a correct, running binary.

This is real friction: the bracket-sugar syntax (`grid[i]`, documented in
LANGUAGE-OVERVIEW.md §16 with no mention of needing an import) works at the
type-check stage without the import, then breaks two stages later with an
error that names a nonexistent Nim identifier instead of pointing back to the
missing `import seq`. Two independent fixes would each close this: (a) make
`indexCallee` require/insert an implicit dependency on `seq` whenever it
resolves a `Seq` index (so no explicit import is needed, matching that the
sugar is baked into the language, not a std call the user spelled out), or
(b) if an explicit import is meant to be required, have the checker (not just
codegen) reject a `Seq` index with no `import seq` in scope, with a real
`TK-` diagnostic instead of a Nim-stage failure.

No other compiler bugs found. The `object` + `self`-mutation exemption
(LANGUAGE-OVERVIEW.md's surprise-table #11 / tuck-spec.md §7.1) worked exactly
as documented for the backtracking's shared mutable state — see below.

## Interface/mixin/actor design notes

No `interface` or `mixin` fit naturally here — there is exactly one solving
technique (backtracking) and one grid representation, so there's no
polymorphism point to name. No `actor` either: there's no need for a single
globally-addressable coordinator; the whole program is one board, solved
once, in one call stack.

The one design choice that mattered was wrapping the grid in `object Board:
cells: Seq[int]` rather than passing a bare `Seq[int]` between plain `fn`s.
A plain `fn solve({grid: Seq[int], pos: int})` that tries `grid[pos] = val`
is rejected at typecheck with `TK-TY15` ("cannot assign into parameter 'grid'
— a parameter is a value the caller owns, not a var") — correct per spec:
Tier 1 params are never writable through. Backtracking search is inherently
about mutating one shared structure across a recursive call stack (place a
digit, recurse, undo on failure), so it is a textbook case for the
documented `self`-mutation exception: making the grid an `object`'s own field
and every solving step a member fn (`self.cells[pos] = val`) let the checker
allow exactly the same in-place mutation, recursively, with no copying and no
threading a return value back up. This is a good, sharp illustration of *why*
the object-self exception exists — a fully immutable-record version of this
algorithm would need every recursive call to return a whole new board, which
would work but is a strictly worse fit for what the algorithm is actually
doing.

## Joy-of-use verdict

Pleasant, once past the one real bug above. The payload-call convention reads
well for this kind of code (`{self: self, row: row, col: col, val: val}
valid` is no worse than a normal call, and chaining `line + grid[...].toStr +
" "` for the printer is genuinely nice). The `object`/`self`-mutation model
mapped cleanly onto backtracking's "mutate, recurse, undo" shape — better
than I expected going in, given Tier 1's value-semantics-by-default stance.
The only real friction was the silent `import seq` requirement for bracket
sugar, which cost a full build-and-read-the-Nim-output cycle to diagnose
because the type checker had already said `OK`.
