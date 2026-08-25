# std.db — Tuck translation

## Shape decision, and the biggest structural mismatch found in this pass
`actor`, per direct guidance. It compiles (`./tuck ch`: `OK`) — but this
module is where the actor-as-service bet strains hardest, worth flagging
prominently rather than folding into the general open-questions list.

**An actor is one instance per declared *type*** (spec §9.1: "a singleton
— there is no separate construction step"). The Nim design's whole point
was `open(dsn): Connection` — a caller opens as many independent
connections as it needs (a pool, or simply two different databases in one
program). `actor Db` cannot represent that: there is exactly one `Db` for
the whole program, ever, by construction. Two candidate resolutions, both
real design decisions, neither taken here:

1. **One connection per program.** Fine for `todo-cli`-shaped apps, wrong
   for anything pooling connections or talking to two databases at once —
   which `INDEX.md`'s own `kv-store-server`/`chat-server` load shapes
   suggest is not a safe assumption to bake in.
2. **The actor manages a set of connections internally**, handing callers
   an opaque id rather than a `Connection` value — closer to `sys.net`'s
   real `fd: int` handle pattern (`std/net.tuck`, still a useful style
   sample even though it predates actors here) than to a per-connection
   actor. This keeps "many connections" possible but turns `Db` into a
   connection-pool manager, a bigger piece of design than this pass
   attempts.

This is a separate, still-open question from the reply-shape question
below — the two don't resolve each other, and shouldn't be conflated.

## The C-binding shape is settled, and it constrains the actor

`sqlite3*` is literally the example the pointer rule cites when justifying
its opaque-handle exemption (`tests/suites/pointer_containment.nim`), so
the driver has a sanctioned form. Verified compiling:

```tuck
extern [c, header: "sqlite3.h", lib: "sqlite3"]:
  type Sqlite3 = {}                                    # opaque handle
  type Stmt = {}
  fn sqlite3_open({path: cstring, out: Sqlite3}) -> i32 [emit: "sqlite3_open"]
  fn sqlite3_close({db: Sqlite3}) -> i32 [emit: "sqlite3_close"]
  fn sqlite3_step({s: Stmt}) -> i32 [emit: "sqlite3_step"]
```

**But a handle still may not be *stored*, and that includes actor fields.**
Verified — `conn: Sqlite3` on the `Db` actor is rejected outright:

> `Sqlite3 is a pointer — it may only appear in an extern signature, not an
> actor field (cross into safe Tuck with a converter such as toStr)`

So the actor cannot hold the connection between messages, which is what an
actor-shaped service would naturally want to do. Two shapes remain, and
this is a real design decision rather than an oversight:

1. **The C side owns the connection**, keyed by something safe the actor
   *can* hold — an `int` slot id, with the impl module keeping the handle
   in a static table. This is how a `[impl:]` binding would normally do it,
   and it composes with the multi-connection question above (the id
   becomes the connection identifier).
2. **Every operation opens and closes**, holding a handle only within one
   expression. Correct by construction, and far too slow for anything real.

Option 1 is almost certainly right, but it means the "driver" is a small
amount of *backend-language* code (Nim/Odin) holding the handle table, not
pure Tuck — worth stating plainly, since it changes what "write the sqlite
driver" involves.

## The reply shape — resolved: a cursor, not a bulk fetch

`query`'s whole value is the rows it returns, and rows can be arbitrarily
wide — exactly the "large reply" case `TUCK-TRANSLATION.md`'s resolved
pattern addresses. The answer isn't to make the actor-boundary copy
cheaper (it's deliberately not, per spec — see that file); it's to never
produce one big reply at all. `query` allocates a cursor keyed by a
caller-supplied token; `fetchNext {token}` returns exactly **one row** per
call, appended to a small bounded field — every individual message stays
small, the same size class as `sys.audio`'s status replies, regardless of
how many rows the query actually matches.

**Compiler-verified**, `./tuck ch`: `OK`. One real gotcha hit getting here:
`pending` is a reserved word (the `pending:` block) — the results field
below is named `fetched`, not `pending`, because the latter fails to parse
as a field name at all (see `TUCK-TRANSLATION.md`'s syntax-gotchas list).

## The API

```tuck
type ValueKind:
  | vkNull
  | vkInt
  | vkFloat
  | vkText

type Value = {kind: ValueKind, asInt: i64, asFloat: float, asText: str}
type Row = {columns: Seq[Value]}
type FetchResult = {token: i64, done: bool, row: Row}

actor Db [queue: 32]:
  isOpen: bool = false
  fetched: Seq[FetchResult] = []

  on open({dsn: str}) -> void:
    isOpen = true

  on close() -> void:
    isOpen = false

  on query({token: i64, sql: str}) -> void:
    return          # allocates a cursor keyed by token, no rows moved yet

  on fetchNext({token: i64}) -> void:
    return           # appends exactly one FetchResult{token} to `fetched`

  on deleteToken({token: i64}) -> void:
    return

  on select:
    | shutdown -> {}: isOpen = false
```

## In use

```tuck
Db send open {dsn: "sqlite:./app.db"}
var tokens = newIncremental              # TokenIssuer, see TUCK-TRANSLATION.md
let t = {self: tokens} next
Db send query {token: t, sql: "select id from tasks"}
Db send fetchNext {token: t}
Db send deleteToken {token: t}
```

A caller reads `Db.fetched` (a copy, per actor semantics), filters to its
own `token`, and keeps calling `fetchNext` until it sees `done: true` — the
same "read the public field, then explicitly free what you've consumed"
shape `std.queue::pending`/`ack` already uses, generalized here to a
per-row cursor instead of a whole backlog.

## Open design questions
- **The multi-connection mismatch — still the module's most serious open
  question, unaffected by the cursor resolution above.** Both need their
  own decision; this file doesn't conflate them.
- `exec` (statements with no rows, just an affected-row count) isn't shown
  above — it's the same small-reply shape `sys.audio`'s status replies
  already use, not a new pattern; omitted here to keep the cursor mechanic
  the sole focus.
- Connection pooling (many callers sharing bounded live connections) is
  deliberately still not specified — per the original Nim design's own
  call, this should wait for a concrete high-concurrency app to force the
  real answer, the same way `std.async`'s executor model waited for
  `load-tester`.
