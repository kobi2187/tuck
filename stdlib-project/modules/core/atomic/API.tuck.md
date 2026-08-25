# core.atomic — Tuck translation

## This module does not translate at the library level, and that is the finding.

`core.atomic` is *"counters, flags and pointers that several threads (or a
main loop and an interrupt handler) can touch at once without tearing…
the bottom of the concurrency stack — `sys.sync`'s locks and channels are
built out of these."*

Tuck's concurrency model has no layer for it to be the bottom of. From the
spec's own reasoning:

> **No `ref` in Tier 1**, so no two names ever denote one record. A data
> race needs two references to one mutable location; the sentence cannot be
> formed. That is why Tuck has no `Send`/`Sync`, no borrow checker, no
> lifetimes — not because those problems were solved, but because they were
> never expressible.
>
> **Messages are copied** into a fixed-size mailbox (§9.1), so nothing
> crosses an actor boundary by reference and "two actors sharing state" is
> likewise unsayable.

And the scheduler is *cooperative, single-threaded*: "no preemption, no OS
threads in the scheduler" (§10). An actor runs to its next `[io]` yield
point without interruption, so there is no window in which a counter can
tear.

So the shared mutable location that atomics exist to protect has no
vocabulary in Tuck. A `core.atomic` module would be primitives with nothing
to be primitive *to*.

## The two real use cases, and where each goes

- **Cross-task shared counters/flags** — an actor's own fields. `Counter
  send add {n}` then reading `Counter.total` is the whole pattern, and
  `examples/26-actor-run.tuck` run-verifies it (55 on both backends). The
  isolation is structural, not enforced by an atomic instruction.
- **Main loop ↔ interrupt handler** — this one is genuinely *not* covered
  and shouldn't be papered over. `platform.interrupt`'s ISRs are
  `{.raises: [].}` `{.nimcall.}` handlers that cannot capture, and the
  documented way state reaches them is "a `Queue`, a `Mutex[T]`, or a
  module-level `var`" (`INDEX.md`'s own note). A module-level `var` shared
  between an ISR and the main loop **is** the tearing case atomics exist
  for, and Tuck's Tier-1 argument doesn't reach it, because an interrupt is
  a preemption the cooperative scheduler doesn't control.

## The open question worth carrying forward
The embedded half of the atomics story is real and unaddressed: `platform`
tier code needs *some* answer for ISR↔main-loop shared state, and "no `ref`
in Tier 1" doesn't provide one, since the hardware preempts regardless of
what the language can express. That likely belongs to `platform.interrupt`
rather than a `core.atomic` module — flagged there rather than resolved
here.

## Recommendation
Drop `core.atomic` as a Tuck module; carry the ISR question to
`platform.interrupt`. Same treatment as `core.ptr`/`core.slice`: flagged,
not deleted, with the `API.nim.md` kept as the record.
