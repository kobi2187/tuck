# DISCOVERIES — append-only

Spike 2026-07-25. Probed the REAL compiler with `tuck build` + run, not just
`tuck check`. Rule learned the hard way: **`tuck check` OK does not mean it
builds.** Everything marked (ran) was executed.

## Call style
- Module calls do NOT need `mod::` when imported and unambiguous. Natural Tuck
  is `{text: "hi"} printLine`, `{value: n} toStr`. `::` is for collisions only.
  The `import` line is still required.

## Verified working (ran)
- `for i in 1 ..< 11:` / `for i in 0 .. 10:` ranges, `var` accumulate — printed 55.
- List literals `[3,1,4]`, `for n in nums:` value iteration.
- `.len` on Seq AND on str — `"hello".len` printed 5.
- `xs[i]` indexed read and `xs[i] = v` indexed write (fixed-size, on a `var`).
- Full in-place **bubble sort** with nested loops + swap via a `let tmp` — ran,
  printed 1358. The imperative core is genuinely expressible.
- `seq::at` / `seq::setAt` explicit forms.
- String concat `s + "a"` on a `var` — printed "abcd".
- `/` and `%` on ints; `break` / `continue` / `loop:` / while-form `for cond:`.

## Verified broken / absent
- **Growable sequences do not exist.** `acc = acc + [7]` CHECKS but fails to
  build (emits invalid Nim: `proc \`+\`(x: int8): int8`). No `seq::push`.
  Author examples against FIXED-SIZE arrays. Top stdlib gap.
- **Bracket sugar needs `import seq` or you get a raw Nim error.** `xs[i]`
  lowers to `seq::at`, so a file using brackets WITHOUT `import seq` fails at
  the Nim stage with a `setAt` spelling suggestion, not a Tuck diagnostic.
  Diagnostic bug worth filing; not a language limit.
- No string indexing / no char type: `seq::at` on a `str` is a type error.
  Blocks reverse-a-string, palindrome-by-char, Caesar cipher, anagrams.
- No `seq::len` module fn (`.len` is the way). No string split/slice, no
  int-parsing from str.
- `let x = if c: a else: b` — parse error. `if` has no expression form (bug #3).

## Checker hole (found via batch A, 2026-07-25) — HIGHEST VALUE SO FAR
- **`tuck check` accepts ANY undeclared identifier.** Both
  `let x = totallyUndeclared + 1` and `for undeclaredThing:` pass `check`
  clean, then fail at the Nim stage with a raw Nim error.
  Cause: the gradual-typing sentinel (`UnknownName` in ast.nim — "undeclared
  symbols synthesize this named type"). It is swallowing genuine typos.
  Effect: typos and misremembered names get NO Tuck diagnostic, which breaks
  the compiler's stated no-Nim-diagnostic promise.
- Corollary: `for cond:` is NOT a broken construct (batch A misdiagnosed it).
  `for b != 0:` builds and runs fine. The agent wrote the metavariable `cond`
  literally; Tuck read it as a variable, and the checker hole let it through.
  Doc lesson: never put bare metasyntax in an example block.

## VERIFIED codegen/checker bugs (minimal repros, 2026-07-25)
Each of these was reduced to a <15-line file and reproduced. Sum types have NO
working path today — this cluster is the highest-value fix list.

1. **match on a payload sum type emits `case s` instead of `case s.kind`.**
   The TYPE is emitted correctly (`case kind*: ShapeKind`), but the match
   scrutinizes the object itself. Nim: "selector must be of an ordinal type".
   One-token codegen defect; blocks the headline feature.
2. **Payload-less variant construction emits `Color.Red()`.** Nim: "identifier
   expected, but found 'Color.Red'". Enum-like sums codegen to a bare Nim enum,
   but construction lowers to a call. (`decision` tables over the same enum DO
   work — they ord-pack.)
3. **`_` catch-all in match mis-lowers to Nim's `_` discard**, not `else`.
   Nim: "the special identifier '_' is ignored in declarations".
4. **match on `bool` fails exhaustiveness even with both arms.** Tuck error:
   "missing true, false" when `true:` and `false:` are BOTH present. Checker
   doesn't special-case bool literals. (This one is a Tuck-level diagnostic,
   i.e. the checker contradicting itself.)
5. **`tuck check` accepts ANY undeclared identifier** (see section above).
6. A local named `addr` collides with a Nim keyword → raw Nim parse error
   instead of a Tuck diagnostic. Same diagnostic-leakage class as `xs[i]`
   needing `import seq`.

7. **`pending:` stub arity mismatch (VERIFIED, minimal repro).** A stub whose
   payload has 2+ fields fails to build. The stub emits a SINGLE generic
   payload param — `proc countOf*[T](payload: T): int` — while the call site
   emits the fields spread positionally — `countOf(xs, 1)`. Nim: "type
   mismatch". A 1-field payload works (both sides agree by accident).
   Impact: the "invent a fn, keep compiling" workflow — which this whole
   effort depends on — only survives `check`, not `build`, for any realistic
   multi-field signature. Most natural collection/text fns take items+arg.
8. **std/io and std/fs emit bare unqualified Nim calls that collide with
   Nim's own syncio procs** (`readLine`, `readFile`, `writeFile`) →
   "ambiguous identifier". Needs qualified emission.
9. **`expr?` propagation does not exist in the parser.** `tkQuestion` appears
   only in parser_type.nim for `?T`/`!T` TYPE syntax, never in parser_expr.
   SYNTAX.md documented it — MY error, now corrected. There is currently no
   verified `!T` → `T` unwrap idiom at all, which undermines every fallible
   fn (parseInt/readFile/readLine) even after they're implemented.
10. Multi-line list literals are rejected (`Expected expression but got
    tkNewline` at the break). `fn` cannot be used as a struct field name.
    Nested indexed WRITE `m[i][i] = 1` fails (inner `at()` treated immutable)
    though nested READ works.

11. **SILENT: Nim builtins shadow Tuck fns with no diagnostic.** A `pending:`
    stub named `min` (or `max`, or any name in Nim's `system`) is silently
    intercepted by Nim's own 2-arg overload. Verified: the program BUILDS,
    RUNS, prints a plausible answer (`3`), and the `TUCK PENDING: min invoked`
    stderr line NEVER fires — the declared Tuck stub is dead code with zero
    warning. A real implementation with different semantics than Nim's would
    silently diverge from spec. **This is the worst bug in the list because it
    is invisible**; every other bug at least fails loudly. Fix direction:
    emit Tuck fns into a namespace, or mangle names, so user code can never be
    captured by `system`.
12. **No integer division. `/` always emits Nim's float `/`.** Verified:
    `let q = 7 / 2` builds and prints **3.5**. Two ints in, float out, no
    diagnostic. Reassigning into an int var (`n = n / 10`) is a hard Nim type
    error. There is currently no way to write integer division at all — this
    blocks digit-extraction, midpoints, averages, binary search, base
    conversion. Needs a `div` lowering for int operands.
13. **`unwrapOr` emits a curried call** — `unwrapOr(maybeName)("unknown")`
    instead of `unwrapOr(maybeName, "unknown")` (found by batch C via c09).
    Related to the multi-field call-emission family (#7) but a distinct shape.

14. **Nested indexed WRITE fails; nested READ works.** `m[0][0] = 1` on
    `var m = [[0,0],[0,0]]` → "expression 'at(m, 0)' is immutable, not 'var'".
    The inner `at()` returns a value, so the outer setAt has nothing mutable
    to write into. Blocks ALL 2D/grid work (matrices, game boards, dynamic
    programming tables). Verified minimal repro.
15. **Multi-line list literals are a parse error.** `[1, 2,\n  3, 4]` →
    "[Parse Error] ... Expected expression but got: tkNewline". Any matrix or
    data table must be written on one line. Verified minimal repro.
16. **FOOTGUN: pending stubs return zero/false deterministically, so
    "loop until condition" over a stub never terminates.** Batch B wrote
    `loop:` + `if {} randomBool: break`, which spun forever and had to be
    killed after >5GB of stderr. The stub warning printing on EVERY call makes
    the runaway expensive. Suggests pending stubs should either rate-limit the
    warning or the docs should warn against looping on a stub predicate.

## RULING (user, 2026-07-25) — mangle emitted fn names
**Tuck must never stumble upon Nim procs.** The emitter shall mangle or prefix
emitted Tuck fn names (e.g. `nim_`-style prefix or a module-qualified mangle)
so user and stdlib fns can never be captured by Nim's `system` or any other
imported Nim module. This kills the entire bug class rather than blacklisting
names, and it frees the stdlib to use the RIGHT names (min/max/abs/count/sum/
join/split — exactly the .NET-shaped names) without collision anxiety.

Ordering constraint (see the interaction note below): this should land BEFORE
or WITH the arity fix (#7), because fixing arity first would widen the set of
calls that Nim can capture.

## SHADOWING SWEEP (2026-07-25) — refines bug #11, and it interacts with #7
Swept the corpus's 60+ invented fn names against Nim's `system`. Result: the
name alone is NOT the trigger. **Shadowing happens only when the positionally-
spread payload matches a Nim overload in BOTH arity and types.**

- 1-field payload `{value: int}`: 14 of 15 tested names run their stub fine
  (min, max, contains, find, count, sum, add, join, split, repeat, reverse,
  items, pairs, len). Only **`abs`** is shadowed — Nim's 1-arg `system.abs`.
- 2-field payload `{a: int, b: int}`: **`min` and `max` are SHADOWED** — build,
  run, print a plausible answer, stub never fires. `contains`/`find`/`add`
  instead FAIL THE BUILD on the arity bug (#7).

**The two bugs interact badly.** Bug #7 is normally a loud build failure, which
is what protects most colliding names. A Nim overload that matches the spread
call absorbs the broken call and makes #7 silent. So #7 fixes #11 by accident
today — and **fixing #7 will EXPAND #11's blast radius**, because every call
will then spread positionally and become capturable.
=> Namespaced/mangled emission should land BEFORE or WITH the arity fix.

Confirmed shadowed (build, run, plausible output, stub NEVER fires):
`abs` (1 field), `min`/`max` (2 int fields), `clamp` (3 int fields — Nim's
`system.clamp`, found by batch B and verified: printed 10, no PENDING line).
Confirmed NOT shadowed (stub fires correctly): `sign`, `parseInt`,
`randomBool`, plus the 14 one-field names swept above.

Corpus impact: only files declaring `abs`, `min`, `max`, or `clamp` have
untrustworthy GREEN status — batch A's a16, batch B's b21/b25, batch D's
d03/d20. All to be retested once the mangling ruling lands. Everything else
in the sweep is genuinely GREEN.

17. **Every keyword is unusable as a struct field name.** Verified: `task:`
    and `select:` in a type body are a parse error; batch D hit the same with
    `fn:`. The lexer's keyword table has ~40 entries (type, object, on, match,
    in, when, pool, arena, register, task, select, decision, loop, ...) and
    ALL of them are blocked. For a language whose entire calling convention is
    struct payloads with named fields, this is a live ergonomic tax — `task`,
    `type`, `object`, `count` are ordinary data-modelling field names.
    Fix direction: contextual keywords — an identifier directly after `{` or
    `.` is a field name, not a keyword. Parser change, not a redesign.
18. **`Map[K, V]` is not a type.** `{} Map[str, int]` → "indexing takes
    exactly one index, got 2". No dictionary type exists at all; the
    two-parameter bracket form is parsed as indexing. Blocks every
    application-shaped program (lookup tables, grouping, counting by key).
    Batch F promoted this to Tier 1 on qualitative grounds despite thin raw
    frequency — it is the FIRST wall an app-shaped program hits.

19. **Fallible fns MUST be `[io]`.** Verified: `fn parseInt({text: str}) -> !int`
    without `[io]` → "fallible functions must be marked [io]; pure functions
    are total". DESIGN CONSEQUENCE the user should rule on: this means no PURE
    fn can parse a string or divide safely — `parseInt`, `safeDiv` and every
    `!T`-returning stdlib fn is forced to carry `[io]` even with zero actual
    I/O. Defensible ("failure is an effect") but it diverges from Rust/Python,
    where parsing is pure-with-a-result. Was undocumented in SYNTAX.md; fixed.
20. **A bare `?T` cannot receive a postfix call.** `maybe.double` on a `?int`
    → "unhandled ?int — pass it to a handling function or propagate with '?'
    before accessing fields". Note the message advertises `'?'` propagation —
    **which the parser does not implement** (bug #9). The checker's own
    diagnostic points at a nonexistent feature.

## AUTHORING FINDINGS (not compiler bugs — parser diagnosed correctly)
- **Elixir-style `fn(args)` mid-pipeline is rejected**, with a genuinely good
  error: "Function calls are postfix in Tuck: write {payload} fnName". The
  correct mid-chain form for a step needing extra args is the METHOD form
  `.name {args}`:
      {text: raw} trim lower .split {sep: ", "} .join {sep: "-"} upper
  Evidence for the pipe-analogy's limit: Elixir's `|>` maps onto Tuck postfix
  only for SINGLE-PAYLOAD steps. The moment a step takes extra arguments the
  syntaxes diverge — exactly where a pipe-trained author trips.
- **`decision` tables need an all-`_` catch-all when ANY column is an open
  domain** (int/str). Closed domains (sum type, bool) are proven exhaustively;
  an `int` column cannot be, so the table needs a final catch-all row.

## FIXED
- **`elif` — FIXED 2026-07-26.** Was lexed (tkElif in the keyword table) but
  parseExpr's if-branch only looked for tkElse, so every multi-branch
  condition had to be hand-nested. Now parses as `else: (if C: B)` — pure
  sugar nested into elseBranch, so no AST, checker, or codegen change was
  needed. Chains of any length; trailing `else` optional. Corpus went
  176 -> 178 check-clean (b10, b16 recovered). Regression guard #10 in
  tests/known_bugs.nim.

## CONFIRMED WORKING (negative results — no stdlib fn needed)
- **Structural equality on records is already a language feature.** `a == b`
  on two `Point`s builds, runs, and compares by value. No `equals` fn should
  be added. (Verified minimal repro.)

## STANDING PROPOSAL — division (batch A, endorsed)
**Type-directed `/`:** `int / int -> int` (truncating); any float operand
-> float. No new operator, no explicit call.
Rejected alternatives: separate `/` vs `div` relocates the bug (the author
must remember to reach for `div`, and all 5 divisions in batch A were written
as plain `/` with obvious integer intent); explicit `{a,b} intDiv` turns the
most common numeric operator into a fn call, fighting Tuck's own
operator-vs-postfix-call split. `%` stays int-only with a check-time error on
float operands. Mixed `+ - *` follow the same type-directed rule so `/` isn't
a special case. STATUS: proposal, awaiting the user's ruling.

## NOT bugs — agent misdiagnoses, corrected here
- `for cond:` is fine. `for n > 0:` builds and runs. Two batches reported it
  broken; batch A had literally written the metavariable `cond` as an
  identifier, and batch B's own files used correct conditions while the report
  claimed otherwise. b13-countdown builds GREEN.
- b06-while-style fails on the KNOWN integer-division bug (`n / 2` → float),
  not on the loop form.
- LESSON: a finding is only real with a minimal repro. Pattern-matching an
  error message to a plausible cause produced 2 false headline bugs out of 3.

## Tooling
- CLI: `tuck build FILE.tuck --root:/home/kl/prog/tuck_lexer` — options come
  AFTER the file, and `--root:DIR` takes a colon, not a space.
