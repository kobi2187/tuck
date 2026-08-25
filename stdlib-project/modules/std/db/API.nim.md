# std.db — Nim API

## Purpose
Run a parameterized query against a database and get typed rows back — the
Go `database/sql` shape, not an ORM. This module owns the *interface*
(connect, query, get typed rows, transact); it does not own any wire
protocol or file format itself. A driver satisfies this interface for one
specific database; `sqlite` (below) is the reference driver this module
ships alongside.

*New in this pass.* `DOMAINS.md`'s cross-domain synthesis found web backend
and mobile both need this, independently, and named the exact fragmentation
risk of leaving it unstandardized: Rust's `std` left both the interface and
the implementation to the ecosystem for async, and paid for it with three
competing runtimes for the better part of a decade. Go standardized the
*interface* only and let drivers stay fully external, and it did not
fragment. This module is that interface. Per `GOVERNANCE.md`: the interface
is rung **A**; the bundled `sqlite` driver is rung **B1** — shipped inside
the offline toolchain install, not fetched from a registry, because a
database-shaped app is the single most common thing either domain builds,
and an offline developer without it is exactly the "hand-roll a driver from
raw `sys.ffi`" outcome this project's batteries-included promise exists to
prevent.

## Protocols implemented
`Connection` is `Resource`. `Rows` is `Collection[Row]` — the result set is
walked with `list`, and `first`/`count`/`each` arrive for free. `Row` is
`Gettable` with a column locator (name or index), the same two-locator shape
`sys.ble::Device` already established for a value addressed by more than one
kind of key.

## The API

```nim
type
  Connection* = object        ## Resource. One open link to one database
  Transaction* = object       ## Resource. Commits on `close`; `rollback` is the other exit
  Rows* = object               ## Collection[Row] — a streaming result set, not a materialized seq
  Row* = object                ## Gettable[ColumnRef, T]

  ColumnRef* = object
    case byName*: bool
    of true:  name*: string
    of false: index*: int

  Value* = object
    ## One dynamically-typed column value. `get[T]` converts; an
    ## unconvertible request raises the same `Failure` every other module's
    ## `get` does on a type mismatch — no silent truncation.
    case kind*: ValueKind
    of vkNull:    discard
    of vkInt:     asInt*: int64
    of vkFloat:   asFloat*: float64
    of vkText:    asText*: string
    of vkBlob:    asBlob*: seq[byte]
  ValueKind* = enum vkNull, vkInt, vkFloat, vkText, vkBlob

  Driver* = concept d
    ## What a database driver implements to satisfy this module. Not user-
    ## facing — `open(dsn)` picks the driver from the DSN's scheme, the same
    ## way `std.compress`'s `Method` enum picks an algorithm from one call.
    d.dialOpen(string) is Connection

proc open*(dsn: string): Connection
  ## `dsn` carries the driver selection: `"sqlite:./app.db"`,
  ## `"postgres://host/db"` — one call regardless of which `Driver` answers.
proc tryOpen*(dsn: string): Option[Connection]
proc close*(c: var Connection)

proc query*(c: var Connection; sql: string; params: varargs[Value]): Rows
  ## Parameters are always bound, never string-concatenated — there is no
  ## second, unsafe overload that takes a pre-built SQL string with the
  ## values already inlined.
proc exec*(c: var Connection; sql: string; params: varargs[Value]): int64
  ## For statements with no rows to return; the count of rows affected.

iterator list*(r: Rows): Row
  ## The `Collection` primitive. Streams rows as they arrive rather than
  ## materializing the whole result set — `for row in rows.list(): ...`
  ## over a million-row table costs one row's memory, not the table's.

proc get*[T](row: Row; col: ColumnRef): T
proc get*[T](row: Row; col: string): T        ## the common case, unwrapped
proc get*[T](row: Row; col: int): T
proc has*(row: Row; col: string): bool         ## true even if the value is SQL NULL; check `isNull` next

proc begin*(c: var Connection): Transaction
proc close*(t: var Transaction)                ## commits — Resource's ordinary close, spelled once
proc rollback*(t: var Transaction)              ## the other exit; consumes `t`
```

## Friendly-naming notes

| `database/sql` (Go) | Nim name | Why |
|---|---|---|
| `sql.Open(driver, dsn)` | `open(dsn)` | the DSN's scheme *is* the driver selection; one fewer argument to get wrong |
| `Rows.Next()` + `Rows.Scan(&a, &b)` | `for row in rows.list(): row.get[T](col)` | the `Collection` primitive replaces a hand-rolled loop-and-scan pair |
| `sql.NullString` / `sql.NullInt64` (per-type null wrappers) | `Value` variant + `has(row, col)` | one dynamic type instead of N nullable wrappers, matching `core.types::Option`'s "one way to spell absence" rule |
| `Tx.Commit()` / `Tx.Rollback()` | `close(t)` / `rollback(t)` | `close` is `Resource`'s ordinary word; only the *other* exit needs a new one |
| `driver.Driver` interface | `Driver` concept | Nim's structural typing states the same contract without a registration call |

## In use

```nim
# web backend (per DOMAINS.md): a typed row read, no string-built SQL
var db = open("sqlite:./app.db")
var rows = db.query("select id, title, done from tasks where done = ?", @[Value(kind: vkInt, asInt: 0)])
for row in rows.list():
  echo row.get[int64]("id"), "  ", row.get[string]("title")

# a migration, run once at startup — std.db owns the primitive, not the runner
var tx = db.begin()
discard tx.exec("create table if not exists tasks (id integer primary key, title text, done integer)")
close(tx)   # commits

# mobile (per DOMAINS.md): same interface, same driver, local file instead of a server
var local = open("sqlite:" & appDataDir() / "cache.db")
```

## Vocabulary exceptions
- **`query`/`exec` are domain verbs.** `read`/`write` are `Streamable`'s
  words and a SQL statement is not a stream of bytes; a structural verb here
  would teach the wrong lesson, the same reasoning `sys.ble` already gives
  for `connect`.
- **`Value` is one dynamic type rather than per-database-type wrappers.**
  Every driver's native type system (SQLite's five storage classes,
  Postgres's dozens) has to collapse to *something* at this interface's
  boundary; one variant with a `get[T]` conversion is the same resolution
  `core.types::Option` already picked for absence — one carrier, not one
  per case.
- **Left unresolved, on purpose — named, not silently dropped.**
  Connection pooling (many `query` calls sharing a bounded set of live
  connections) is exactly the shape a real server needs and is not
  specified here; per `PROTOCOLS.md`'s own executor-model precedent (once
  `std.async`'s pool question was forced open by `load-tester`'s load
  shape), this should wait for a concrete high-concurrency database app to
  force the actual answer, not be guessed at from first principles. Schema
  migrations (a numbered-file runner) are deliberately not in this file —
  `DOMAINS.md` calls it a natural extension of this interface, not a
  separate concern, and it belongs here once someone writes it, not before.

## Submodule: `sqlite` — the bundled reference driver

Ships alongside this interface at rung **B1** (bundled in the offline
toolchain install, independently versioned — see `GOVERNANCE.md`). Not a
second interface: `sqlite.open(path)` returns the same `Connection` type
above, selected automatically by `open("sqlite:...")`'s DSN scheme.

```nim
# modules/std/db/sqlite — driver-only surface; everything else is std.db's

proc open*(path: Path; readonly = false): Connection
  ## The typed entry point, for a caller who wants the driver named
  ## explicitly rather than through a DSN string — `std.db.open("sqlite:" & $path)`
  ## and this call are equivalent; both return the same `Connection`.
```

Network drivers (Postgres, MySQL) are deliberately not bundled here or
anywhere in `std` — per `DOMAINS.md`'s embedded/desktop reasoning applied to
this case, a network database needs a reachable server regardless of the
developer's own registry access, so bundling the *driver* offline buys
nothing an offline developer couldn't already get from `sqlite`. Those stay
rung B2/C, fetched on demand, against the same `Driver` concept this file
defines.
