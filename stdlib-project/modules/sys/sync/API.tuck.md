# sys.sync — Tuck translation

## This module does not translate, and that is the finding.

`sys.sync` is *"sharing state between threads without getting it wrong: a
lock that owns what it protects, channels for handing work along, and a
lock-free handoff for the one thread that must never, ever block."*

With no user-facing OS threads (`sys.thread`), there are no threads to
synchronise. Every primitive here answers a problem Tuck arranges not to
have:

| Nim design | why it's absent |
|---|---|
| `Guarded[T]` (a lock owning its value) | no two names denote one record; nothing to lock |
| `Channel[T]` (MPMC queue) | an `actor`'s mailbox *is* this — bounded, copying, with `send` |
| `Handoff[T]` (SPSC lock-free ring) | existed so an audio callback on a *real thread* never blocks; no such thread |
| `Barrier`/`Gate`/`Once` | rendezvous between threads that don't exist |

The cooperative scheduler makes the guarantee structurally: an actor or
task runs to its next `[io]` yield point without interruption, so there is
no window in which another context observes a half-written value.

## The mapping worth writing down

`sys.sync::Channel[T]` → **an actor with a `[queue: N]` mailbox.** The
correspondence is close and worth stating, because the Nim design's
reasoning transfers:

- **`capacity` has no default on purpose** (the Nim design's note: "an
  unbounded queue silently growing behind a slow consumer is a real
  outage") — Tuck agrees, and goes further: `[queue: N]` is *mandatory*
  and compile-time, so the ring buffer is sized exactly and a full mailbox
  is a known, fixed condition.
- **`send` blocks when full — that is backpressure** — the same argument
  `examples/25-pools.tuck` makes for `pool.acquire` returning `?T`
  ("exhaustion is backpressure, not an error").

## The one real gap this leaves

**What happens when an actor's mailbox is full is not documented anywhere**
— not in the spec, not in `LANGUAGE-OVERVIEW.md`, not in any example.
`send` is fire-and-forget with no return value, so a caller cannot learn
that its message was dropped, queued, or that it blocked. The Nim design
had three distinct answers for this shape (`send` blocks, `trySend`
returns false, `Handoff.trySend` never blocks *or* allocates); Tuck
currently has one verb and no stated policy.

That matters most for the modules already written on the actor shape —
`sys.window`'s input events, `std.queue`'s pushes, `sys.audio`'s control
messages. Worth a ruling; noted in `FRICTIONS.md` territory but it's a
design question rather than a compiler bug.

## Recommendation
Drop as a module. Fold the "bounded queue, exhaustion is backpressure"
reasoning into the actor documentation, and settle the full-mailbox policy.
