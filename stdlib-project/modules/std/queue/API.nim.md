# std.queue — Nim API

## Purpose
A queue that survives the process being killed mid-write: push an item,
it's on disk before `push` returns, and a restart replays whatever wasn't
yet marked done. The mobile background-sync shape — "queue writes durably,
flush and reconcile once connectivity returns" — generalized to any
domain that needs the same guarantee (a desktop sync client, a web
backend's outbox pattern for a flaky downstream).

*New in this pass.* `DOMAINS.md`'s synthesis (Finding C) named this as the
sharpest *runtime*-offline finding in the whole document, and judged it a
composition of two existing modules (`alloc.deque` for the in-memory shape,
`sys.fs` for durability) rather than a new primitive. Writing the actual
composition surfaced real design questions a one-line "compose them"
recommendation didn't answer — crash-safe framing, replay ordering, and
at-least-once-not-more-than-once accounting — which is why this became a
real module rather than only an "In use" example.

## Protocols implemented
`DurableQueue[T]` is `Adjustable`-shaped for its depth and otherwise domain
verbs — `push`/`pop`/`ack` have no structural analogue among the nine
protocols. It is deliberately not `Collection`: walking a durable queue
without consuming it invites exactly the "did I already send this" bug the
whole module exists to prevent.

## The API

```nim
type
  DurableQueue*[T] = object
    ## Backed by one append-only file (the log) plus one small pointer file
    ## (the last acknowledged offset) — the same two-file shape `sys.fs`'s
    ## own `kv-store-server` WAL example already uses, generalized to any
    ## `T` that `std.serde-derive` can encode.
  Entry*[T] = object
    id*: int64          ## monotonic, assigned at push — the replay/ack key
    value*: T

proc openQueue*[T](path: Path): DurableQueue[T]
  ## Creates the log if absent; if present, does **not** replay automatically
  ## — `pending()` hands back what's unacknowledged and the caller decides
  ## when to process it, the same "the caller drives, the module doesn't
  ## guess" restraint `sys.fs::Watcher` already applies to its own events.
proc close*[T](q: var DurableQueue[T])

proc push*[T](q: var DurableQueue[T]; value: T): int64 {.discardable.}
  ## Appends and `persist(metadata = false)`s before returning — the push
  ## is durable the instant this call returns, matching `sys.fs`'s own
  ## fdatasync-for-per-record-durability precedent from the WAL example.
proc pending*[T](q: DurableQueue[T]): seq[Entry[T]]
  ## Everything pushed but not yet `ack`ed, oldest first — what a restart
  ## replays, and what an online-again handler processes.
proc ack*[T](q: var DurableQueue[T]; id: int64)
  ## Marks one entry done. Idempotent — acking an already-acked or unknown
  ## id is a no-op, not a raise, because a crash between "processed it" and
  ## "recorded the ack" is exactly the case this module exists to survive,
  ## and the recovery path must be safe to re-run.
proc depth*[T](q: DurableQueue[T]): int      ## Adjustable-shaped: how much is queued
proc compact*[T](q: var DurableQueue[T])
  ## Rewrites the log with only unacknowledged entries — the log grows
  ## forever otherwise, since `ack` marks a pointer, it doesn't erase the
  ## record. Not automatic: compaction takes an exclusive moment on the
  ## file, so the caller picks when, the same restraint `alloc.map::retain`
  ## already gives its own caller for bulk eviction.
```

## Friendly-naming notes

| Shape it's modeled on | Nim name | Why |
|---|---|---|
| A message broker's "outbox pattern" (no single canonical library name) | `DurableQueue[T]` | names the guarantee, not a specific broker's vocabulary |
| SQS/Pub-Sub "receive, process, ack" | `pending()` + `ack(id)` | the at-least-once shape every real message queue converges on, spelled with this library's own verbs |
| A raw WAL (`kv-store-server`'s hand-rolled version, per `INDEX.md`) | `push`/`persist` built in, not hand-rolled per app | the exact duplication `INDEX.md` already flagged (`platform.hal`'s I2C retry and `process-supervisor`'s restart backoff were each hand-rolled independently) resolved once instead of a third time |
| Kafka consumer group offset commit | `ack(id)` | one id, one call — no separate offset-commit API to learn |

## In use

```nim
# mobile background sync (per DOMAINS.md, this document's sharpest offline finding)
var outbox = openQueue[SyncOp](appDataDir() / "outbox.log")
outbox.push(SyncOp(kind: skUpdate, recordId: task.id, payload: task))
# ...app may be killed here; nothing is lost...

# later, once connectivity returns:
for entry in outbox.pending():
  if trySend(server, entry.value):
    outbox.ack(entry.id)
  # left un-acked entries are retried next time pending() is called

# a web backend's outbox pattern: never lose an event because the queue was down
var events = openQueue[DomainEvent]("data/outbox.log")
db.begin():
  discard db.exec("update orders set status = 'paid' where id = ?", @[orderId])
  events.push(DomainEvent(kind: ekOrderPaid, orderId: orderId))
```

## Vocabulary exceptions
- **`push`/`pop`-shaped but no `pop`.** `pending()` returns a snapshot
  rather than removing one item — removal happens through `ack(id)`
  explicitly, because the item isn't "done" until whatever consumed it
  says so, which a `pop` (removes on read) cannot express safely across a
  crash between the two.
- **Not `Collection`, on purpose.** `list`/`first`/`each` would invite
  reading entries without acknowledging them, silently reintroducing
  "did I already send this" — the one failure mode this module's whole
  design exists to close.
- **Left unresolved, on purpose.** Conflict resolution when the *same*
  record was modified both locally (queued, not yet synced) and on the
  server is explicitly out of scope — `DOMAINS.md` names this as a genuine
  gap, not something this module's ack/replay mechanics can resolve on
  their own; a CRDT-shaped merge primitive would be the next real question,
  and isn't guessed at here without a validated app forcing its actual
  shape.
