# core.types — Nim API

## Purpose
The vocabulary of plain values every other module is built from: fixed-width numbers, `bool`, `Rune`, `Option[T]`, and the small aliases (`Index`, `Bytes`) that keep signatures readable. Nothing here allocates and nothing here depends on anything else.

## Protocols implemented
**None — this is a primitive/domain module.** It defines the value types the nine protocols are written *in terms of*, so implementing one here would be circular.

## The API

```nim
{.push checks: off.}   ## core tier: no implicit bounds/overflow machinery

type
  Rune* = distinct int32   ## one Unicode scalar value — not a byte, not a UTF-16 unit
  Index* = int             ## a position in something; never used as "just a number"
  Count* = int             ## how many of something
  Bytes* = openArray[byte] ## the universal "some bytes, length included" parameter type

  Option*[T] = object
    ## Present or absent. The *only* way absence is ever spelled in this library.
    case present: bool
    of true:  value: T
    of false: discard

func some*[T](value: T): Option[T]
func none*[T](_: typedesc[T] = T): Option[T]

func isSome*[T](o: Option[T]): bool
func isNone*[T](o: Option[T]): bool

func get*[T](o: Option[T]): T
  ## The value, or raises `Failure` if there isn't one. Use when you already checked.
func get*[T](o: Option[T], fallback: T): T
  ## The value, or `fallback`. This is the one you reach for by default.
func orCompute*[T](o: Option[T], make: proc (): T {.nimcall.}): T
  ## Like `get(o, fallback)` but only builds the fallback if it's actually needed.
func orRaise*[T](o: Option[T], why: static string): T
  ## Turn "absent" into "failed" at a boundary where absence really is an error.

func map*[T, U](o: Option[T], transform: proc (x: T): U {.nimcall.}): Option[U]
func keep*[T](o: Option[T], test: proc (x: T): bool {.nimcall.}): Option[T]
  ## `some(x)` if `test(x)`, otherwise `none` — the one-value version of `iter.keep`.

template ifSome*[T](o: Option[T], name, body: untyped)
  ## `reading.ifSome(r): echo r` — binds the value with no unwrapping ceremony.

{.pop.}
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `Result<T, E>` | *(removed)* | Nim raises. Failure raises a `Failure`; a `try`-prefixed sibling returns `Option[T]`. Two carriers became one rule. |
| `char` | `Rune` | "char" reads as "byte" to most people; `Rune` is Nim's existing word for a scalar value. |
| `usize` | `Index` / `Count` | Splits the two meanings the one Rust type carried, so a signature says which it means. |
| `unwrap_or(d)` | `get(o, d)` | `get` is the protocol verb; the fallback is just a second argument. Nobody has to learn "unwrap". |
| `unwrap_or_else(f)` | `orCompute(f)` | Says what's different about it: the fallback costs something. |
| `ok_or(e)` | `orRaise("why")` | Converts absence to failure — matches the Option-vs-raise rule directly. |
| `is_some` | `isSome` | Unchanged; already plain. |
| `filter` | `keep` | Same rename as `core.iter`, so one word means one thing library-wide. |

## In use

```nim
# embedded-sensor-node: an ADC reading that may not have been taken yet
var latest: Option[uint16] = none(uint16)
latest = some(adc.sample())

echo latest.get(0)                       # safe default, no branch written by hand
latest.ifSome(mv): led.blink(mv div 100) # only runs when there's a reading

let scaled = latest.map(proc (mv: uint16): uint16 = mv * 3)
let mustHave = latest.orRaise("sensor never sampled")   # raises Failure at the boundary
```

## Vocabulary exceptions
`orCompute` and `orRaise` are new verbs, not in the table. They're justified because the table has no word for "supply a fallback lazily" or "promote absence to failure", and both are one-line, single-purpose words that read as English. `keep` is borrowed from `core.iter` rather than invented, per the no-synonyms rule.
