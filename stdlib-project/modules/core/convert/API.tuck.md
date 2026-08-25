# core.convert — Tuck translation

## Shape decision
Freeform `pending:` verbs. **Compiler-verified**, `./tuck ch`: `OK`, 7/7
`PENDING`.

## Most of this module is a language question, not a library one

The Nim design built three concepts (`ConvertsTo`, `MayConvertTo`,
`ViewableAs`) plus a generic `to(x, typedesc[U])` family, because Nim needs
a library to express "this type converts to that one."

Tuck answers most of it in the language:

- **A `distinct` conversion is a plain postfix call** — `value Milliseconds`
  (`std/time.tuck`). No `to(x, U)` machinery needed for the common case.
- **`~T` lossy conversion is the intended answer** for the narrowing half,
  and it is explicitly **"named as a future ruling only"**
  (`LANGUAGE-OVERVIEW.md` §17, `examples/40:12`). Per `examples/40`'s own
  comment, the overflow attributes are *what a lossy `~T` conversion
  consults to decide clamp vs wrap vs trap* — meaning `toNarrowClamped`
  below is a placeholder for something the language intends to own.
- **`view(x, U)` (the O(1) reinterpretation) is gone entirely**, with
  `View[T]` itself — see `core.slice`.

So this module shrinks to the conversions that are genuinely functions:
narrowing with an explicit failure mode, and text↔number parsing.

⚠️ **Written against the intended language, per direct guidance.** `~T`
isn't implemented, and `[wrapping]`/`[trapping]` are declaration-only with
no behavioural test — so when `~T` lands, `toNarrow`/`toNarrowClamped`
below should be re-examined and probably deleted in favour of it.

## The API

```tuck
pending:
  fn toNarrow({x: i64}) -> i32?
  fn toNarrowClamped({x: i64}) -> i32
  fn toApprox({x: float}) -> f32
  fn parseInt({t: str}) -> i64?
  fn parseFloat({t: str}) -> float?
  fn intToStr({x: i64}) -> str
  fn floatToStr({x: float}) -> str
```

## Notes
- **Names shortened per the Factor rule**: `tryToNarrower` → `toNarrow`
  (the `try` prefix is redundant once the return type is `?i32` — absence
  *is* the signal), `toNarrowerClamped` → `toNarrowClamped`,
  `toApproximate` → `toApprox`.
- **`toNarrow` returns `i32?` rather than raising**, because a pure fn
  cannot return `!T` at all (fallible requires `[io]`). Same resolution as
  everywhere else in `core`.
- **`intToStr`/`floatToStr` overlap `std/str.tuck`'s real `toStr[T]`**,
  which already exists as a runtime extern. Flagged rather than resolved:
  either this module defers to it, or `toStr` is the one true spelling and
  these two are dropped. Worth deciding when `core.fmt`'s `show` and
  `std/str::toStr` are reconciled — three routes to "value as text" is two
  too many.
