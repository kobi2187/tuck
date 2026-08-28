# Actor semantics — what actually works today, before writing the D backend

The user flagged that actors are **in progress and possibly incomplete even in
the Nim "authority"**, so this probes what genuinely runs rather than assuming
the reference is a correct target.

## What an actor IS here (not Erlang)

A **singleton service**, one per declared type. No construction, no reference,
no spawning. Registered automatically, runs as a daemon **alongside** `main`
for the whole program, exits only when the program does. It owns state and
drains a mailbox. `send` is fire-and-forget with no reply channel; a caller
that needs a value polls a **public field** via `scheduler::waitUntil`.

## Verified working (both backends, run not just compiled)

| Probe | Nim | Odin |
|---|---|---|
| 26-actor-run — 10 sends, queue 128, waitUntil on a predicate | **55** | **55** |
| probe3 — same shape, smaller numbers | 10 | — |

So the core path is real in both: send, drain, mutate state, predicate,
read the field back.

## Gaps found — both REPRODUCED, not inferred

**1. A full mailbox HANGS (probe1).** `[queue: 4]` with 10 sends plus a
`waitUntil` whose predicate needs all 10 spins forever (timeout 124). The
excess sends are dropped silently, so the predicate can never become true.
FRICTIONS.md #9 already recorded that the spec states no full-mailbox policy —
this is that gap, observed. Whatever D does here, it cannot be "match Nim",
because Nim deadlocks.

**2. Without `waitUntil`, no message is ever drained (probe2).** 10 sends,
queue 4, no wait -> `got=0`. `main` never yields, so the daemon never runs and
the program exits with the mailbox untouched. Sending without waiting is
therefore a no-op today, which is at least surprising and probably a bug: a
fire-and-forget send that never fires.

## What this means for the D backend

- **Target the VERIFIED path**, not the whole feature: singleton, drain loop,
  `send`, public-field reads, `waitUntil`. That is what 26-actor-run and
  27-actor-select exercise, and both reference backends agree on 55.
- **Do not port the deadlock.** If a full mailbox is reachable, dropping is the
  existing de-facto behaviour, but the hang comes from `waitUntil` believing a
  predicate that can never hold. Worth a diagnostic rather than a spin — but
  changing it is a LANGUAGE decision (spec §9.1 has to state the policy), not a
  backend one, so the D backend should match the drop and the gap stays
  recorded here.
- **The `send`-without-wait no-op is upstream too.** Same reasoning: record,
  do not paper over it in one backend.
