# Batch D — Collections / Arrays

20 examples, `d01`–`d20`. Verified with `tuck check` then `tuck build` +
run for every file (`--root:/home/kl/prog/tuck_lexer`, options after the
file). No compiler bugs were fixed — only recorded, each with a minimal
(<15-line) repro.

**Correction pass:** the original submission wrongly reported `for cond:`
(while-style loop) as broken. It isn't — I had literally copied the
metavariable name `cond` out of SYNTAX.md's `for cond:` illustration
instead of writing a real condition, in all four affected files (d07, d10,
d11, d18). Fixed by writing actual boolean conditions (`for lo < hi:`,
`for j >= 0 and xs[j] > key:`, etc.); three of the four now build and run
(d07, d10, d18 → GREEN). d11 still fails to build, but for an unrelated,
real reason — see below.

## Results

| file | task | status | detail |
|---|---|---|---|
| d01-sum-list | sum a list | CHECKS | builds+runs but `pending` stub only traps: `TUCK PENDING: sum invoked` then prints `0`. Needs real `sum` |
| d02-average | average of a list | CHECKS | same `sum` pending-stub trap, prints `0.0` |
| d03-min-max | min/max of a list | CHECKS | `min`/`max` pending stubs trap, print `0` `0` |
| d04-count-matching | count matching a predicate | PARSE-ADJACENT | `tuck check` OK, but `tuck build` fails: Nim error `proc count[T](payload: T): int` / "extra argument given" — pending stub codegen breaks once the struct has 2 fields (`items`+`pred`) |
| d05-filter | filter a list | CHECKS | same 2-field pending-stub codegen bug as d04, on `filter({items, pred})` |
| d06-map-transform | map/transform a list | PARSE then CHECKS | first draft used field name `fn:` — parse error `Expected parameter name` (`fn` is reserved). Renamed field to `transform`; then hit the same 2-field pending-stub codegen bug as d04/d05 |
| d07-reverse | reverse a list in place | **GREEN** | builds and runs, prints `5 4 3 2 1`. (Originally miscoded as `for cond:`; fixed to `for lo < hi:`.) |
| d08-contains-index-of | contains / index-of | PARSE-ADJACENT | same 2-field pending-stub codegen bug (`contains`/`indexOf` each take 2 fields) |
| d09-bubble-sort | bubble sort in place | GREEN | builds and runs, prints `1 2 3 5 8 9` |
| d10-insertion-sort | insertion sort in place | **GREEN** | builds and runs, prints `1 2 3 5 8 9`. (Originally miscoded as `for cond:`; fixed to `for j >= 0 and xs[j] > key:`.) |
| d11-binary-search | binary search | CHECKS | `tuck check` OK; `tuck build` fails — real bug, unrelated to `for`: `let mid = (lo + hi) / 2` then `xs[mid]` fails because Tuck's `/` lowers straight to Nim's `/` (float division), so `mid` infers as `float` and `seq.at(xs, mid)` rejects it. Minimal 9-line repro confirmed with plain `let`s, no loop at all |
| d12-remove-duplicates | remove duplicates | CHECKS | builds+runs, `dedup` pending stub traps (1-field payload — no codegen bug here) |
| d13-flatten-nested | flatten 2D list | GREEN | builds and runs, prints 1..9 |
| d14-zip-two-lists | zip two lists (paired sum) | GREEN | builds and runs, prints `11 22 33 44` |
| d15-dot-product | dot product | GREEN | builds and runs, prints `32` |
| d16-matrix-sum | sum a 2D matrix | GREEN | builds and runs, prints `45` |
| d17-identity-matrix | build 3x3 identity matrix | CHECKS | `tuck check` OK; `tuck build` fails: nested indexed write `m[i][i] = 1` — Nim sees `at(m,i)` as immutable, so `setAt` on the inner seq can't take a `var`. Nested-array indexed *write* is broken even though nested *read* (d13/d16) works. Re-confirmed with a 7-line minimal repro |
| d18-sieve-of-eratosthenes | sieve up to 30 | **GREEN** | builds and runs, prints `2 3 5 7 11 13 17 19 23 29`. (Originally miscoded as `for cond:`; fixed to `for j < 31:`.) |
| d19-running-totals | prefix sums | GREEN | builds and runs, prints `3 4 8 9 14 23` |
| d20-greatest-element | greatest element + push | PARSE-ADJACENT | `max` (1-field) pending stub would build; `push({items, value})` is 2-field and hits the same pending-stub codegen bug |

Status counts: **GREEN 9**, **CHECKS 7**, **PARSE-ADJACENT (checks OK, build
fails on Nim codegen for the pending-fn stub itself) 4**, **PARSE 0**
(no example was rejected by the Tuck parser after fixes).

## Compiler/parser findings along the way (not examples, but hit while writing them)

- **List literals cannot span multiple lines.** Re-confirmed with a 6-line
  minimal repro (`let xs = [1, 2,\n  3, 4]`): `Expected expression but got:
  tkNewline` at the line break inside the brackets. Not documented as a gap
  in SYNTAX.md/DISCOVERIES.md.
- **`fn` is not usable as a struct field name**, even though it's a
  plausible name for "the function to apply" in a `map`-style payload
  (`{items, fn: :double}`). Parser error: `Expected parameter name`. Worth
  either reserving it deliberately (fine) or documenting it as reserved.
- **Integer `/` silently becomes float division when the result feeds a
  `seq[i]` index**, because Tuck's `/` lowers straight to Nim's `/`
  (Nim's integer-dividing operator is `div`, not `/`). Plain `let c = a / b`
  at top level with no downstream use builds fine (Nim infers `int` there),
  but `xs[(lo + hi) / 2]` fails: `mid` gets inferred as `float`, and
  `seq.at` rejects it. This is the one real "arithmetic → array index"
  gap in the batch, confirmed with a 9-line minimal repro (d11 is the only
  example that hit it — binary search is the classic case that needs
  `mid = (lo+hi)/2` as an index).
- **`pending:` stub codegen breaks once the payload struct has 2+ fields.**
  Team lead pinned the exact mechanism: the stub emits a single generic
  payload parameter (`proc countOf*[T](payload: T): int`) while the call
  site emits the fields spread positionally (`countOf(xs, 1)`) — a
  stub-emission vs. call-emission disagreement, not an arity ceiling per
  se. A 1-field pending fn (`sum({items})`, `min({items})`, `dedup({items})`)
  happens to have both sides agree and so builds and runs (trapping at the
  call with `TUCK PENDING: ... invoked`). A 2-field pending fn
  (`count({items, pred})`, `filter({items, pred})`, `contains({items,
  value})`, `push({items, value})`) fails Nim compilation with "extra
  argument given". Matters a lot for this exercise specifically: most
  useful collection fns naturally take 2+ fields (items +
  predicate/value/transform), so most `pending:` declarations in this
  batch could only be check-verified, not build-verified.
- **Nested-array indexed *write* is broken; nested-array indexed *read* is
  fine.** `m[i][i] = 1` (d17) fails to build because the lowering treats the
  intermediate `at(m, i)` as immutable when trying to `setAt` into it.
  Reading through two levels of nesting (`for row in m: for n in row:`,
  used successfully in d13/d16) works. Re-confirmed with a 7-line minimal
  repro.

## Proposed stdlib API

Stands as originally submitted — unaffected by the `for cond:` correction.
Ranked by how many of the 20 examples wanted it. All would live in a new
`std/seq.tuck`-adjacent module (call it `std/collections` or extend
`std/seq`) except where noted.

1. **`fn sum({items: Seq[int]}) -> int`** — wanted by d01, d02 (2 examples,
   and implicitly by any aggregate task). The single most obviously-missing
   fn: nobody writing "sum a list" naturally reaches for a hand-rolled
   accumulator loop first.
2. **`fn max({items: Seq[int]}) -> int`** and **`fn min({items: Seq[int]}) -> int`**
   — wanted by d03, and `max` again by d20. Reduce-style, same shape as
   `sum`. Should probably be generic (`Seq[T]` with `T: Ord`) rather than
   int-only, but int-only is the honest MVP given the language has no
   type-class/constraint syntax yet in what I've seen.
3. **`fn filter({items: Seq[T], pred: fn}) -> Seq[T]`** — wanted by d05.
   Needs first-class fn values as struct fields; SYNTAX.md's `:name` fn-ref
   syntax (`x bake {op: :plus}`) suggests the mechanism already exists for
   partial application, so plumbing it into `filter`/`count`/`map` should be
   small.
4. **`fn map({items: Seq[T], transform: fn}) -> Seq[U]`** — wanted by d06.
   Note: do NOT name the field `fn` — `fn` is a reserved word and the parser
   rejects it as a field name (see finding above). `transform` reads well
   postfix: `{items: xs, transform: :double} map`.
5. **`fn count({items: Seq[T], pred: fn}) -> int`** — wanted by d04. Could
   be defined in terms of `filter` + `.len` once both exist, but as a
   primitive it avoids allocating the intermediate seq.
6. **`fn contains({items: Seq[T], value: T}) -> bool`** and
   **`fn indexOf({items: Seq[T], value: T}) -> int`** (return `-1` on
   miss, matching the everyday convention already used by hand in d08) —
   wanted by d08.
7. **`fn dedup({items: Seq[T]}) -> Seq[T]`** — wanted by d12. Preserves
   first-seen order (the natural expectation); an unordered/set-based
   variant is a different, lower-priority fn.
8. **`fn push({items: Seq[T], value: T}) -> Seq[T]`** (or `append`) —
   wanted by d20, and flagged directly by DISCOVERIES.md/SYNTAX.md as *the*
   top stdlib gap independent of this batch: growable seqs don't exist at
   all today, so every example in this batch that would naturally build up
   a result of unknown length (filter, dedup, map onto a fresh seq) had to
   either pre-size a fixed buffer and track a separate count (d05, d12
   worked around it that way) or invent `push`/`filter`/`map` as opaque
   pending fns and let the runtime own the growth. This is not "one more
   fn to add" — it's the single biggest structural gap; every `Seq`-return
   pending fn above (`filter`, `map`, `dedup`) is really asking for this to
   exist underneath it.

Everything else in the batch (bubble sort, insertion sort, binary search,
zip, dot product, matrix sum, identity matrix, sieve, running totals,
reverse) was fully expressible with only `.len`, `xs[i]`/`xs[i] = v`,
and plain loops — no additional stdlib surface needed, once the codegen
bugs above (int-division-as-index, nested-write, pending-stub arity) are
fixed.
