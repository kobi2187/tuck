# The Tuck Vision — How People Write Code in Tuck

(User's development philosophy, recorded 2026-07-10. The tutorial teaches
THIS process; features exist to serve it.)

## The process

**Top-down design with TDD, enabled by `pending`.** Imagine the final app.
Declare the functionality it needs as typed holes in `pending:` blocks. The
skeleton compiles AND RUNS from day one — stubs log and return zero values,
the TODO report nags until every hole is filled.

**Compose functionality with `+` — the manager catalog.** Needed capability
lives in manager types (roles): a type carries data AND functionality, like
a small library. Pull managers in mixin-style and compose them:

```tuck
type PodcastPlayer = PlayerLifecycle + PlaybackControls + CacheManager
```

Over time this builds a catalog you simply pull from — or extend one manager
into a new type. Managers, not class hierarchies.

**Rapid dev without bugs.** Fast error-finding cycles; errors can be
deliberately deferred (error policy continue/exit + SHORTCUTS report) so the
walking skeleton keeps walking. Rapid never means sloppy: the compiler
bounds cyclomatic complexity, functions stay short, and the concatenative
style keeps code reading straight through. Simplification is a goal, not a
nicety.

**Declare correctness, don't code it.** Invariants (block form), decision
tables, sum-type transition graphs — high-level declarations the compiler
turns into low-level code via Nim. Memory stays controllable (arena, bump
allocator implementations planned).

**Actors for scale.** When a program grows, actors are the maintainability
model — isolated state machines are easy to visualize; coroutines ride along
for performance.

## Why

This pushes software toward the shape the author has found best in practice:
short pure functions, declared state machines, visible errors, composition
over inheritance, skeletons that run before they're finished.
