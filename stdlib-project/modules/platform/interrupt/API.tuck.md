# platform.interrupt — Tuck translation

## Shape decision
Mostly language-level; a thin `pending:` surface for the rest.

## What Tuck already provides

ISR constraints are enforced by the compiler rather than documented:

- **An ISR must be `{.raises: [].}`**, so *no raising verb is callable
  inside one at all* — the `try`-prefixed siblings become the only usable
  half of the library. `INDEX.md` called this "the strongest justification
  the `try` convention has earned anywhere in the project," and it holds:
  the compiler enforces what a comment would otherwise ask for.
- **Handlers are `{.nimcall.}`** — they cannot capture, so state reaches
  them only through a `pool` slot, an actor field, or a module-level `var`.
  Again enforced, not documented.

## The API

```tuck
pending:
  fn onInterrupt({vector: int, handler: str}) -> void
  fn enableIrq({vector: int}) -> void
  fn disableIrq({vector: int}) -> void
  fn inCritical() -> bool
  fn beginCritical() -> void
  fn endCritical() -> void
```

## The unresolved question this module inherits

`core.atomic` dissolved because Tuck's Tier-1 argument ("no two names
denote one record; a data race needs two references to one mutable
location") removes the shared-mutable-state vocabulary. **That argument
does not reach an interrupt**, because the hardware preempts regardless of
what the cooperative scheduler or the type system can express.

So the genuinely open case is: a module-level `var` written by an ISR and
read by the main loop. Tuck has no `atomic` type, no memory-ordering
vocabulary, and no way to say "this read must not tear." `beginCritical`/
`endCritical` (masking interrupts around the access) is the classical
answer and is what this module offers — but it is a discipline the compiler
does not check, which is unusual for Tuck.

**Worth a real decision**: either a checked mechanism (a type that may only
be touched inside a critical section), or an explicit statement that
ISR-shared state is the one place Tuck asks for discipline rather than
providing a guarantee.

## Notes
- `beginCritical`/`endCritical` as a pair rather than a scoped block,
  because there is no scope-exit hook to guarantee the `end` runs — the
  same gap `core.mem::Scrubbed` and `std.testing::cleanup` hit.
- `handler: str` is a placeholder for a `fnsig`-typed slot; the real
  spelling wants a non-capturing handler reference, which `:name` gives.
