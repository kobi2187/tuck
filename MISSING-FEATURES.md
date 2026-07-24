# Missing Features & Gaps — snapshot 2026-07-24

A "for later" list, compiled after the async/actor/extern work. Three parts:
broken/incomplete examples, open known-bugs, and the TOUR-GAPS re-audit.

## A. Examples not fully green

Gate = `nim check` on emitted Nim (tests/compile_all_examples nimCheckExpected).
Async examples build+run via cli_smoke instead (they need arsenal on the path,
which bare `nim check` doesn't pass).

| Example | State | Missing feature |
|---|---|---|
| **16-actor-tasks-unified-syntax** | BROKEN (skip) | `.fn {args}` on an undeclared method (`copyFrom`) → checker error; AND dotted select sources (`resp.ok`, `timeout.5s`) parse as opaque strings, not typed readiness/duration. Needs: method-on-undeclared ruling + typed select sources + `5s` duration lexing. |
| **20-embedded-mp3-player** | BROKEN | (1) MMIO register-field access `DAC_CR.EN` → "undeclared field: 'EN'" — register DSL depth (nested bitfield write) unimplemented. (2) `transitionTo`-with-payload INSIDE AN ACTOR HANDLER emits garbage — a handler-context codegen bug (the transition DESIGN is resolved; see D#4). |
| **08-actors_isolated_state** | OK (library) | Decl-only actor (no main) — builds, not runtime-testable. Could add a driver + gate, or leave as a pure-decl showcase. |
| **28-async-task** | GREEN (cli_smoke, exit 42) | Not in nimCheck gate (needs arsenal path). Runtime-verified only. |
| **29-task-timeout** | GREEN (cli_smoke, exit 2) | Same — runtime-verified; uses a placeholder idle source (see C below). |

(`http` in the list is a std/-style module, not an example.)

## B. Open known-bugs (tests/known_bugs.nim, 5 open)

1. **`/=` on ints emits float `/`** — integer compound-divide picks Nim's
   float-returning `/`.
2. **`toStr` result loses str-ness under `+`** — `n.toStr + "x"` picks the
   numeric `+`, not concat.
3. **`if` has no expression form** — `let x = if c: a else: b` unsupported.
4. **Beef backend doesn't clamp `[saturating]`** — Nim clamps; Beef emits a
   bare ctor (parity gap).
5. **type argument named like an attribute** — `Box[error]` fails: `error` is
   in the attribute word list, so the parser reads `[error: ...]`. Same for
   stack/queue/align/priority/volatile + ~14 others. (The valued half
   `[name: value]` is fixed; bare markers still use the word list.)

(`.fn {args}` undeclared, #8, was CLOSED this stretch — now a checker error.)

## C. Async/actor layer — real gaps (from this session's work)

- **No real async std I/O externs.** std fs/io/sys are BLOCKING externs over
  Nim's sync stdlib. There is no socket recv / async readFile that yields
  through the reactor. The operation-timeout MECHANISM is real+proven, but
  example 29 races an idle placeholder pipe (`openSource`) because there's
  nothing real to race yet. NEXT: a real async source (async TCP recv) so a
  task does genuine non-blocking I/O with a real timeout.
- **Typed select sources.** `on select` arms only lower `read <fd>` /
  `timeout <ms>` (bare + int). `resp.ok` (future readiness) and `timeout.5s`
  (duration) parse as opaque strings — need typed SelectSource variants + `5s`
  duration lexing. Blocks example 16's task select.
- **Beef async/actor runtime** = declared ceiling (comment-only emission).
  minicoro-beef exists; the same reactor design would need porting.

## D. TOUR-GAPS re-audit (which still hold)

Fixed since the 2026-07-13 tour: #1 toStr, #2 str concat, #3 list literals,
#5 error match, #6 const-units. Still open:

- **#4 transitionTo** — **RESOLVED.** The design ruling: the caller constructs
  the FULL target variant (payload and all); emitted `transitionTo(self,
  target: <SumType>)` validates the kind-edge against the table and assigns
  `self = target`. Example 12 is gated/green on this. NOT a hoop — it's the
  chosen model. The only remaining piece is a NARROWER codegen bug: example
  20's `transitionTo`-with-payload INSIDE AN ACTOR HANDLER emits garbage
  (`PlayerState.Decoding(transitionTo(self.state))(rate)`) — a handler-context
  emission defect, not the transition design.
- **#7 two arrow styles** — **CLOSED (ruling: keep both).** `match p:` uses
  `:`, `decision` uses `->` — intentional, both stay. Not a gap.
- **#8 match parse error has no hint** — STILL OPEN. `Stopped -> 0` (wrong
  style) gives a bare `[Parse Error]` with no "match arms are `pattern: value`".
  Small: a targeted parser diagnostic.
- **#9 actors declare but don't run** — **FIXED this session.** Actors run on
  the unified arsenal runtime (examples 26/27, exit 55). The highest-value gap
  is closed.
- **#10 minor frictions:**
  - postfix binds tighter than operators (`x + y sys::exit`) — STILL OPEN, no
    precedence hint in errors.
  - `match r.err:` exhaustiveness unchecked — STILL OPEN, RULING MADE: do FULL
    exhaustiveness checks, Nim-style — every match over an enum/sum must cover
    all variants OR have a catch-all, else a compile error. General feature
    (all matches, not just error enums).
  - "numbers only in exit-code verification" — STALE now: toStr works (gap #1
    fixed), so runtime proofs need not funnel through sys::exit. Tests still
    do, but it's no longer forced.
  - `fn` slots have no signature type — STILL OPEN, RULING + SYNTAX MADE.
    Add NAMED function signatures (a named delegate) using Tuck's struct syntax:
      `fnsig Adder = {a: int, b: int} -> {sum: int}`
      `fnsig Predicate = {} -> bool`
      `fnsig Reader = {path: str} -> !{content: str}`
    Form: `fnsig NAME = {params} -> <ret>` — named-struct params (reads exactly
    like a fn minus name/body); `fnsig` keyword is grep-able/self-documenting.
    RETURN side accepts ANYTHING a fn returns: `{struct}`, a bare type
    (int/bool), void, and !T/?T wrappers — full parity with fn return types.
    Then use NAME as a type: bake slots, callback fields, `:name` fn-ref args.
    The checker validates call shape (arity/param-types/ret) against the named
    sig → restores the no-Nim-diagnostic promise; subsumes the current `fn`
    slot (which maps to an uncallable pointer today).
    Build pieces: parser `fnsig NAME = {params} -> ret` decl; AST a function-
    type node (params + ret) + named binding; checker resolves NAME to that
    type and checks calls; codegen emits Nim `proc(a: int, b: int): tuple[...]`.

## E. Standing ROADMAP items (not tour/example specific)

- Resource registry §7.4 (parser/checker/rt/codegen) — not started.
- `when TARGET` §8.3 conditionals — blocks 11/20's target-specific code.
- match exhaustiveness checking (RULED: full Nim-style — cover all variants or
  catch-all, else compile error) — general gap, feeds #10b.
- named function signatures `fnsig NAME = {params} -> ret` (RULED + syntax,
  feeds #10c) — a named delegate type (struct-syntax params, full fn-return
  parity) for fn slots/callbacks; checker validates call shape.
- Visibility (pub/private), nested module paths.
- `pred`/`set` fn prefixes §3.6; stack-depth budgets `[stack: N]` §6.2;
  complexity limit §6.3 (ruling: hard error) — declared, unbuilt.
- Spec §11 debt: describes npeg+flat-IR; reality is recursive-descent+ref-AST
  + id-keyed Resolution — rewrite §11 to match.
