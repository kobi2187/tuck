# std.queue — Tuck translation

## Shape decision
`actor`, per direct guidance. Same multi-instance tension `std.db` has, for
the same reason — an app can legitimately want more than one durable queue
(mobile's outbox, plus a separate one for a different sync target) and
`actor DurableQueue` is one singleton for the whole program. Not re-derived
in full here; see `modules/std/db/API.tuck.md`'s writeup, which applies
verbatim.

**Compiler-verified**, `./tuck ch`: `OK`.

## The API

```tuck
actor DurableQueue [queue: 32]:
  isOpen: bool = false
  depth: int = 0

  on openQueue({path: str}) -> void:
    isOpen = true

  on close() -> void:
    isOpen = false

  on push({payload: str}) -> void:
    depth += 1

  on ack({id: i64}) -> void:
    return

  on compact() -> void:
    return

  on select:
    | shutdown -> {}: isOpen = false
```

## In use

```tuck
DurableQueue send openQueue {path: "outbox.log"}
DurableQueue send push {payload: "hello"}
```

## Open design questions
- The multi-instance mismatch — same as `std.db`'s, applies verbatim.
- **The general reply-pattern question is resolved, and this module is
  where it started** (`TUCK-TRANSLATION.md`): `push`/`ack` are already the
  small-message, caller-visible-field shape every other actor's reply now
  follows. Two small fixes worth making explicit, not new problems:
  `pending()`'s "read back everything unacknowledged" is a direct read of
  a public `Seq[Entry]` field (queue entries are naturally small already —
  unlike `std.db`'s rows, no cursor indirection is needed here); `push`'s
  assigned entry id should come from a caller-side `TokenIssuer`
  (`TUCK-TRANSLATION.md`) rather than the actor inventing one, matching
  `std.db`'s token exactly.
- `Entry[T]` is generic over the payload type in the Nim design
  (`DurableQueue[T]`). **Confirmed not expressible**: `actor Box[T] [queue: 4]:`
  is a parse error (`Expected 'Colon' here, found '['` — the `[queue: N]`
  slot is the only bracket an actor declaration accepts). A generic durable
  queue needs either one declared actor type per payload type used in a
  program, or a payload carried as an already-encoded byte buffer (matching
  `std.serde-derive`'s job at the boundary) rather than a Tuck generic —
  both are real design decisions, not attempted here.
