# core.error — Nim API

## Purpose
One way things go wrong, library-wide. Absence hands you an `Option`; failure raises a `Failure` that carries what happened, where, and what caused it; a `try`-prefixed sibling exists whenever you'd rather branch than catch.

## Protocols implemented
**None of the nine.** This module defines the failure half of PROTOCOLS' third convention — the rule every other module's signatures obey — rather than being a structural shape itself.

## The API

```nim
type
  Failure* = ref object of CatchableError
    ## The root of everything this library raises. `msg` (from Nim's Exception) is
    ## the human-readable part; the fields below are the machine-readable part.
    spot*: Option[Where]      ## where it happened, if the raiser knew
    retryable*: bool          ## worth trying again, or permanently broken?

  Where* = object
    ## "What and where", cheaply and without allocating. Richer locations
    ## (a full field path like `server.tls.cert_path`) are alloc-tier types that
    ## also satisfy `Locatable`; core only knows about numbers.
    line*, column*: uint32
    offset*: Index

  Locatable* = concept x
    ## Anything that can say where it is. `alloc.string`-backed field paths
    ## satisfy this without core.error ever hearing about them.
    show(x, var TextSink)
    x.spot is Option[Where]

  Bug* = ref object of Defect
    ## A mistake in the program, not a bad input. Not catchable in normal code.

proc fail*(why: string, at = none(Where), retryable = false) {.noreturn.}
  ## Raise a `Failure`. The one way this library reports failure.
proc failBecause*(why: string, cause: Failure, at = none(Where)) {.noreturn.}
  ## Same, wrapping the lower-level failure that caused it.
func cause*(f: Failure): Option[Failure]
  ## The next link down the chain. Walk it with `while` or `list`.
iterator list*(f: Failure): Failure
  ## This failure, then its cause, then its cause's cause. For printing "caused by".

func worthRetrying*(f: Failure): bool
  ## `web-downloader`'s backoff loop asks this instead of matching on error types.

template attempt*[T](work: untyped): Option[T]
  ## Run `work`; hand back `none` if it raised. This is how every `tryX` proc in
  ## the library is written, and how you write your own.

proc bug*(why: string) {.noreturn.}
  ## Programmer error. Raises `Bug`, which nothing is expected to catch.

template needs*(condition: bool, why: static string)
  ## Precondition. Proved away at compile time where the compiler can; otherwise
  ## a check in debug builds and nothing at all under `{.push checks: off.}`.
template promises*(condition: bool, why: static string)   ## postcondition
template alwaysTrue*(condition: bool, why: static string) ## invariant
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `Result<T, E>` + `?` | raise + `try` prefix | Nim raises. The whole two-carrier system collapses into the one rule PROTOCOLS already states, and `?`-propagation becomes ordinary Nim: exceptions travel by themselves. |
| `Error` trait | `Failure` type | A concrete root type instead of a trait — Nim exceptions are already an inheritance tree, so a concept would fight the language. `Failure` is also the word PROTOCOLS uses in prose. |
| `source()` | `cause()` / `list()` | "Source" reads as a file. "Caused by" is what it prints anyway, and `list` gives the whole chain via the protocol's own enumerate verb. |
| `Location` / `SourcePos` | `Locatable` / `Where` | One word, spelled like the question it answers. |
| `is_retryable()` | `worthRetrying()` | Reads as a decision a person makes, which is what a backoff loop is doing. |
| `panic(msg)` | `bug(msg)` | "Panic" describes the runtime's reaction; "bug" describes the cause, and makes the "never for expected failures" rule self-explanatory. |
| `#[requires]`/`#[ensures]`/`#[invariant]` | `needs`/`promises`/`alwaysTrue` | Three attributes that read like a formal-methods paper became three words usable without knowing what a proof obligation is. |
| *(none)* | `attempt` | New. The single template that turns any raising proc into its `try` sibling, so the library-wide rule costs one line per proc, not a duplicated body. |

## In use

```nim
# embedded-sensor-node: bus errors are ordinary; hanging the device is not
proc readSensor(bus: var I2c): Option[Reading] =
  for go in 1 .. maxRetries:
    needs(maxRetries <= 5, "retry bound must stay small enough to not miss a sample")
    let raw = attempt[array[6, byte]](bus.read(sensorAddr, 6, timeout = 10.ms))
    raw.ifSome(bytes): return bytes.tryTo(Reading)
    led.blink(faultPattern)
  none(Reading)

# config-schema-validator: every violation keeps its own place in the file
fail("expected a port number, got text",
     at = some(Where(line: 12, column: 8, offset: 341)))
```

## Vocabulary exceptions
`fail`, `bug`, `attempt`, `needs`, `promises` and `alwaysTrue` are domain verbs; the structural table describes operations on values, and has nothing to say about control flow. `list(f: Failure)` uses the enumerate verb on something that isn't a collection — justified because walking a cause chain is exactly "enumerate everything in here", and giving it a second name would break the one-verb rule for no gain.
