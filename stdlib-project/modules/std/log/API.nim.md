# std.log — Nim API

## Purpose
Leveled logging where the interesting parts stay as *values* — `field("attempt", 3)`, not `"attempt=3"` — so the same call produces readable text for a person and real JSON for a machine, and costs nothing when the level is off.

## Protocols implemented
None of the nine, honestly. `Log` is `Messenger`-*shaped* — `send(log, record)` is exactly "hand off a message" — but there is no `receive`, because nothing ever reads a record back out. Rather than supply a raising stub to complete the concept, the missing half is named here, the same way `core.fmt`'s `TextSink` names its missing `read`.

## The API

```nim
type
  Level* = enum Trace, Debug, Info, Warn, Error
  Field* = object            ## a typed key/value pair, never pre-formatted
    key*: string
    value*: FieldValue
  FieldValue* = object
    case kind*: FieldKind
    of fText: text*: TextView
    of fWhole: whole*: int64
    of fNumber: number*: float
    of fYes: yes*: bool
    of fSpan: span*: Duration
    of fWhen: at*: Instant
    of fFailure: failure*: Failure
    of fGroup: group*: seq[Field]
  Record* = object
    at*: Instant
    level*: Level
    msg*: TextView
    fields*: openArray[Field]
  LogSink* = concept s
    ## Where records end up. Implement these two and you are a sink.
    write(s, Record)
    accepts(s, Level) is bool
  Log* = object              ## cheap to copy; a handle, not a hierarchy

proc field*[T](key: static string; value: T): Field
  ## Overloaded across the FieldValue kinds. There is deliberately no fallback that
  ## formats an arbitrary type: `field("password", pw)` must not compile.

proc newLog*(sink: LogSink): Log
proc with*(log: Log; fields: varargs[Field]): Log
  ## A *new* handle carrying these fields on every record. Nothing is mutated, so a
  ## per-connection log is a value you pass down, not a name you look up.
proc withGroup*(log: Log; name: static string): Log   ## nests later fields under `name.*`

proc send*(log: Log; rec: Record)                     ## the generic path
proc trace*(log: Log; msg: string; fields: varargs[Field])
proc debug*(log: Log; msg: string; fields: varargs[Field])
proc info* (log: Log; msg: string; fields: varargs[Field])
proc warn* (log: Log; msg: string; fields: varargs[Field])
proc error*(log: Log; msg: string; fields: varargs[Field])
proc log*(log: Log; s: Scope; level: Level; msg: string; fields: varargs[Field])
  ## Takes a `std.async.Scope` so a sink can pick up scope-carried values (a request
  ## id set once via `scope.set`) without every call site repeating them.

proc accepts*(log: Log; level: Level): bool
  ## Ask before building expensive fields. `if log.accepts(Debug): log.debug(...)`

proc newTextSink*(into: var ByteSink; from = Info): LogSink
proc newJsonSink*(into: var ByteSink; from = Info): LogSink

proc defaultLog*(): Log
proc setDefaultLog*(log: Log)     ## set once at startup; there is no reconfiguration API
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `Logger` | `Log` | You write `log.info(...)`; the type may as well be the word you already typed. |
| `Attr` / `attr(k, v)` | `Field` / `field(k, v)` | "Attribute" is XML's word. A structured log line has fields. |
| `Handler` | `LogSink` | Matches `core.fmt`'s `TextSink` exactly: a sink is where things go. "Handler" says nothing about direction. |
| `Value` | `FieldValue` | Bare `Value` collides with half the library; the qualified name costs one word and removes the ambiguity. |
| `Logger::enabled(level)` | `accepts(log, level)` | Reads as the question you are asking before you spend money building fields. |
| `TextHandler::new(w, min)` | `newTextSink(into, from =)` | Target first, options last. `from = Warn` says which levels get through. |
| `set_default(logger)` | `setDefaultLog` | Greppable, and the noun tells you what global you just touched. |
| `Record.msg + attrs` | *(unchanged)* | The one thing worth keeping verbatim: attributes never get folded into the message string. |

## In use

```nim
# chat-server: bind the connection's identity once, forget about it afterwards
let conn = baseLog.with(field("connId", id), field("peer", addr))
conn.info("joined", field("room", room), field("members", room.count))

# web-downloader: don't build the fields at all when debug is off
if dl.accepts(Debug):
  dl.debug("chunk", field("offset", at), field("bytes", n), field("of", total))

# process-supervisor: the supervisor's own events go here; the child's stdout does not
sup.with(field("process", name))
   .warn("crashed, backing off", field("after", uptime), field("wait", delay))
```

## Vocabulary exceptions
`trace`/`debug`/`info`/`warn`/`error` are domain verbs and stay — they are the five words every logging API in existence uses, and renaming them would be gratuitous. `with` is a compound of nothing structural; it returns a new `Log` rather than mutating, which is the whole design (`chat-server`'s per-connection handle), so the name reads as "the same log, with these as well."

`send(log, rec)` uses `Messenger`'s verb on a type that is not a `Messenger`. That is deliberate and narrow: handing a record to a sink genuinely is "hand off a message," and inventing a sixth word for it would break the one-verb rule for no gain. `accepts` is the exception's exception — it is neither `has` (that would be membership in a collection) nor `wait`, so it gets a plain English name.

**No `Broadcaster` needed here either.** A logger with several destinations is a `LogSink` that holds a `Collection[LogSink]` and calls `each` — ordinary application code over verbs that already exist, not a protocol.
