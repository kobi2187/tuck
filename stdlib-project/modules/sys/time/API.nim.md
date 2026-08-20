# sys.time — Nim API

## Purpose
Two clocks that are never allowed to be confused: `Instant` for measuring how long something took, `Timestamp` for recording when it happened. Plus `Duration`, the one way this library ever says "how long."

## Protocols implemented
**None — domain module.** It supplies the `Duration` every `Waitable`, `Messenger` and timeout in the library speaks, but a point in time has no structural shape of its own.

## The API

```nim
type
  Duration* = object      ## a span. Signed, nanosecond-resolution, no allocation
  Instant* = object       ## a reading off the steady clock. Opaque on purpose: there is no
                          ## `toInt`, no `$`, and no way to serialise one. Comparing across
                          ## processes or reboots is meaningless, so the type won't let you.
  Timestamp* = object     ## what a clock on the wall said. Can jump backwards (NTP, a user)

proc now*(_: typedesc[Instant]): Instant
proc now*(_: typedesc[Timestamp]): Timestamp
  ## Written `Instant.now()` and `Timestamp.now()`, so which clock you asked for is on the page.
  ## Cost: a vDSO read on Linux/macOS, `QueryPerformanceCounter` on Windows — tens of
  ## nanoseconds, no kernel trap. Safe to call twice per request at thousands of requests
  ## a second; any port that cannot manage that must say so here.

proc elapsed*(since: Instant): Duration        ## Instant.now() - since; never negative
proc since*(later, earlier: Instant): Duration ## saturates at zero rather than wrapping
proc `+`*(i: Instant; d: Duration): Instant
proc `<`*(a, b: Instant): bool

proc since*(later, earlier: Timestamp): Duration
  ## Raises when the clock ran backwards between the two readings — that is a real event
  ## on a wall clock, and silently returning a colossal duration is how it becomes a bug.
proc trySince*(later, earlier: Timestamp): Option[Duration]
const UnixEpoch*: Timestamp
proc unixSeconds*(t: Timestamp): int64         ## the one serialisable form; `std.chrono` does calendars

func nanos*(n: int64): Duration     ## `500.ms`, `3.seconds`, `2.minutes` — UFCS suffixes,
func micros*(n: int64): Duration    ## which is how every timeout in this library is written
func ms*(n: int64): Duration
func seconds*(n: int64): Duration
func minutes*(n: int64): Duration
const Forever*: Duration            ## the default for every `wait`/`receive` in the tier
func asSeconds*(d: Duration): float64
func tryAdd*(a, b: Duration): Option[Duration]

proc sleep*(d: Duration)            ## the same proc `sys.thread` exports, listed here to be found
template measure*(name: string; body: untyped): Duration
  ## Time a block without writing the two `Instant.now()` calls and the subtraction.
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `SystemTime` | `Timestamp` | says what it's for — stamping a log line — instead of naming the subsystem it came from |
| `Instant::now()` | `Instant.now()` | the type is the first word you read, so picking the wrong clock takes real effort |
| `duration_since(earlier)` | `since(later, earlier)` | reads as English left to right, and the argument order matches every other proc |
| `checked_duration_since` | `trySince` | the `try` prefix already means "hands back absence instead of raising", library-wide |
| `from_millis(500)` | `500.ms` | UFCS. It is shorter than the number of characters in `from_millis` |
| `as_secs_f64` | `asSeconds` | the width is Nim's business, not the caller's |
| `checked_add` | `tryAdd` | the same word `core.num` uses for the same idea |
| `Option<Duration>` for "no timeout" | `Forever` | one named constant beats `none(Duration)` at every timeout call site |
| *(none)* | `measure` | new. Everybody writes this template; writing it once is the whole point of a stdlib |

## In use

```nim
# mp3-player: playback position, immune to the user fixing their clock mid-song
let started = Instant.now()
while playing:
  ui.showPosition(trackOffset + started.elapsed())     # never jumps, never goes backwards
  sleep(250.ms)

# load-tester: two readings per request, and a wall-clock stamp for the report header
let sent = Instant.now()
let reply = conn.request(url)
latencies.add(sent.elapsed())
report.header = "run started " & Timestamp.now().unixSeconds().show()

# secrets-vault: clear the clipboard in 30 seconds, measured on the steady clock
let clearAt = Instant.now() + 30.seconds
```

## Vocabulary exceptions
- **`now`, `elapsed`, `since` and `sleep` are domain verbs.** Reading a clock is not `get(target, key)` — there is no target and no locator — and forcing it into the structural table would obscure rather than clarify, which is exactly the case PROTOCOLS carves out.
- **`Instant` has no `show`.** Deliberate: `core.fmt`'s `Showable` is what makes `echo t` legal, and an `Instant` printed into a log is a number that means nothing to anyone tomorrow. Use a `Timestamp` for that, and the compiler will tell you when you didn't.
- **`Duration` is a `sys` type that has no OS dependency.** It is defined here rather than in `core` only so there is exactly one spelling that `sys.thread`, `sys.sync`, `sys.net`, `sys.process`, `sys.signal` and `sys.ble` all import from the same place.
