# `repr`: a compiler-baked debug text for any value (design brief)

Status: **design needed, nothing built.** Owner ruling (2026-11-09): `repr` is a
compiler builtin; there is **no library introspection**. Only the compiler bakes
type information into types, so a library cannot walk a value it knows nothing
about. (`std/reflect` today is a schema/validation library over `Json`, not
type introspection; whether it stays is a separate question for the owner.)

## What it is for
`{value: x} repr` -> `str`: `Point{x: 1, y: 2}`, `[1, 2, 3]`, `Circle{r: 3}`,
`some(5)` / `none`, `err NotFound`. Used by: a failing `expect` (what was
compared), a property-test failure (the shrunk counterexample), `tuck`'s own
diagnostics and a debugger-free "print what this is".

## Constraints (from the language)
* One answer on all three backends, byte for byte (the A67 rule for floats).
* No stored pointers, no cycles: values are finite trees, so output is finite.
* Value semantics: `repr` reads, never moves or copies the argument (a view).
* Effect-free (`[pure]`), allocation only for the result.
* Sum types, optionals, results, `Seq`, `Array`, records, objects, actors'
  public state, slabs/pools (handles print as handle ids, not contents).

## Where it lives in the pipeline
The checker already knows every type. Option A (recommended): lowering emits,
per type that reaches a `repr` call, one generated function
`repr_T(v) -> str` that calls the generated functions of its fields, exactly
like the per-type copy/drop glue (ownership rule G, and #206 for Odin). The
shared lowering decides the shape once; each backend only prints it (the #106
rule). Option B: a runtime walker over type info; rejected because Odin pays
for it today (#206) and it is the "library introspection" the owner rules out.

## Open questions for the owner
1. Spelling: a builtin fn `repr` (a payload call like any other) vs a
   `{...} .repr` postfix only? Recommendation: ordinary payload call, so it
   composes (`x repr printLine`).
2. A user override: may a type define its own text (a fn named `reprOf` for
   `T` that the generated code prefers)? Recommendation: yes, one fn, found by
   the same receiver rule as any group satisfier.
3. Depth/width limits for large values (a 10 MB Seq)? Recommendation: a
   second form with a limit; the plain form prints everything.
4. Records with `[view]`/secret fields (core.mem handles): print as
   `<secret>`? Recommendation: a field attribute that suppresses its value.
5. Does this feed `serde-derive` later? Same per-type generation, other text.
   Design the generator once, use it for both.

## Not in scope
Parsing the text back, pretty-printing with line breaks (a later layer over the
same generated tree walk), and any runtime type reflection.
