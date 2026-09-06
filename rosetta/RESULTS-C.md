# RESULTS-C — structs, sum types, data-shaping

20 examples in `rosetta/examples/c01..c20`. Verified with `tuck check` then
`tuck build` (+ run the binary when it built). Status legend:
GREEN = builds and runs correctly. CHECKS = `tuck check` OK but `tuck build`
fails (Nim compile error). PARSE = parser rejects the `.tuck` source itself.
NEEDS = uses an invented (`pending:`) fn — runs the stub, not real logic.

Revised after reframe: leaned into inventing stdlib fns wherever the natural
way to write a task needed one (`sqrt`, `describe`, `unwrapOr`), and swapped
one hand-rolled comparison (c17) for the built-in `==` to test whether
structural equality is already a language feature — it is (see below).

| file | task | status | detail |
|---|---|---|---|
| c01-point-distance.tuck | distance between two Points, `sqrt` via pending | NEEDS | builds+runs; `sqrt` is a stub (prints "TUCK PENDING", returns 0) since no math stdlib exists |
| c02-rectangle-area.tuck | Rectangle struct, area + perimeter | GREEN | ran, printed `20` / `18` |
| c03-person-record.tuck | Person record, greet fn, `describe` formatter via pending | NEEDS | builds+runs; `describe` is a stub — printed an empty line instead of "TUCK PENDING: ..." (str-returning pending stubs appear to return `""` silently rather than logging, unlike void-returning stubs — worth a follow-up bug) |
| c04-struct-field-update.tuck | struct field update via `..` mutator chain | GREEN | ran, printed `3` |
| c05-nested-structs.tuck | Address nested inside Person | GREEN | ran, printed `Springfield` / `12345`. (Originally named the local `addr`, which collided with Nim's `addr` keyword and failed the Nim build stage — renamed to `home` and it built clean. Root-cause bug recorded separately below, not dodged, just worked around in the file since a keyword collision isn't the feature under test) |
| c06-shape-sum-type.tuck | Shape sum type (Circle/Square), match computes area | CHECKS | `tuck check` OK; Nim build fails: `c06_shape_sum_type.nim(12, 18) Error: selector must be of an ordinal type, float or string`. Codegen emits `case s of Circle: ...` — matching directly on the *value* `s` (an object) instead of on `s.kind`; the discriminant field is never referenced |
| c07-color-enum.tuck | Color enum-like sum type (Red/Green/Blue), match to name | CHECKS | `tuck check` OK; Nim build fails: `c07_color_enum.nim(15, 8) Error: the special identifier '_' is ignored in declarations and cannot be used`. Tuck's catch-all match arm `_: "unknown"` is lowered to a Nim `of _:` branch, but Nim's `_` is a discard-pattern, not a wildcard case label (needs `else:`) |
| c08-direction-enum.tuck | Direction sum type + `decision` table for movement delta | CHECKS | `tuck check` OK; Nim build fails: `c08_direction_enum.nim(14, 18) Error: attempting to call routine: 'North'`. Constructing a payload-less variant `{} North` lowers to a call `North()`, but codegen made `Direction` a plain Nim `enum` (bare enum constants, not callable) — construction syntax and the enum-only representation disagree |
| c09-optional-value.tuck | `?T` optional value from a pending fn, unwrapped with `unwrapOr` | CHECKS | `tuck check` OK; Nim build fails: `c09_optional_value.nim(11, 16) Error: undeclared identifier: 'unwrapOr'`. Codegen emits `unwrapOr(maybeName)("unknown")` (curried call) instead of `unwrapOr(maybeName, "unknown")` — calling an invented (`pending`-implied) fn in postfix method position with a struct-literal argument on an optional value produces malformed Nim, a distinct bug from the c06/c18 match-scrutinee issue |
| c10-result-error-handling.tuck | `!T` result-returning fn, `?` propagation, `fail` | PARSE | `Expected expression but got: tkQuestion` on `let r = {a, b} divide?` (line 8, col 28). The postfix propagation operator `expr?` documented in SYNTAX.md is not accepted by the parser after a postfix call expression — `divide?` itself parses, but `{args} fnName?` (payload-call immediately propagated) does not |
| c11-temperature-invariant.tuck | Temperature type with `invariant: celsius >= -273` | GREEN | ran, printed `21`; invariant declared but not exercised (no violating construction attempted) |
| c12-distinct-units.tuck | `distinct Meters/Feet`, prevent mixing, convert via multiply | Type error at check | `tuck check` fails: `Type Error: arithmetic between Feet and float at line 8:10` (`f * 0.3048`). The distinct-unit safety works as advertised but there's no ergonomic conversion path — a natural unit-conversion fn is a type error, not merely inconvenient |
| c13-merge-structs.tuck | `merge` two structs (Episode + Prefs) into one context | GREEN | ran, printed `Pilot` / `80` |
| c14-alias-rename-fields.tuck | `alias` renames incoming fields to local call shape | NEEDS | builds+runs; `playTrack` is a pending stub |
| c15-bake-partial-application.tuck | `bake` partial application, then apply | GREEN | ran, printed `15` |
| c16-fnsig-callback.tuck | `fnsig` named signature, `:name` fn ref passed as callback | GREEN | ran, printed `7` |
| c17-compare-records.tuck | compare two Point records for equality via built-in `==` | GREEN | ran, printed `true` / `false`. **Structural equality on records is already a language feature — no stdlib fn needed.** (Originally hand-rolled with `a.x == b.x and a.y == b.y`; swapped to plain `p1 == p2` to test this directly, and it just works) |
| c18-tagged-union-interpreter.tuck | tiny Add/Sub/Lit tagged-union expression evaluator | CHECKS | `tuck check` OK; Nim build fails: `c18_tagged_union_interpreter.nim(13, 18) Error: selector must be of an ordinal type, float or string`. Same root cause as c06 — `match` on a 3-variant sum type also matches on the object value instead of `.kind` |
| c19-bank-account-invariant.tuck | Account with non-negative-balance invariant, deposit/withdraw via `..` | GREEN | ran, printed `120`; invariant declared but not exercised |
| c20-decision-over-sum-type.tuck | `decision` table keyed on a sum-type variant + bool | CHECKS | `tuck check` OK; Nim build fails: `c20_decision_over_sum_type.nim(14, 17) Error: attempting to call routine: 'High'`. Same root cause as c08 |

## Tally (20 files total)

- GREEN: 10 — c02, c03(needs-ish, counted below), c04, c05, c11, c13, c15, c16, c17, c19 — corrected: c03 is NEEDS (uses a pending stub), so GREEN = 9: c02, c04, c05, c11, c13, c15, c16, c17, c19
- NEEDS: 3 — c01, c03, c14 (build+run, but exercise a `pending:` stub, not real logic)
- CHECKS: 6 — c06, c07, c08, c09, c18, c20 (typecheck OK, Nim build fails)
- PARSE: 1 — c10 (`{args} fnName?` propagation rejected by the parser)
- Type-checker rejects natural code: 1 — c12 (distinct-unit conversion is a type error)

9 + 3 + 6 + 1 + 1 = 20.

## Top 5 most painful expressiveness problems

1. **Sum-type `match` is fundamentally broken for anything beyond 2 payload-bearing variants.** `case s of Circle: ... of Square: ...` gets codegen'd as matching on the *struct value itself*, not `s.kind`. Breaks c06, c09, c18 — the single most central "data-shaping" feature (sum types + match) does not build in the common case.

2. **Payload-less sum-type variants (`{} North`, enum-like Color/Direction) are inconsistently codegen'd.** Represented as a bare Nim `enum` (works fine for `decision` tables — c08's key-packing succeeds) but variant *construction* syntax `{} North` still lowers to `North()`, a call on a non-callable enum value. Breaks c07, c08, c20.

3. **The catch-all `_` arm in `match` mis-lowers to Nim's `_` discard pattern instead of `else`.** Independent bug from #1 — c07 fails purely on this even where the scrutinee issue wouldn't otherwise bite.

4. **`{args} fnName?` (call + immediate propagate) is a parse error.** SYNTAX.md documents `expr?` for propagation but the natural one-liner postfix-call-then-propagate form isn't accepted (c10).

5. **Calling an invented/pending fn in postfix-method position with an argument struct mis-lowers to a curried call.** `maybeName unwrapOr {default: "unknown"}` becomes `unwrapOr(maybeName)("unknown")` in Nim instead of `unwrapOr(maybeName, "unknown")` (c09) — a second, independent bug in the same file family as #1/#2, suggesting postfix-call lowering onto not-yet-implemented stdlib fns needs its own test coverage.

## Notes on local codegen reserved-word collision (c05, worked around)

Not counted as a top-5 item since it's a narrow lexical issue, but worth
recording: local variable naming in codegen doesn't avoid Nim reserved
words. A local named `addr` (completely ordinary Tuck identifier) collides
with Nim's `addr` keyword, failing the Nim compile stage with a raw Nim
"identifier expected" error instead of a clean Tuck diagnostic. Same failure
class as the previously-discovered `xs[i]`/`import seq` diagnostic gap
(DISCOVERIES.md) — Nim keyword/identifier leakage into user-facing errors.
Worked around in the file (renamed to `home`) since the collision isn't the
struct-nesting feature under test; c05 is GREEN as a result.

## Proposed stdlib API

Every fn invented across this batch because natural code needed it and
nothing existed, grouped by module, ranked by how many examples wanted it.
Full signatures as written in the `pending:` blocks.

### module `math` (1 example wanted this — but it's the single most obvious gap)

```tuck
fn sqrt({value: int}) -> int
```
Needed by: c01 (Point distance — the textbook first thing anyone reaches for
once they have two structs with numeric fields). Distance/geometry math is
about as core as it gets; not having `sqrt` at all means every
geometry/physics-flavored example has to invent it. **Ranked #1 despite only
1 example** because it's not domain-specific — almost any numeric program
eventually wants it, and its absence was the very first wall hit in this
batch.

### module `opt` (optional-value handling — 1 example, but structural)

```tuck
fn unwrapOr[T]({self: ?T, default: T}) -> T
```
Needed by: c09. `?T` optional types are a language feature with essentially
no accompanying stdlib — there's no way to get a plain value out of an
optional without a `match`. `unwrapOr` is the single most common thing done
to an optional in any language that has them (Rust, Swift, Kotlin all ship
it as the first method on their optional type). Its absence also happens to
be where the curried-call codegen bug (#5 above) was found, so fixing this
gap and the bug are linked.

### module `fmt` / auto-derived (record formatting — 1 example, but likely wanted everywhere)

```tuck
fn describe({self: Person}) -> str
```
Needed by: c03, written as a per-type fn because there is no way to turn an
arbitrary struct into readable text. This is the one invented fn I'd
actually argue should NOT land in `fmt` as hand-written per-type functions —
see the design ruling below. Every example in this batch that wanted to
`printLine` a record (c02, c03, c05, c11, c13, c19) ended up manually
picking fields and calling `toStr`/`printLine` per field instead, because
there is no generic "turn this struct into text" operation at all.

### Already covered / no stdlib gap (confirmed by testing directly)

- **Structural equality (`==` on records)** — c17. Already works as a
  language feature; no `equals`/`compare` stdlib fn needed. Confirmed by
  writing `p1 == p2` directly instead of hand-rolling field comparisons —
  it built and ran correctly (`true`/`false`).

## Design ruling: stdlib fn vs. language feature vs. compiler-derived

Answering the specific question asked — for each candidate, what it should
be:

- **Structural equality (`==` on records).** Already a language feature.
  **Correct as-is — do nothing.** Confirmed working in c17; this is not a
  gap.

- **Printing/formatting a struct (`describe`, "turn a record into text").**
  Should be **compiler-derived, not stdlib, not hand-written per type.** The
  same reasoning that makes `==` a language feature applies even more
  strongly here: a hand-written `fmt` module fn can't know a struct's field
  names or count, so at best it'd be a macro-like magic fn, and at worst
  every type author has to write their own `describe`/`toStr` boilerplate
  (which is exactly what c02/c05/c11/c13/c19 were reduced to: printing
  fields one at a time by hand). The compiler already knows every field name
  and type at the point it emits the struct — auto-deriving a default
  `{self: T} toStr -> str` (and printing it as `TypeName{field: value, ...}`,
  Rust-`Debug`-style) the same way it already auto-derives constructors from
  `{fields} TypeName` costs nothing extra to discover and removes the most
  common piece of boilerplate seen across this entire batch.

- **Comparison for sorting / ordering (`<`, `compare`).** Not exercised
  directly in this batch (no sort-a-list-of-records example), but by the
  same logic as equality: if `==` is already structural/derived, ordering
  should be too, *for records with a natural field order* — but only as an
  opt-in (`derive Ord` or similar), since not every struct has a sensible
  total order (e.g. Shape doesn't). Recommend: **language/compiler feature,
  opt-in via a marker**, not a stdlib fn — a hand-written `compare` fn
  can't express "lexicographic by field declaration order" any more
  naturally than the compiler already can.

- **`sqrt` and general math.** Should be **stdlib** (`math` module). This is
  ordinary numeric-domain library code with no relationship to Tuck's type
  system or struct machinery — exactly the kind of thing a stdlib module
  exists for. No language feature is implied.

- **`unwrapOr` (and friends: `map`, `isSome`, `isNone` on `?T`).** Should be
  **stdlib**, but tightly coupled to the `?T` language feature — i.e. a
  small `opt` module that ships as a "supports the optional-type feature"
  library, analogous to how `seq::at`/`setAt` already back the `xs[i]`
  sugar (per DISCOVERIES.md). Not compiler-derived, because unlike equality
  or printing, unwrap semantics need a caller-supplied default/handler —
  there's no single obviously-correct auto-derivation.
