# Tour Gaps Report

*2026-07-13. Method: every TOUR.md section was first written the way the
code SHOULD read, then run. Anything that forced a workaround — however
small — is listed here. Bar set by the user: "if we have to jump through
hoops even a tiny bit, it's an area for improvement."*

Ordered by how hard they blocked natural expression.

## 1. ~~Cannot print a number~~ FIXED 2026-07-13 — generic `toStr`

`std/str` ships `fn toStr[T]({value: T}) -> str` (one generic extern over
the runtime): `{text: n.toStr} io::printLine` prints 42. Interpolation
remains future sugar.

### (original finding)

```tuck
let n = 42
{text: n} io::printLine   # Type Error: expects str but got int
```

The very first thing a tutorial does (print a computed value) is not
expressible. Needs at least a `toStr` for primitives (stdlib-blocks §18
already lists radix format as extern `strutils`), ideally interpolation.
**This blocked the hello-world of arithmetic.** Runtime verification in
this project uses *exit codes* because of this gap — that's telling.

## 2. ~~String concatenation emits invalid code~~ FIXED 2026-07-13 — `+` is concat

`"hello, " + name` works: codegen routes str `+` through the rt layer
(`tuckConcat` / Beef `concat`) — one abstraction over the backend, not a
hardcoded operator.

### (original finding)

```tuck
let greeting = "hello, " + name   # checker: OK; emitted Nim: `+` on strings — invalid
```

Checker accepts `str + str` (same-type arithmetic), codegen emits Nim
`+`; Nim wants `&`. Checker-level question too: is `+` the Tuck operator
for concat (then codegen must map it), or is concat a fn? Either way,
today it silently produces broken output — worse than an error.

## 3. ~~List literals of constructions emit garbage~~ FIXED 2026-07-13

Root cause: the Nim backend simply had NO `exkList` arm (and, found while
fixing, NO `exkFor` arm either — for-loops had never been emitted). Both
added; a list of constructions now sums through a for-loop,
runtime-verified. The collection API (add/len/...) is deliberately still
out — it will be designed as Rust-level traits/interfaces in the stdlib
session.

### (original finding)

```tuck
var eps = [{title: "A"} Episode, {title: "B"} Episode]
# emitted: var eps = discard        ← emitter bug, nim-check fails
```

`Seq[T]` params and `for` loops work, but *building* the seq doesn't.
Companion gap: **no collection API at all** — `eps add {…}` gradual-passes
the checker (unknown callee) and emits nonsense. Growable collections are
a stdlib-blocks item, but the list-literal emission is a plain bug.

## 4. Transitioning a state machine is a hoop

```tuck
{s: p, target: Playing} transitionTo   # checks…
# …but emitted transitionTo wants the FULL target value (payload included)
```

The natural call names the target *variant*; the emitted
`transitionTo(self, target: Player)` wants a constructed target with
payload, so the caller must build `{config, position: 0} Player.Playing`
first — duplicating payload knowledge at every call site. Wants a ruling:
`transitionTo` keyed by kind + payload args, or a per-edge generated fn
(`p toPlaying {position: 0}`).

## 5. ~~Can't react to WHICH error occurred~~ FIXED 2026-07-13

`match r.err` is now fully typed: arms validate against the producer's
declared `[error: ...]` enums (typos and cross-enum ambiguity caught),
and compile to hashed id constants. Error ids are namespaced —
`"module/Enum.Variant"` is the hash input — with a program-wide
compile-time collision check, and debug builds embed a reverse table so
the unhandled report prints the NAME, not a hex code.

## 6. ~~`const` can't hold unit values~~ FIXED 2026-07-13

`const` now has Nim-static semantics: arbitrary pure computation
evaluated at compile time (explicit `static:` block in the emitted
code). `const timeout = 5.ms` and computed constants work; `[io]`
calls and record constructions are rejected at the Tuck level.

## 7. Two arrow styles: match uses `:`, decision tables use `->`

```tuck
match p:
  Stopped: 0        # colon
decision route(...):
  | high true -> 1  # arrow
```

Both are "pattern to outcome" and they read differently. Small, but it's
exactly the kind of inconsistency the philosophy ("one answer per
concern") says shouldn't exist. Pick one.

## 8. Match arms found by trial — no diagnostics pointer

First attempt used `Stopped -> 0` (decision-table style); the parse error
was a bare `[Parse Error] at line 7, column 13` with no hint. Given gap 7
exists, the parser should say "match arms are `pattern: value`".

## 9. Actors declare but don't run

The API (envelopes, typed send helpers) emits, but with the
runtime/scheduler ruling open there is no way to *run* an actor program.
The tour's actor section ends mid-sentence by necessity. Highest-value
missing feature for the "actors for scale" story in VISION.md.

## 10. Minor frictions noticed in passing

- **Postfix binds tighter than operators**: `x + y sys::exit` parses as
  `x + (y sys::exit)`. Correct per grammar, surprising to write; needed a
  `let z = x + y` line. A precedence note in errors would help.
- **`match r.err:` needs a catch-all?** Exhaustiveness over error enums
  is unchecked (match exhaustiveness is a known ROADMAP gap) — combined
  with gap 5, error handling is the least-finished corner of an otherwise
  strong error model.
- **Numbers in exit-code verification only**: every runtime proof in the
  test suite funnels through `sys::exit` because of gap 1.
- **`fn` slots (`op: fn`) have no signature** — any call shape gets
  through the checker and fails (if at all) in Nim. Fine for v1 gradual,
  but a `fn({a: int}) -> int` type syntax would restore the "user never
  reads a Nim diagnostic" promise for bake-heavy code.

## What did NOT produce gaps

Worth recording what expressed cleanly on the first try: records +
subset matching, `..` chains and mutators, invariants (all sites),
`pending` skeletons, bake/invoke, alias/merge/input, const (plain data),
distinct units, decision tables, sealed types + `[unsafe]`, composition
(`+` mixins/records, interfaces), the error happy-path with `.ok`
narrowing, imports + stdlib io/fs, and the library-vs-binary build
split. The core flow model held up with zero hoops.
